from __future__ import annotations

import base64
import os
import re
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

import numpy as np

from pyenvector.client.client import EnvectorClient
from pyenvector.kms.client import KMSClient
from pyenvector.proto_gen.v2.common import type_pb2 as common_type_pb2


def short_key_id(prefix: str) -> str:
    return f"e2e-{prefix}-{uuid.uuid4().hex[:8]}"


def configure_local_kms_tls_roots(kms_addr: str, secure: bool) -> str | None:
    """Return the local docker-compose KMS CA path when running TLS examples locally."""
    if not secure:
        return None

    host = kms_addr.rsplit(":", 1)[0]
    if host not in {"localhost", "127.0.0.1", "::1"}:
        return None

    for env_name in ("KMS_INTEGRATION_CACERT", "KMS_HTTP_CACERT"):
        env_ca = os.environ.get(env_name)
        if not env_ca:
            continue
        env_ca_path = Path(env_ca)
        if env_ca_path.is_file() and env_ca_path.stat().st_size > 0:
            return str(env_ca_path)

    # Compose-only fallback. This file also ships outside the SDK tree, where there
    # are fewer parents than the SDK layout has — resolve defensively.
    _parents = Path(__file__).resolve().parents
    repo_root = _parents[5] if len(_parents) > 5 else _parents[-1]
    ca_path = repo_root / ".local" / "kms-root-ca.crt"
    compose_project = os.environ.get("KMS_COMPOSE_PROJECT_NAME") or os.environ.get("COMPOSE_PROJECT_NAME")
    env_path = repo_root / ".env"
    if not compose_project and env_path.is_file():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("COMPOSE_PROJECT_NAME="):
                compose_project = line.split("=", 1)[1].strip().strip("'\"")
                break

    if compose_project:
        ca_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        container = f"{compose_project}-envector-kms-tee-1"
        try:
            subprocess.run(
                ["docker", "cp", f"{container}:/certs/ca/root_ca.crt", str(ca_path)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            ca_path.chmod(0o600)
        except Exception:
            pass

    if ca_path.is_file() and ca_path.stat().st_size > 0:
        return str(ca_path)
    return None


def normalized_vectors(num_vectors: int, dim: int, seed: int) -> list[list[float]]:
    rng = np.random.default_rng(seed)
    vectors = rng.random((num_vectors, dim))
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    norms[norms == 0] = 1
    return (vectors / norms).tolist()


def deterministic_key_seed(seed: int) -> bytes:
    """Derive a stable 64-byte key-generation seed from the example seed."""
    return np.random.default_rng(seed).bytes(64)


def parse_key_seed(seed_hex: str | None, fallback_seed: int) -> bytes:
    if seed_hex:
        key_seed = bytes.fromhex(seed_hex)
    else:
        key_seed = deterministic_key_seed(fallback_seed)
    if len(key_seed) != 64:
        raise ValueError(f"key seed must be exactly 64 bytes, got {len(key_seed)}")
    return key_seed


def generate_local_secret_key_from_seed(
    *,
    key_id: str,
    preset: str,
    eval_mode: str,
    seed: bytes,
) -> bytes:
    """Generate a local SDK secret key with the same seed used by KMS."""
    from pyenvector.crypto.key_manager import KeyGenerator, KeyManager

    with tempfile.TemporaryDirectory(prefix="envector-kms-seed-e2e-") as key_dir:
        KeyGenerator(
            key_path=key_dir,
            key_id=key_id,
            preset=preset,
            eval_mode=eval_mode,
            metadata_encryption=False,
            seed=seed,
        ).generate_keys()
        return KeyManager(key_id=key_id).unwrap_key_json(str(Path(key_dir) / "SecKey.json"))


def derive_local_metadata_key_from_seed(seed: bytes) -> bytes:
    """Derive the deterministic metadata key from seed (matches KMS derivation)."""
    from pyenvector.utils.aes import derive_metadata_key_from_seed

    return derive_metadata_key_from_seed(seed)


def local_topk_from_seeded_secret(
    *,
    result_ctxt,
    sec_key: bytes,
    dim: int,
    preset: str,
    eval_mode: str,
    top_k: int,
) -> list[dict]:
    """Decrypt score ciphertext locally and return the expected TopK rows."""
    from pyenvector.crypto.cipher import Cipher

    cipher = Cipher(
        dim=dim,
        preset=preset,
        eval_mode=eval_mode,
        use_key_stream=True,
        sec_key=sec_key,
    )
    decrypted = cipher.decrypt_score(result_ctxt, sec_key=sec_key)
    shard_indices = list(getattr(result_ctxt.data, "shard_idx", []))
    rows = []
    for score_group_idx, scores in enumerate(decrypted["score"]):
        shard_idx = shard_indices[score_group_idx] if score_group_idx < len(shard_indices) else score_group_idx
        for row_idx, score in enumerate(scores):
            rows.append(
                {
                    "metadata_idx": {
                        "shard_idx": shard_idx,
                        "row_idx": row_idx,
                    },
                    "score": float(score),
                }
            )
    rows.sort(key=lambda row: row["score"], reverse=True)
    return rows[:top_k]


def cleanup_msa_artifacts(msa_addr: str, index_prefix: str, access_token: str | None = None, secure: bool = False) -> None:
    cleanup_client = EnvectorClient()
    cleanup_client.init_connect(address=msa_addr, access_token=access_token, secure=secure)
    try:
        for index_name in cleanup_client.indexer.get_index_list() or []:
            if not index_name.startswith(index_prefix):
                continue
            try:
                print(f"[cleanup] delete leftover index: {index_name}", flush=True)
                cleanup_client.indexer.delete_index(index_name)
            except Exception as exc:
                print(f"[cleanup] delete leftover index warning: {exc}", flush=True)
        for key_id in cleanup_client.indexer.get_key_list() or []:
            try:
                cleanup_client.indexer.unload_key(key_id=key_id)
            except Exception:
                pass
            try:
                cleanup_client.indexer.delete_key(key_id=key_id)
            except Exception:
                pass
    finally:
        cleanup_client.disconnect()


def wait_for_registered_key(client: EnvectorClient, key_id: str, timeout: float = 10.0, poll_interval: float = 0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if key_id in (client.get_key_list() or []):
                return
        except Exception:
            pass
        time.sleep(poll_interval)
    raise RuntimeError(f"Key '{key_id}' was not registered within {timeout}s")


def load_key_with_cleanup(client: EnvectorClient, key_id: str) -> None:
    try:
        client.load_key(key_id=key_id)
        return
    except Exception as exc:
        match = re.search(r"Another key \(ID: ([^)]+)\) is already loaded", str(exc))
        if not match:
            raise

    loaded_key_id = match.group(1)
    print(f"[cleanup] unloading previously loaded key: {loaded_key_id}", flush=True)
    try:
        client.unload_key(key_id=loaded_key_id)
    except Exception as unload_exc:
        print(f"[cleanup] unload warning: {unload_exc}", flush=True)
    client.load_key(key_id=key_id)


def kms_scores_from_result(result_ctxt):
    return [common_type_pb2.EVCiphertext(degree=score.degree, data=score.data) for score in result_ctxt.data.ctxt_score]


def manual_kms_round_trip(index, kms_client: KMSClient, result_ctxt, top_k: int):
    shard_indices = list(getattr(result_ctxt.data, "shard_idx", []))
    ranked_results = kms_client.topk(
        key_id=index.index_config.key_id,
        encrypted_scores=kms_scores_from_result(result_ctxt),
        k=top_k,
        shard_indices=shard_indices or None,
    )

    topk_indices = [
        {
            "shard_idx": ranked.metadata_idx.shard_idx,
            "row_idx": ranked.metadata_idx.row_idx,
        }
        for ranked in ranked_results
    ]
    metadata_result = index.indexer.get_metadata(index.index_config.index_name, topk_indices, fields=["metadata"])

    encrypted_metadata = []
    encrypted_positions = []
    decrypted_metadata = [None] * len(metadata_result)
    for i, item in enumerate(metadata_result):
        payload = index._metadata_payload(item)
        if not payload:
            continue
        if index.index_config.metadata_encryption:
            encrypted_metadata.append(base64.b64decode(payload))
            encrypted_positions.append(i)
        else:
            decrypted_metadata[i] = payload

    if encrypted_metadata:
        plaintext_metadata = kms_client.decrypt_metadata(index.index_config.key_id, encrypted_metadata)
        for i, plaintext in zip(encrypted_positions, plaintext_metadata):
            decrypted_metadata[i] = index._parse_kms_plaintext_metadata(plaintext)

    return [
        {
            "id": metadata_result[i].id,
            "metadata_idx": topk_indices[i],
            "score": ranked_results[i].score,
            "metadata": decrypted_metadata[i],
        }
        for i in range(len(ranked_results))
    ]
