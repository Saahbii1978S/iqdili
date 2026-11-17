#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL must point to the disposable CI PostgreSQL database}"

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

# This script runs after storage-cleanup-queue.sql, which creates the minimal
# listing tables and applies the actual candidate migrations. No synthetic
# lock-protocol schema or reimplemented trigger/function is used here.
sql "update public.storage_cleanup_jobs
       set status='completed', lease_until=null, lease_token=null
     where object_path not like 'race/%'"

# 1. The actual worker claim wins the per-object advisory lock. A concurrent
# listing attachment waits, then the real attachment trigger rejects it.
sql "insert into public.storage_cleanup_jobs(bucket,object_path,status,updated_at)
     values ('listing-images','race/claim-first.jpg','pending',now()-interval '1 day')"
start_holder claim_first "begin; set local role service_role; select object_path from public.claim_storage_cleanup_jobs(1); select pg_sleep(1); commit;"
if sql "insert into public.service_requests(user_id,title,status,image_urls)
        values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','race claim first','approved',array['race/claim-first.jpg'])" >/tmp/claim-attach.log 2>&1; then
  echo "Attachment unexpectedly succeeded after the real worker claim" >&2; exit 1
fi
finish_holder claim_first
[[ "$(sql "select status from public.storage_cleanup_jobs where object_path='race/claim-first.jpg'")" == "processing" ]]

# 2. Attachment wins the same lock while a cleanup job is staged. The real
# worker claim waits, rechecks references, and leaves the job staged.
sql "insert into public.storage_cleanup_jobs(bucket,object_path,status,updated_at)
     values ('listing-images','race/attach-first.jpg','staged',now()-interval '1 day')"
start_holder attach_first "begin; insert into public.service_requests(user_id,title,status,image_urls) values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','race attach first','approved',array['race/attach-first.jpg']); select pg_sleep(1); commit;"
CLAIM_COUNT="$(sql "begin; set local role service_role; select count(*) from public.claim_storage_cleanup_jobs(1); commit;")"
finish_holder attach_first
[[ "$CLAIM_COUNT" == "0" ]]
[[ "$(sql "select status from public.storage_cleanup_jobs where object_path='race/attach-first.jpg'")" == "staged" ]]

# 3. Final detachment commits before the worker's real defer RPC. The RPC
# rechecks references under the advisory lock and requeues the object.
sql "insert into public.service_requests(user_id,title,status,image_urls)
     values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','race detach first','approved',array['race/detach-first.jpg'])"
sql "insert into public.storage_cleanup_jobs(bucket,object_path,status,lease_token,lease_until)
     values ('listing-images','race/detach-first.jpg','processing','dddddddd-dddd-4ddd-8ddd-dddddddddddd',now()+interval '5 minutes')"
DEFER_ID="$(sql "select id from public.storage_cleanup_jobs where object_path='race/detach-first.jpg'")"
start_holder detach_first "begin; delete from public.service_requests where title='race detach first'; select pg_sleep(1); commit;"
DEFER_RESULT="$(sql "begin; set local role service_role; select public.defer_storage_cleanup_job($DEFER_ID,'listing-images','race/detach-first.jpg','dddddddd-dddd-4ddd-8ddd-dddddddddddd'); commit;")"
finish_holder detach_first
[[ "$DEFER_RESULT" == "t" ]]
[[ "$(sql "select status from public.storage_cleanup_jobs where id=$DEFER_ID")" == "pending" ]]

# 4. The real defer RPC wins while a reference still exists. The subsequent
# final DELETE runs its real triggers and reactivates the staged job.
sql "insert into public.service_requests(user_id,title,status,image_urls)
     values ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','race defer first','approved',array['race/defer-first.jpg'])"
sql "insert into public.storage_cleanup_jobs(bucket,object_path,status,lease_token,lease_until)
     values ('listing-images','race/defer-first.jpg','processing','ffffffff-ffff-4fff-8fff-ffffffffffff',now()+interval '5 minutes')"
DEFER_ID="$(sql "select id from public.storage_cleanup_jobs where object_path='race/defer-first.jpg'")"
start_holder defer_first "begin; set local role service_role; select public.defer_storage_cleanup_job($DEFER_ID,'listing-images','race/defer-first.jpg','ffffffff-ffff-4fff-8fff-ffffffffffff'); select pg_sleep(1); commit;"
sql "delete from public.service_requests where title='race defer first'"
finish_holder defer_first
[[ "$(sql "select status from public.storage_cleanup_jobs where id=$DEFER_ID")" == "pending" ]]

echo "Actual-migration Storage cleanup concurrency tests passed (4 two-session races)."
