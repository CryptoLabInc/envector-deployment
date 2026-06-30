-- 1.4.0-1.4.4_to_latest.sql
--
-- In-place upgrade of a deployment on stable tags 1.4.0 – 1.4.4 (the 1.4.0-1.4.4 range)
-- to the current latest schema. Companion to 1.4.5-1.4.6_to_latest.sql,
-- which covers tags 1.4.5–1.4.6. See:
--   1.4.0-1.4.4_to_latest_runbook.md (deployment steps, validation, rollback)
--
-- Named partitions. PART A also adds indexes.parent_index_name and the partitions
--   table (+ _default backfill) — the global delta initSchema builds on a fresh
--   install. Additive + idempotent. See docs/design/partitions.md.
--
-- WHY a separate script from the 1.4.5-1.4.6 one:
--   * 1.4.0-1.4.4 has NO <idx>_shard_map_legacy sidecar (introduced only in 1.4.5), so
--     its per-index transform is the 1.4.5-1.4.6 transform with Step 7 reduced
--     to a harmless no-op.
--   * 1.4.0-1.4.4 lacks four global objects that 1.4.5 already shipped: indexes.import_id,
--     indexes.ct_trunc, the import_log table, and shards.owner_merge_task_id.
--     1.4.5→HEAD (the 1.4.5-1.4.6 script) only needs two of those; 1.4.0-1.4.4→HEAD needs all four
--     plus keys.status. PART A below carries that wider global delta.
--   * 1.4.0-1.4.4 blobs predate the 1.4.5 generation by a release, so PART B adds a per-row
--     assertion gate (Step 1b) the 1.4.5-1.4.6 script does not carry.
--
-- GROUND TRUTH (verified 2026-06-04 against tags 1.4.0–1.4.5 + HEAD da513ebd):
--   * models.go AND task_queue.go are byte-identical across 1.4.0, 1.4.1, 1.4.2,
--     1.4.3, 1.4.4 — so the 1.4.0 column superset below covers the whole version range.
--   * task_queue, index_details, index_operations, index_delete_tasks have ZERO
--     column delta vs HEAD (every column the in-binary migrateAll re-adds via
--     addColumnIfNotExists already existed in 1.4.0; those ADDs were no-ops for
--     1.4.0-1.4.4 and are intentionally omitted here).
--   * <idx>_shard_map and <idx>_ctxt_map already carry the `deprecated` column in
--     1.4.0, so no ADD COLUMN is needed before the deprecated partial indexes.
--
-- BOOT ORDER (critical — same constraint as the 1.4.5-1.4.6 script):
--   Run this script with the application STOPPED, BEFORE deploying the new
--   binary. The old binary cannot read the post-transform schema (renamed
--   <idx>_item_shard_map + row_idx), and the new binary's first runtime query
--   against <idx>_item_shard_map fails until the transform has run. After this
--   script self-healing no longer exists in the binary (initSchema is fresh-
--   install only), so the script — not the binary — is the sole upgrade path.
--
-- WHY everything is non-CONCURRENTLY and transaction-wrapped:
--   The migration runs in an app-stopped window, so there is no concurrent write
--   traffic for CREATE INDEX's SHARE lock to block. Non-CONCURRENTLY lets every
--   statement live inside a transaction (atomic per-index rollback on error) and
--   avoids the invalid-index cleanup that a failed CONCURRENTLY build leaves
--   behind. (The 2026-04-22 script used CONCURRENTLY only because it ran with the
--   app live; that constraint does not apply here.)
--
-- Execution (see runbook for the automated loop):
--   PART A runs once (idempotent — safe to re-run). PART B is a per-index
--   template: replace <index_name> with each lowercased index name and run once
--   per index. Generate the list with:  SELECT lower(index_name) FROM indexes;
--   Because PART A is fully IF-NOT-EXISTS, piping the whole file through the
--   per-index sed loop is also safe — PART A becomes a no-op after the first
--   index.

