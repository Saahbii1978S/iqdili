#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL must point to the disposable CI PostgreSQL database}"
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/storage-cleanup-concurrency-setup.sql >/dev/null

sql() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c "$1"; }
wait_until_sleeping() {
  local app="$1"
  for _ in $(seq 1 100); do
    if [[ "$(sql "select count(*) from pg_stat_activity where application_name='$app' and query like '%pg_sleep%'")" == "1" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "Timed out waiting for concurrent transaction $app" >&2
  return 1
}
start_holder() {
  local app="$1" statement="$2"
  PGAPPNAME="$app" psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -c "$statement" >/tmp/"$app".log 2>&1 &
  HOLDER_PID=$!
  wait_until_sleeping "$app"
}
finish_holder() {
  wait "$HOLDER_PID" || { cat /tmp/"$1".log >&2; return 1; }
}

# 1. Worker claim wins the object lock: a concurrent attachment must wait,
# then be rejected after the job becomes processing.
sql "insert into cleanup_concurrency.cleanup_jobs(bucket,object_path,status,lease_token) values ('listing-images','race/claim-first.jpg','pending',gen_random_uuid())"
start_holder claim_first "begin; select cleanup_concurrency.claim_one(); select pg_sleep(1); commit;"
if sql "insert into cleanup_concurrency.listings(bucket,object_path) values ('listing-images','race/claim-first.jpg')" >/tmp/claim-attach.log 2>&1; then
  echo "Attachment unexpectedly succeeded after worker claim" >&2; exit 1
fi
finish_holder claim_first
[[ "$(sql "select status from cleanup_concurrency.cleanup_jobs where object_path='race/claim-first.jpg'")" == "processing" ]]

# 2. Attachment wins the object lock before cleanup enqueue: enqueue must
# observe the committed reference and create a staged job, never a pending one.
start_holder attach_first "begin; insert into cleanup_concurrency.listings(bucket,object_path) values ('listing-images','race/attach-first.jpg'); select pg_sleep(1); commit;"
ENQUEUE_RESULT="$(sql "select cleanup_concurrency.enqueue_one('listing-images','race/attach-first.jpg')")"
finish_holder attach_first
[[ "$ENQUEUE_RESULT" == "staged" ]]
[[ "$(sql "select status from cleanup_concurrency.cleanup_jobs where object_path='race/attach-first.jpg'")" == "staged" ]]

# 3. Final detachment commits before the worker's defer request: defer must
# recheck references under the lock and requeue the now-unreferenced object.
sql "insert into cleanup_concurrency.listings(bucket,object_path) values ('listing-images','race/detach-first.jpg')"
sql "insert into cleanup_concurrency.cleanup_jobs(bucket,object_path,status,lease_token) values ('listing-images','race/detach-first.jpg','processing',gen_random_uuid())"
DEFER_ID="$(sql "select id from cleanup_concurrency.cleanup_jobs where object_path='race/detach-first.jpg'")"
start_holder detach_first "begin; delete from cleanup_concurrency.listings where object_path='race/detach-first.jpg'; select pg_sleep(1); commit;"
DEFER_RESULT="$(sql "select cleanup_concurrency.defer_one($DEFER_ID)")"
finish_holder detach_first
[[ "$DEFER_RESULT" == "pending" ]]
[[ "$(sql "select status from cleanup_concurrency.cleanup_jobs where id=$DEFER_ID")" == "pending" ]]

# 4. Worker defer wins the object lock while a reference still exists:
# final detachment must reactivate the staged job in its own transaction.
sql "insert into cleanup_concurrency.listings(bucket,object_path) values ('listing-images','race/defer-first.jpg')"
sql "insert into cleanup_concurrency.cleanup_jobs(bucket,object_path,status,lease_token) values ('listing-images','race/defer-first.jpg','processing',gen_random_uuid())"
DEFER_ID="$(sql "select id from cleanup_concurrency.cleanup_jobs where object_path='race/defer-first.jpg'")"
start_holder defer_first "begin; select cleanup_concurrency.defer_one($DEFER_ID); select pg_sleep(1); commit;"
sql "delete from cleanup_concurrency.listings where object_path='race/defer-first.jpg'"
finish_holder defer_first
[[ "$(sql "select status from cleanup_concurrency.cleanup_jobs where id=$DEFER_ID")" == "pending" ]]

echo "Storage cleanup concurrency lock-protocol tests passed (4 two-session races)."
