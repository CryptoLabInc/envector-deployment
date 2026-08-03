"""Example: KMS <-> SDK <-> envector-msa server end-to-end lifecycle flow.

The local envector-msa gRPC endpoint is plaintext in this flow; KMS uses the
SDK default TLS connection.

Proves KMS key lifecycle (rotate / suspend / destroy) against a live MSA:

1. KMS generates a key (no seed)
2. SDK init with kms_address + auto_key_setup registers/loads the key on MSA
3. Insert + managed search baseline
4. KMS TopK baseline (explicit path — proves KMS can decrypt)
5. Rotate -> managed search and explicit KMS TopK still work
6. Suspend -> managed search fails, explicit KMS TopK fails
7. Destroy -> managed search fails, explicit KMS TopK fails

See kms_sdk_msa_seed_e2e.py for seed-consistency verification.
"""

from __future__ import annotations

import argparse
import os
import sys
import uuid
from pathlib import Path

# Imports resolve to the installed pyenvector (pip install pyenvector==<version>).
# The in-repo SDK source is deliberately NOT prepended to sys.path here, so this
# example exercises the released client rather than shadowing it.

import numpy as np
from _kms_e2e_common import (
    cleanup_msa_artifacts,
    configure_local_kms_tls_roots,
    manual_kms_round_trip,
    normalized_vectors,
    short_key_id,
)

from pyenvector.client.client import EnvectorClient
from pyenvector.kms.client import KMSClient

try:
    # Dev-only OpenTelemetry harness; excluded from the shipped wheel. When
    # present and OTEL_TRACES_ENABLED is set, SDK gRPC calls emit traces that
    # connect to the server-side spans (search <-> KMS). A no-op otherwise.
    from pyenvector import telemetry as _telemetry
except Exception:
    _telemetry = None


def _trace_span(name: str):
    if _telemetry is None:
        import contextlib

        return contextlib.nullcontext()
    return _telemetry.span(name)


def resolve_msa_address(args: argparse.Namespace) -> str:
    if args.msa_address:
        return args.msa_address
    return f"{args.host}:{args.port}"


def assert_rows_match(label: str, actual_rows, expected_rows) -> None:
    ids_match = [row["id"] for row in actual_rows] == [row["id"] for row in expected_rows]
    metadata_match = [row["metadata"] for row in actual_rows] == [row["metadata"] for row in expected_rows]
    score_match = np.allclose(
        [row["score"] for row in actual_rows],
        [row["score"] for row in expected_rows],
        rtol=1e-5,
        atol=1e-6,
    )
    print(f"[result] {label}_ids_match = {ids_match}", flush=True)
    print(f"[result] {label}_metadata_match = {metadata_match}", flush=True)
    print(f"[result] {label}_score_match = {score_match}", flush=True)
    if not (ids_match and metadata_match and score_match):
        raise RuntimeError(f"{label} rows do not match")


def expect_failure(label: str, fn) -> None:
    try:
        fn()
    except Exception as exc:
        print(f"[result] {label}_failed_as_expected = True ({type(exc).__name__}: {exc})", flush=True)
        return
    raise RuntimeError(f"{label} unexpectedly succeeded")


def latest_key_state(kms_client, key_id: str) -> str:
    details = kms_client.get_key_details(key_id)
    versions = details.get("versions", [])
    if not versions:
        raise RuntimeError(f"KMS returned no versions for {key_id}")
    return str(versions[-1].get("state"))