-- ============================================================================
-- PART A — Global schema delta (run ONCE; every statement is idempotent)
-- ============================================================================

BEGIN;

-- A1. indexes.ct_trunc — NOT NULL with a literal default, so existing rows are
--     backfilled to FALSE by the ADD COLUMN itself.
ALTER TABLE indexes ADD COLUMN IF NOT EXISTS ct_trunc BOOLEAN NOT NULL DEFAULT FALSE;

-- A2. indexes.import_id — nullable TEXT (Go *string, gorm tag default:null). NULL
--     is the correct value for every pre-import index, so no backfill.
ALTER TABLE indexes ADD COLUMN IF NOT EXISTS import_id TEXT DEFAULT NULL;

-- A3. shards.owner_merge_task_id — nullable BIGINT, no default. NULL is the
--     documented "legacy / unowned" state (models.go:164-166); ClaimRawShardsForMerge
--     treats NULL as claimable, so a plain nullable ADD COLUMN is the full migration.
ALTER TABLE shards ADD COLUMN IF NOT EXISTS owner_merge_task_id BIGINT;

-- A4. keys.status — NOT NULL default 'active'. Pre-migration keys are active, so
--     the literal default backfills them correctly.
ALTER TABLE keys ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'active';

-- A5. import_log table — absent in all of 1.4.0–1.4.4; first shipped in 1.4.5.
--     Mirrors the ImportLog model (models.go:304-319). Timestamps are NOT NULL
--     with no DB default because GORM sets autoCreateTime/autoUpdateTime in-app;
--     the table is empty on 1.4.0-1.4.4 deployments (the import feature did not exist).
CREATE TABLE IF NOT EXISTS import_log (
    import_id           TEXT        PRIMARY KEY,
    bundle_root_sha256  TEXT        NOT NULL,
    target_index_name   TEXT        NOT NULL DEFAULT '',
    scope               TEXT        NOT NULL,
    state               TEXT        NOT NULL,
    target_index_names  TEXT[]      NOT NULL DEFAULT '{}',
    failed_indexes      TEXT[]      NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ NOT NULL,
    updated_at          TIMESTAMPTZ NOT NULL,
    completed_at        TIMESTAMPTZ,
    failed_at           TIMESTAMPTZ,
    expired_at          TIMESTAMPTZ,
    error_code          TEXT,
    error_message       TEXT,
    CONSTRAINT chk_import_log_scope_target CHECK (
        (scope = 'SYSTEM' AND target_index_name = '')
        OR (scope = 'INDEX' AND target_index_name != '')
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS uniq_import_log_bundle_target
    ON import_log (bundle_root_sha256, target_index_name);

-- A6. Named global indexes that struct tags do not produce.
--     idx_indexes_import_id is postgres-only in the binary (partial-index syntax);
--     this script targets postgres, so it is unconditional here.
CREATE INDEX IF NOT EXISTS idx_indexes_import_id
    ON indexes (import_id)
    WHERE import_id IS NOT NULL;

-- keys cleanup-worker getKeysWithStaleStatus probe (status IN pending/deleting).
CREATE INDEX IF NOT EXISTS idx_keys_status_transient
    ON keys (status, updated_at)
    WHERE status IN ('pending', 'deleting');

-- task_queue: narrows cleanup_worker dedup / Phase-1 lookup. InsertData-driven
-- tasks leave target_shard_id NULL, so the partial predicate keeps it small.
-- (target_shard_id itself already exists in 1.4.0 with a plain struct-tag index;
--  this composite partial is the additional DeleteData index. CONCURRENTLY is
--  unnecessary in the app-stopped window — see header.)
CREATE INDEX IF NOT EXISTS idx_task_queue_target_shard_id
    ON task_queue (target_shard_id, status)
    WHERE target_shard_id IS NOT NULL;

-- Named partitions. A partition is a separate physical index
-- sharing the parent's schema/key/centroids; `partitions` maps
-- (index_name, partition_name) -> physical_index_name, and indexes.parent_index_name
-- links a partition's physical index back to its parent. _default's physical index
-- IS the parent index itself. Additive + idempotent; initSchema builds these on a
-- fresh install, so existing DBs get them here. The backfill gives every existing
-- top-level index its _default partition.
ALTER TABLE indexes ADD COLUMN IF NOT EXISTS parent_index_name VARCHAR(30) NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS partitions (
    partition_id        BIGSERIAL    PRIMARY KEY,
    index_name          VARCHAR(30)  NOT NULL,
    partition_name      VARCHAR(255) NOT NULL,
    physical_index_name VARCHAR(30)  NOT NULL,
    status              VARCHAR(20)  NOT NULL DEFAULT 'active',
    created_at          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_partitions_index
        FOREIGN KEY (index_name) REFERENCES indexes (index_name)
        ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS uniq_partition_index_name_partition_name
    ON partitions (index_name, partition_name);

INSERT INTO partitions (index_name, partition_name, physical_index_name, status)
SELECT index_name, '_default', index_name, 'active'
FROM indexes
WHERE parent_index_name = ''
ON CONFLICT (index_name, partition_name) DO NOTHING;

COMMIT;

-- ============================================================================
-- PART B — Per-index transform (repeat for every index; <index_name> = lowercased)
-- ============================================================================
-- Transforms <idx>_shard_map (item_id PK + id_in_shard) into
-- <idx>_item_shard_map (composite (shard_id, item_id) PK + row_idx), matching
-- the post-#1888 createShardMapTable path. Each block is one atomic transaction.

BEGIN;

-- Step 1: Sanity check — confirm the source table still has the old 1.4.0-1.4.4 schema.
-- Aborts if <idx>_shard_map is gone (already migrated) or id_in_shard is missing.
DO $$
DECLARE
    has_id_in_shard BOOLEAN;
    has_old_table   BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_name = '<index_name>_shard_map'
    ) INTO has_old_table;
    IF NOT has_old_table THEN
        RAISE EXCEPTION 'Index <index_name>: source table <index_name>_shard_map does not exist; already migrated?';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = '<index_name>_shard_map'
          AND column_name = 'id_in_shard'
    ) INTO has_id_in_shard;
    IF NOT has_id_in_shard THEN
        RAISE EXCEPTION 'Index <index_name>: shard_map.id_in_shard column missing; migration already applied?';
    END IF;
END $$;

-- Step 1b: Per-row assertion gate (1.4.0-1.4.4-specific defense-in-depth).
-- The Step-3 backfill recomputes row_idx as ROW_NUMBER()-1 over item_id order.
-- That is only correct if the on-disk shard blob stores items in item_id-ascending
-- slot order — i.e. if the existing id_in_shard already equals that rank for every
-- row. 1.4.x established this order unconditionally (commit be2cf6cb), but this
-- gate proves it on the actual deployment data before we trust the recompute. If
-- it fires, the blob order is NOT item_id-ascending and an in-place migration is
-- unsafe for THIS index — treat that index as v1.1.0-v1.2.2 (export / re-ingest); the other
-- indexes can still migrate in place.
DO $$
DECLARE
    mismatched BIGINT;
BEGIN
    SELECT COUNT(*) INTO mismatched FROM (
        SELECT id_in_shard,
               ROW_NUMBER() OVER (PARTITION BY shard_id ORDER BY item_id) - 1 AS computed
        FROM <index_name>_shard_map
    ) t
    WHERE id_in_shard <> computed;

    IF mismatched > 0 THEN
        RAISE EXCEPTION
            'Index <index_name>: % rows where id_in_shard <> item_id-sorted rank — '
            'blob slot order is NOT item_id-ascending; in-place migration unsafe. '
            'Use export/re-ingest for this index.',
            mismatched;
    END IF;
END $$;

-- Step 2: Create the new item_shard_map table with the composite PK.
-- Hand-written DDL matches what CreateTable(&IndexShardMap{}) emits on a fresh
-- install: PK (shard_id, item_id) only, no struct-tag secondary indexes.
CREATE TABLE <index_name>_item_shard_map (
    shard_id   VARCHAR(20) NOT NULL,
    item_id    BIGINT      NOT NULL,
    row_idx    BIGINT      NOT NULL,
    deprecated BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (shard_id, item_id)
);

-- Step 3: Backfill old → new. row_idx = sort-by-item_id position within each
-- shard (the convention the new code emits at cutover). Partition only by
-- shard_id (not deprecated) so deprecated rows keep their slot — alive rows are
-- intentionally allowed to have gaps. ON CONFLICT guards against any stray
-- duplicate (shard_id, item_id) in the source.
INSERT INTO <index_name>_item_shard_map (shard_id, item_id, row_idx, deprecated, created_at, updated_at)
SELECT
    shard_id,
    item_id,
    ROW_NUMBER() OVER (PARTITION BY shard_id ORDER BY item_id) - 1 AS row_idx,
    deprecated,
    created_at,
    updated_at
FROM <index_name>_shard_map
ON CONFLICT (shard_id, item_id) DO NOTHING;

-- Step 4: Row-count sanity. Under the old item_id PK every item is in exactly
-- one shard, so NEW count must equal OLD count; divergence means corruption.
DO $$
DECLARE
    old_count BIGINT;
    new_count BIGINT;
BEGIN
    SELECT COUNT(*) FROM <index_name>_shard_map        INTO old_count;
    SELECT COUNT(*) FROM <index_name>_item_shard_map   INTO new_count;
    IF old_count <> new_count THEN
        RAISE EXCEPTION 'Index <index_name>: row count mismatch — old=% new=% (expected equal)',
            old_count, new_count;
    END IF;
END $$;

-- Step 5: Retain the old table (renamed, not dropped) for fast rollback. Drop
-- after >=24h of stable operation (see runbook "retention cleanup").
ALTER TABLE <index_name>_shard_map RENAME TO <index_name>_shard_map_old;

-- Step 6: Indexes on the new item_shard_map — exactly the set the post-simplification
-- createShardMapTable produces on a fresh install (D1). The unused
-- idx_<idx>_item_shard_map_row_idx_alive partial is intentionally NOT created:
-- getItemIdFromIdMap has no deprecated predicate, so the planner cannot use it.
-- (a) item_id lookup (DeleteData / cutover WHERE item_id IN ...); the composite
--     PK cannot serve it since item_id is not the leading column.
CREATE INDEX IF NOT EXISTS idx_<index_name>_item_shard_map_item_id
    ON <index_name>_item_shard_map (item_id);
-- (b) "alive rows per shard" hot path (DeleteData Phase 1 survivor lookup).
CREATE INDEX IF NOT EXISTS idx_<index_name>_item_shard_map_alive
    ON <index_name>_item_shard_map (shard_id, item_id)
    WHERE deprecated = FALSE;
-- (c) "deprecated rows" cleanup_worker Phase A scan.
CREATE INDEX IF NOT EXISTS idx_<index_name>_item_shard_map_deprecated
    ON <index_name>_item_shard_map (shard_id)
    WHERE deprecated = TRUE;

-- Step 6b: FK item_id → <idx>_ctxt_map(item_id), matching createShardMapTable.
-- Added after the backfill so PostgreSQL validates it in a single scan; aborts
-- the transaction if any migrated item_id has no ctxt_map row (source corruption).
ALTER TABLE <index_name>_item_shard_map
    ADD FOREIGN KEY (item_id) REFERENCES <index_name>_ctxt_map (item_id)
    ON UPDATE CASCADE ON DELETE CASCADE;

-- Step 6c: ctxt_map deprecated partial (cleanup_worker Phase B scan). On 1.4.0-1.4.4 the
-- boot goroutine ensureDeprecatedPartialIndexes used to build this asynchronously;
-- after the simplification removes that goroutine, createCtxtMapTable builds it only for NEW
-- indexes, so existing indexes need it created here. ctxt_map already carries the
-- deprecated column in 1.4.0, so no ADD COLUMN is required. ctxt_map is the
-- pre-existing table (not recreated by this transform); non-CONCURRENTLY is safe
-- in the app-stopped window.
CREATE INDEX IF NOT EXISTS idx_<index_name>_ctxt_map_deprecated
    ON <index_name>_ctxt_map (item_id)
    WHERE deprecated = TRUE;

-- Step 7: Drop the legacy sidecar. 1.4.0-1.4.4 has no <idx>_shard_map_legacy (it first
-- appeared in 1.4.5), so this is a harmless no-op here; kept for parity with the
-- 1.4.5-1.4.6 script and to cover any hand-patched 1.4.x deployment.
DROP TABLE IF EXISTS <index_name>_shard_map_legacy;

-- Step 8: Backfill the per-index merge-lock table (pre-existing main gap, PR #1870).
-- The binary creates <idx>_item_merge_lock only at index-creation time, so indexes
-- created before #1870 lack it and the first merge fails. IF NOT EXISTS makes this
-- a no-op for indexes that already have it. Schema mirrors the ItemMergeLock model.
CREATE TABLE IF NOT EXISTS <index_name>_item_merge_lock (
    item_id       BIGINT    NOT NULL,
    owner_task_id BIGINT    NOT NULL,
    acquired_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (item_id)
);
CREATE INDEX IF NOT EXISTS idx_<index_name>_item_merge_lock_owner_task_id
    ON <index_name>_item_merge_lock (owner_task_id);

COMMIT;

-- ============================================================================
-- Post-migration statistics refresh (run per index, after COMMIT)
-- ============================================================================
-- The new PK + indexes ship with no planner statistics; ANALYZE before resuming
-- traffic so the first queries do not plan against an empty stat snapshot.
--   ANALYZE <index_name>_item_shard_map;

-- ============================================================================
-- Post-migration retention cleanup (run separately, >= 24 hours later)
-- ============================================================================
-- After one full operational day on the new schema without incident, reclaim disk:
--   DROP TABLE IF EXISTS <index_name>_shard_map_old;
--
-- Emergency rollback while _old still exists:
--   BEGIN;
--   ALTER TABLE <index_name>_item_shard_map RENAME TO <index_name>_item_shard_map_failed;
--   ALTER TABLE <index_name>_shard_map_old  RENAME TO <index_name>_shard_map;
--   COMMIT;
-- (combined with redeploying the previous 1.4.0-1.4.4 binary that expects <idx>_shard_map
--  + id_in_shard). NOTE: PART A's global ADD COLUMNs are additive and harmless to
--  the old binary, so they need not be rolled back.

-- ============================================================================
-- Validation queries (run after migration, before resuming traffic)
-- ============================================================================
-- New table schema:
--   \d <index_name>_item_shard_map
--   -- expect PK (shard_id, item_id); columns {shard_id, item_id, row_idx,
--   --        deprecated, created_at, updated_at}; NO id_in_shard.
--
-- (shard_id, row_idx) uniqueness (new code joins on this pair, no deprecated
-- filter, so a collision resolves ambiguously). Do NOT assert alive-only 0..N-1
-- contiguity — soft-deleted rows keep their slot, so gaps are legitimate.
--   SELECT shard_id, row_idx, COUNT(*)
--   FROM <index_name>_item_shard_map
--   GROUP BY shard_id, row_idx
--   HAVING COUNT(*) > 1;
--   -- expect: empty.
--
-- Global delta present:
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name = 'indexes' AND column_name IN ('ct_trunc', 'import_id');   -- expect 2 rows
--   SELECT to_regclass('import_log');                                            -- expect non-null
--
-- row_count invariant (distinct alive items):
--   SELECT COUNT(DISTINCT item_id) FROM <index_name>_item_shard_map WHERE deprecated = FALSE;
--   -- should match indexes.row_count for this index.
