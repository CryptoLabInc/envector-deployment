-- 1.4.7_to_latest.sql — additive global delta beyond 1.4.7-alpha.
--
-- Target: instances that already reached the prior latest (1.4.7-alpha) and no longer
--       re-run the 1.4.5-1.4.6 / 1.4.0-1.4.4 scripts. Beyond the created_shard_list
--       delta + Step 6 (shard_id, row_idx) index those two scripts added in PART A, it
--       also carries the index_operations.orphaned_blob_paths column +
--       (operation_type, state) index that update added, and the shards.row_add_count
--       column single-insert immediate search (ES2-2164) added.
--
-- created_shard_list: 머지 destination shardID들의 JSON []string. shaper blob
-- 쓰기 BEFORE에 기록되는 intent-first 앵커로, 크래시 후 살아남은 비-빈 값은
-- pending shards 행이 끝내 INSERT되지 못한 고아 blob을 가리킨다(기동 reclaim
-- 스윕이 회수). '' = dispatch 진행 중 아님.
--
-- 멱등: ADD COLUMN IF NOT EXISTS / CREATE INDEX ... IF NOT EXISTS. 재실행해도 no-op.
-- 신규 install은 initSchema의 CreateTable(&TaskQueue{}) / createShardMapTable이
-- 모델·코드에서 자동 생성하므로 본 스크립트가 필요 없다.
-- orphaned_blob_paths: JSON []string of blobs the update swap TX orphaned, written
-- atomically with the commit. A non-empty value = a committed swap's post-commit
-- reclaim is incomplete (sweepOrphanedUpdateBlobs clears it after reclaim). '' = none.
--
-- shards.row_add_count: single-row unzip+append count (ES2-2164). Caps the append
-- path at the EVI accumulator's RLWE degree (1024), and > 0 marks the shard as an
-- appended raw shard that merge cutover treats as an overlap buffer. Merge-grown
-- shards keep the 0 default, so no backfill.
BEGIN;
ALTER TABLE task_queue ADD COLUMN IF NOT EXISTS created_shard_list text DEFAULT '';
-- operation_type: mutation that spawned the merge task (INSERT/DELETE/UPDATE).
-- Nullable; NULL rows fall back to the TargetShardID heuristic on recovery.
ALTER TABLE task_queue ADD COLUMN IF NOT EXISTS operation_type text;
ALTER TABLE index_operations ADD COLUMN IF NOT EXISTS orphaned_blob_paths text DEFAULT '';
ALTER TABLE shards ADD COLUMN IF NOT EXISTS row_add_count bigint NOT NULL DEFAULT 0;
ALTER TABLE shards ADD COLUMN IF NOT EXISTS is_frozen boolean NOT NULL DEFAULT false;
-- Backfill: the old freeze mechanism set row_add_count = MaxRowAddCount
-- (ceiling 1024). Without this, previously frozen shards would pass the
-- new is_frozen=false filter and re-enter the append target pool.
UPDATE shards SET is_frozen = true
 WHERE is_raw = true AND row_add_count >= 1024 AND is_frozen = false;
COMMIT;

-- Step 6: full (shard_id, row_idx) index on every existing item_shard_map (search
-- hot-path resolution; see 1.4.0-1.4.6 Step 6). CONCURRENTLY → runs OUTSIDE the tx
-- above, idempotent via IF NOT EXISTS. INVALID-index recovery: see runbook §1-1.
SELECT format(
    'CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_%s_shard_row ON %I (shard_id, row_idx)',
    tablename, tablename)
FROM pg_tables
WHERE schemaname = 'public' AND tablename LIKE '%\_item\_shard\_map'
\gexec

-- (operation_type, state) composite index on index_operations: the update
-- reconciliation/backstop sweeps scan by this pair. Name matches the GORM tag so
-- fresh-install (initSchema) and upgrade converge. CONCURRENTLY → outside a tx.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_index_operations_type_state
    ON index_operations (operation_type, state);