def main(args: argparse.Namespace) -> None:
    msa_addr = resolve_msa_address(args)
    kms_addr = args.kms_address
    key_id = args.key_id or short_key_id("msa")
    index_name = args.index_name or f"e2e_kms_msa_{uuid.uuid4().hex[:8]}"
    preset = args.preset
    eval_mode = args.eval_mode

    print(f"[config] MSA={msa_addr}", flush=True)
    print(f"[config] KMS={kms_addr}", flush=True)
    print("[config] MSA TLS=disabled", flush=True)
    print(f"[config] KMS TLS={'disabled' if args.notls else 'enabled'}", flush=True)
    kms_ca = configure_local_kms_tls_roots(kms_addr, secure=not args.notls)
    if kms_ca:
        print(f"[config] KMS CA={kms_ca}", flush=True)
    print(f"[config] key_id={key_id}", flush=True)
    print(f"[config] eval_mode={eval_mode}", flush=True)
    print(f"[config] preset={preset}", flush=True)
    print(f"[config] index_name={index_name}", flush=True)
    print(f"[config] msa_access_token={'set' if args.access_token else 'unset'}", flush=True)

    if _telemetry is not None:
        # No-op unless OTEL_TRACES_ENABLED is set in the environment.
        _telemetry.enable()

    print("[cleanup] remove leftover e2e indexes/keys", flush=True)
    cleanup_msa_artifacts(msa_addr, "e2e_kms_msa_", access_token=args.access_token, secure=False)

    client = EnvectorClient()
    kms_client = KMSClient(
        address=kms_addr,
        secure=not args.notls,
        access_token=args.access_token,
        ca_cert=kms_ca,
    )
    index = None
    try:
        print("[step] Init SDK client -- KMS manages the secret key", flush=True)
        client.init_connect(
            address=msa_addr,
            access_token=args.access_token,
            secure=False,
        )
        client.init_kms_connect(
            kms_address=kms_addr,
            secure=not args.notls,
            access_token=args.access_token,
            ca_cert=kms_ca,
        )
        client.init_index_config(
            index_name=index_name,
            dim=args.dim,
            key_id=key_id,
            preset=preset,
            eval_mode=eval_mode,
            query_encryption="plain",
            index_encryption="cipher",
            index_type="flat",
            metadata_encryption=False,
            auto_key_setup=True,
        )

        print("[step] CreateIndex", flush=True)
        index = client.create_index(index_name=index_name, dim=args.dim, index_type="flat", metadata_encryption=False)

        print("[step] Insert data", flush=True)
        vectors = normalized_vectors(args.num_vectors, args.dim, seed=args.vec_seed)
        metadata = [{"name": f"item_{i}", "rank": i} for i in range(args.num_vectors)]
        query = vectors[0]
        index.insert(data=vectors, metadata=metadata)

        print("[step] Baseline: SDK managed search()", flush=True)
        with _trace_span("managed_search_baseline"):
            baseline_rows = index.search(query=query, top_k=args.topk, output_fields=["metadata"])[0]
        for row in baseline_rows:
            print(f"  - id={row['id']} score={row['score']:.6f} metadata={row['metadata']}", flush=True)
        print(f"[result] baseline_search = True ({len(baseline_rows)} rows)", flush=True)

        print("[step] Baseline: KMS TopK (explicit path)", flush=True)
        # Group scoring() (search service) and the KMS TopK round-trip under one
        # parent span so the explicit decrypt path reads as a single connected
        # trace in Jaeger instead of two separate SDK->server traces.
        with _trace_span("explicit_kms_topk_baseline"):
            result_ctxt = index.scoring(query=query)[0]
            manual_kms_round_trip(
                index=index,
                kms_client=kms_client,
                result_ctxt=result_ctxt,
                top_k=args.topk,
            )
        print("[result] baseline_kms_topk = True", flush=True)

        print("[step] RotateKey", flush=True)
        kms_client.rotate_key(key_id=key_id, reason="kms_sdk_msa_e2e rotate")

        print("[step] Managed search() after rotate", flush=True)
        rotated_rows = index.search(query=query, top_k=args.topk, output_fields=["metadata"])[0]
        assert_rows_match("rotate_managed", rotated_rows, baseline_rows)

        print("[step] KMS TopK after rotate", flush=True)
        manual_kms_round_trip(
            index=index,
            kms_client=kms_client,
            result_ctxt=index.scoring(query=query)[0],
            top_k=args.topk,
        )
        print("[result] rotate_kms_topk = True", flush=True)

        print("[step] SuspendKey", flush=True)
        kms_client.suspend_key(key_id=key_id, reason="kms_sdk_msa_e2e suspend")
        suspended_state = latest_key_state(kms_client, key_id)
        print(f"[result] suspended_state = {suspended_state}", flush=True)
        if suspended_state != "KEY_STATE_SUSPENDED":
            raise RuntimeError(f"expected KEY_STATE_SUSPENDED, got {suspended_state}")
        expect_failure(
            "suspended_managed_search",
            lambda: index.search(query=query, top_k=args.topk, output_fields=["metadata"]),
        )
        expect_failure(
            "suspended_explicit_kms_topk",
            lambda: manual_kms_round_trip(
                index=index,
                kms_client=kms_client,
                result_ctxt=index.scoring(query=query)[0],
                top_k=args.topk,
            ),
        )

        print("[step] DestroyKey", flush=True)
        kms_client.destroy_key(key_id=key_id, reason="kms_sdk_msa_e2e destroy")
        destroyed_state = latest_key_state(kms_client, key_id)
        print(f"[result] destroyed_state = {destroyed_state}", flush=True)
        if destroyed_state != "KEY_STATE_DESTROYED":
            raise RuntimeError(f"expected KEY_STATE_DESTROYED, got {destroyed_state}")
        expect_failure(
            "destroyed_managed_search",
            lambda: index.search(query=query, top_k=args.topk, output_fields=["metadata"]),
        )
        expect_failure(
            "destroyed_explicit_kms_topk",
            lambda: manual_kms_round_trip(
                index=index,
                kms_client=kms_client,
                result_ctxt=index.scoring(query=query)[0],
                top_k=args.topk,
            ),
        )
    finally:
        try:
            if index is not None:
                try:
                    print(f"[cleanup] delete index: {index_name}", flush=True)
                    client.indexer.delete_index(index_name)
                except Exception as exc:
                    print(f"[cleanup] delete index warning: {exc}", flush=True)
            try:
                print(f"[cleanup] unload key: {key_id}", flush=True)
                client.unload_key(key_id=key_id)
            except Exception:
                pass
            if not args.skip_cleanup:
                try:
                    print(f"[cleanup] delete key: {key_id}", flush=True)
                    client.indexer.delete_key(key_id=key_id)
                except Exception:
                    pass
        finally:
            try:
                client.disconnect()
            except ValueError:
                pass
            if _telemetry is not None:
                # Flush any buffered spans to the collector before exit.
                _telemetry.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="KMS <-> SDK <-> MSA E2E lifecycle example. MSA gRPC is plaintext; KMS uses TLS."
    )
    parser.add_argument("--host", type=str, default="localhost", help="MSA host")
    parser.add_argument("--port", type=int, default=int(os.environ.get("MSA_PORT", "50050")), help="MSA gRPC port")
    parser.add_argument("--msa-address", type=str, default=None, help="MSA gRPC address override")
    parser.add_argument("--kms-address", type=str, default=os.environ.get("KMS_INTEGRATION_ADDR", "localhost:50090"))
    parser.add_argument("--notls", action="store_true", help="Use plaintext for the KMS gRPC connection")
    parser.add_argument("--access-token", type=str, default=os.environ.get("ENVECTOR_ACCESS_TOKEN"))
    parser.add_argument("--key-id", type=str, default=None, help="Key ID for this run")
    parser.add_argument("--index-name", type=str, default=None, help="Index name override")
    parser.add_argument("--dim", type=int, default=int(os.environ.get("E2E_DIM", "128")), help="Vector dimension")
    parser.add_argument("--num-vectors", type=int, default=int(os.environ.get("E2E_NUM_VECTORS", "10")))
    parser.add_argument("--topk", type=int, default=int(os.environ.get("E2E_TOP_K", "3")))
    parser.add_argument("--vec-seed", type=int, default=20260329, help="Random vector seed")
    parser.add_argument(
        "--preset",
        type=str,
        default=os.environ.get("KMS_PRESET", "ip3"),
        help="Key preset (must match between SDK local KeyGenerator and KMS)",
    )
    parser.add_argument(
        "--eval-mode",
        type=str,
        default=os.environ.get("KMS_EVAL_MODE", "mms32"),
        help="Eval mode (must match between SDK local KeyGenerator and KMS)",
    )
    parser.add_argument("--skip-cleanup", action="store_true", help="Keep MSA key state after the run")
    main(parser.parse_args())
