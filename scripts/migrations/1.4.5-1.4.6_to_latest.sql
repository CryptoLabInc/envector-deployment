-- 1.4.5-1.4.6_to_latest.sql  (in-place upgrade: stable tags 1.4.5–1.4.6 → latest)
--
-- Refactors <idx>_shard_map → <idx>_item_shard_map to remove the race between
-- merge cutover and in-flight search/get-metadata. See:
--   1.4.5-1.4.6_to_latest_runbook.md (deployment steps)
--
-- AMENDMENT 2026-06-04 (initSchema-extraction + companion
--   companion script 1.4.0-1.4.4_to_latest.sql). The upcoming "simplification" removes the binary's
--   boot-time self-heal (ensureKeyStatusColumnAndBackfill,
--   ensureShardOwnerMergeTaskIDColumn, and the ensureDeprecatedPartialIndexes
--   goroutine), so this script must carry what those used to add. Three changes:
--     1. PART A global delta added (keys.status, shards.owner_merge_task_id) — the
--        1.4.5→HEAD column delta the binary will no longer auto-add post-simplification.
--     2. row_idx_alive partial removed and DROP-ed if present (D1: unused —
--        getItemIdFromIdMap has no deprecated predicate, so the planner cannot use
--        a deprecated=FALSE partial; the post-simplification createShardMapTable drops it).
--     3. ctxt_map deprecated partial added — post-simplification, createCtxtMapTable builds
--        it only for NEW indexes, so existing indexes need it created here.
--   These keep a 1.4.5-upgraded deployment schema-identical to a fresh post-simplification
--   install.
--
-- Named partitions. PART A also adds indexes.parent_index_name and the partitions
--   table (+ _default backfill) — the global delta initSchema builds on a fresh
--   install. Additive + idempotent. See docs/design/partitions.md.
--
-- Changes:
--   1. Rename table: <idx>_shard_map → <idx>_item_shard_map (clearer
--      semantics — the row is "which shard does this item live in", not
--      "the map of a shard").
--   2. PK changes from `item_id` to `(shard_id, item_id)`.
--   3. Drop `id_in_shard` column (derived from sort-by-item_id position).
--   4. Drop <idx>_shard_map_legacy entirely (no longer needed after PK change).
--   5. Re-attach FK item_id → <idx>_ctxt_map(item_id) ON UPDATE/DELETE CASCADE
--      so a migrated table matches the new-index path (createShardMapTable in
--      index_shardmap.go, which attaches this FK explicitly).
--   6. Create <idx>_item_merge_lock if missing. This is a PRE-EXISTING main gap
--      (PR #1870): the binary only creates it for NEW indexes, so indexes that
--      predate #1870 lack it and the first merge (claimItemsForMerge) fails with
--      "relation does not exist". Backfilled here in the same app-stopped window.
--
-- Authoritative migration: this file is the single source of truth for the
-- shard_map → item_shard_map upgrade. It supersedes
-- 2026-04-22_delete_data_indexes.sql — that script's _shard_map indexes are
-- obsolete after the rename. Post-simplification the binary builds idx_task_queue_target_shard_id
-- and the per-index ctxt_map/item_shard_map deprecated partials ONLY on fresh install
-- (initSchema / createShardMapTable / createCtxtMapTable); existing deployments get
-- them from THIS script (PART A task_queue partial; Step 6 item_shard_map partials;
-- Step 6c ctxt_map deprecated).
--
-- Relationship to migrateAll (in-binary startup migration, init.go):
--   * migrateAll is idempotent + additive only: ADD COLUMN IF NOT EXISTS,
--     CREATE INDEX [CONCURRENTLY] IF NOT EXISTS, CreateTable-if-absent. It does
--     NOT rename tables, change PKs, or backfill row_idx — that is this script.
--   * BOOT ORDER (critical): run this script with the app STOPPED, BEFORE
--     deploying the new binary. On an un-migrated DB the new binary's
--     ensureDeprecatedColumnsOnPerIndexTables runs `ALTER TABLE
--     <idx>_item_shard_map ADD COLUMN ...`; IF NOT EXISTS guards the column,
--     not the table, so it fails with "relation does not exist" and aborts
--     startup. This script must create <idx>_item_shard_map first.
--   * Per-index index set: this script builds idx_<idx>_item_shard_map_{item_id,
--     alive,deprecated} in-window (non-CONCURRENTLY, on the fresh table) plus the
--     ctxt_map deprecated partial — exactly the post-simplification createShardMapTable /
--     createCtxtMapTable fresh-install output. Pre-simplification, ensureDeprecatedPartialIndexes
--     re-created the item_shard_map partials async with the SAME names (IF NOT
--     EXISTS kept both paths idempotent); post-simplification that goroutine is gone, so this
--     script is the sole builder for existing indexes. The unused row_idx_alive
--     partial is NOT created and is dropped if a pre-simplification boot left one (Step 6).
--
-- Invariants this migration assumes:
--   * Application is stopped or in feature-frozen mode during migration.
--     New code that understands the new schema MUST be deployed before
--     resuming traffic.
--   * Shard blobs are immutable per shard_id (confirmed 2026-05-26).
--   * Items inside a shard are stored sorted by item_id (confirmed 2026-05-26).
--
-- Execution:
--   Run each per-index block individually. Generate the per-index list with:
--     SELECT lower(index_name) FROM indexes;
--
-- Replace `<index_name>` with the lowercased index name for each block.
-- For large indexes (> 1M rows) the rebuild may take several minutes; plan
-- accordingly. The TRANSACTION wrap below makes each per-index block atomic
-- — partial rollback is automatic on error.

-- ============================================================================
-- PART A — Global schema delta (run ONCE; idempotent — added 2026-06-04)
-- ============================================================================
-- The 1.4.5→HEAD global column delta the binary's migrateAll used to add on boot
-- (keys.status via ensureKeyStatusColumnAndBackfill; shards.owner_merge_task_id
-- via ensureShardOwnerMergeTaskIDColumn). Post-simplification the binary no longer adds
-- these, so the script carries them. import_log and indexes.import_id/ct_trunc
-- already exist in 1.4.5, so they are NOT here (they are in the 1.4.0-1.4.4 script only).
-- Run ONCE before the per-index loop (its own transaction below). If the runbook
-- sed-loop pipes this whole file per index, PART A re-runs harmlessly — every
-- statement is ADD COLUMN / CREATE INDEX IF NOT EXISTS, a no-op after the first.

BEGIN;

-- keys.status — NOT NULL default 'active' backfills pre-migration rows to active.
ALTER TABLE keys ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'active';

-- shards.owner_merge_task_id — nullable BIGINT, no default. NULL = legacy/unowned
-- (claimable), so a plain ADD COLUMN is the full migration; no backfill.
ALTER TABLE shards ADD COLUMN IF NOT EXISTS owner_merge_task_id BIGINT;

-- keys cleanup-worker getKeysWithStaleStatus probe (status IN pending/deleting).
CREATE INDEX IF NOT EXISTS idx_keys_status_transient
    ON keys (status, updated_at)
    WHERE status IN ('pending', 'deleting');

-- DeleteData task_queue probe. Pre-simplification the ensureDeprecatedPartialIndexes goroutine
-- built this on every boot; post-simplification the binary builds it ONLY in initSchema (fresh
-- install), so existing 1.4.5 deployments must get it here — otherwise the post-simplification
-- binary would build it non-CONCURRENTLY at boot on a populated task_queue. Mirrors
-- the 1.4.0-1.4.4 script and initSchema (D7). The column predates 1.4.5, so this is
-- index-only.
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
-- Per-index block template (repeat for every index)
-- ============================================================================

BEGIN;

-- Step 1: Sanity check — confirm the source table has the expected old schema.
-- Aborts the transaction if id_in_shard is already gone (migration already run)
-- or if the source table is already item_shard_map (rename already complete).
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

-- Step 2: Create the new item_shard_map table with the new PK.
-- row_idx replaces id_in_shard as the 0-based slot inside the shard; the new
-- code reads it directly (the per-shard search engine probes by row_idx).
-- Using a new table + INSERT SELECT is safer than ALTER TABLE on large data:
--   * The new table is built without holding a long-running table lock on the
--     production-active old table.
--   * Rollback is just DROP TABLE <new>; no partial state.
CREATE TABLE <index_name>_item_shard_map (
    shard_id   VARCHAR(20) NOT NULL,
    item_id    BIGINT      NOT NULL,
    row_idx    BIGINT      NOT NULL,
    deprecated BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (shard_id, item_id)
);

-- Step 3: Backfill from old → new.
-- row_idx is derived from sort-by-item_id position within each shard
-- (ROW_NUMBER() OVER (PARTITION BY shard_id ORDER BY item_id) - 1), which is
-- the same convention the new code emits at cutover INSERT. We partition only
-- by shard_id (not shard_id + deprecated) so row_idx matches the immutable
-- shard-blob position over ALL rows; alive rows are NOT required to be
-- contiguous (soft-deleted rows keep their slot, leaving gaps). The old
-- id_in_shard column is read only to validate row counts; the values are
-- discarded because the new code does not rely on the source numbering.
-- ON CONFLICT DO NOTHING handles any duplicate (shard_id, item_id) rows that
-- might exist if the old table somehow contained dupes; under normal
-- operation this is a no-op.
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

-- Step 4: Sanity check — row counts.
-- For a healthy index, NEW count = OLD count (every item_id is in exactly one
-- shard under the old item_id PK, so no dupes possible). Any divergence
-- indicates corruption — abort to investigate.
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

-- Step 5: Retain old table for rollback. Renamed (not dropped) so a fast
-- rollback (rename back) is possible during the first few hours post-deploy.
-- The cleanup of _old tables is in the "Post-migration retention cleanup"
-- block below; run ≥ 24 hours later.
ALTER TABLE <index_name>_shard_map RENAME TO <index_name>_shard_map_old;

-- Step 6: Indexes on the new item_shard_map table — exactly the set the post-simplification
-- createShardMapTable produces on a fresh install (D1).
-- (a) item_id lookup (DeleteData soft-delete UPDATE WHERE item_id, etc.)
CREATE INDEX IF NOT EXISTS idx_<index_name>_item_shard_map_item_id
    ON <index_name>_item_shard_map (item_id);
-- (b) "alive rows per shard" hot path
--     Partial index column set == PK column set; the partial WHERE clause
--     filters out deprecated rows so the index is smaller than the PK
--     when the deprecated ratio is non-trivial.
CREATE INDEX IF NOT EXISTS idx_<index_name>_item_shard_map_alive
    ON <index_name>_item_shard_map (shard_id, item_id)
    WHERE deprecated = FALSE;
-- (c) "deprecated rows" cleanup_worker scan path
CREATE INDEX IF NOT EXISTS idx_<index_name>_item_shard_map_deprecated
    ON <index_name>_item_shard_map (shard_id)
    WHERE deprecated = TRUE;
-- (d) Drop the unused row_idx_alive partial. getItemIdFromIdMap probes by
--     (shard_id, row_idx) with NO deprecated predicate, so the planner cannot use
--     a deprecated=FALSE partial — it is write overhead only (D1). 1.4.5 itself
--     never created idx_<idx>_item_shard_map_row_idx_alive (its goroutine targeted
--     the OLD <idx>_shard_map table); this DROP only fires for a DB already booted
--     on pre-simplification HEAD, where ensureDeprecatedPartialIndexes built it under this
--     exact name. Harmless no-op otherwise, and keeps a 1.4.5-upgraded deployment
--     schema-identical to a fresh post-simplification install.
DROP INDEX IF EXISTS idx_<index_name>_item_shard_map_row_idx_alive;

-- Step 6b: Foreign key item_id → <index_name>_ctxt_map(item_id).
-- Matches the new-index path (createShardMapTable, index_shardmap.go), which
-- attaches this FK explicitly. ON DELETE CASCADE so removing a ctxt_map row
-- cascades to its shard_map rows; ON UPDATE CASCADE mirrors the model tag.
-- Added after the backfill so PostgreSQL validates it in one scan; the
-- statement aborts the transaction if any migrated item_id has no ctxt_map
-- row (i.e. source corruption) — investigate before retrying.
ALTER TABLE <index_name>_item_shard_map
    ADD FOREIGN KEY (item_id) REFERENCES <index_name>_ctxt_map (item_id)
    ON UPDATE CASCADE ON DELETE CASCADE;

-- Step 6c: ctxt_map deprecated partial (cleanup_worker Phase B scan). Pre-simplification the
-- ensureDeprecatedPartialIndexes goroutine built this async; post-simplification,
-- createCtxtMapTable builds it only for NEW indexes, so existing indexes need it
-- here. <idx>_ctxt_map already carries the deprecated column (since 1.4.0), so no
-- ADD COLUMN is needed. ctxt_map is the pre-existing table (not recreated by this
-- transform); non-CONCURRENTLY is safe in the app-stopped window.
CREATE INDEX IF NOT EXISTS idx_<index_name>_ctxt_map_deprecated
    ON <index_name>_ctxt_map (item_id)
    WHERE deprecated = TRUE;

-- Step 7: Drop the legacy retention table — no longer needed.
-- The old shard_map_legacy held pre-merge coordinate snapshots for the 5-min
-- GetMetadata fallback. Under the new PK, cutover INSERTs the new
-- (shard_id, item_id) pair without overwriting any prior row, so the
-- coordinate is preserved in place until the (now deprecated) prior row is
-- explicitly hard-deleted by cleanup_worker. No sidecar needed.
DROP TABLE IF EXISTS <index_name>_shard_map_legacy;

-- Step 8: Backfill the per-index merge-lock table (pre-existing main gap, PR #1870).
-- The binary creates <index_name>_item_merge_lock only at index-creation time
-- (createItemMergeLockTable is reached only via createShardMapTable), so indexes
-- created before #1870 never get it and the first merge — claimItemsForMerge —
-- fails with "relation does not exist". IF NOT EXISTS makes this a no-op for
-- indexes that already have it. Schema mirrors the ItemMergeLock model.
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
-- Post-migration retention cleanup (run separately, ≥ 24 hours later)
-- ============================================================================
-- Once production has run on the new schema for at least one full operational
-- day without incident, drop the _old tables to reclaim disk:
--
--   DROP TABLE IF EXISTS <index_name>_shard_map_old;
--
-- Until that point, an emergency rollback is:
--   BEGIN;
--   ALTER TABLE <index_name>_item_shard_map RENAME TO <index_name>_item_shard_map_failed;
--   ALTER TABLE <index_name>_shard_map_old  RENAME TO <index_name>_shard_map;
--   COMMIT;
-- (combined with redeploying the previous application binary that expected
--  the old <idx>_shard_map name + id_in_shard column).

-- ============================================================================
-- Validation queries (run after migration, before resuming traffic)
-- ============================================================================
-- Verify new table schema:
--   \d <index_name>_item_shard_map
--   -- expect: PRIMARY KEY (shard_id, item_id),
--   --         columns {shard_id, item_id, row_idx, deprecated, created_at, updated_at}
--   -- NOT expect: id_in_shard column
--
-- Verify (shard_id, row_idx) uniqueness — the new code joins on this pair with
-- no deprecated filter, so a collision resolves ambiguously. Do NOT assert
-- alive-only 0..N-1 contiguity: soft-deleted rows keep their row_idx slot, so
-- alive row_idx legitimately has gaps on mixed-state shards.
--   SELECT shard_id, row_idx, COUNT(*)
--   FROM <index_name>_item_shard_map
--   GROUP BY shard_id, row_idx
--   HAVING COUNT(*) > 1;
--   -- expect: empty result (each (shard_id, row_idx) maps to exactly one item)
--
-- Verify legacy is gone:
--   SELECT EXISTS (
--       SELECT 1 FROM information_schema.tables
--       WHERE table_name = '<index_name>_shard_map_legacy'
--   );
--   -- expect: false
--
-- Verify old table is renamed (not dropped yet):
--   SELECT EXISTS (
--       SELECT 1 FROM information_schema.tables
--       WHERE table_name = '<index_name>_shard_map_old'
--   );
--   -- expect: true (drop after 24h stability)
--
-- Verify row_count invariant (distinct alive items):
--   SELECT COUNT(DISTINCT item_id) FROM <index_name>_item_shard_map WHERE deprecated = FALSE;
--   -- should match indexes.row_count for this index
