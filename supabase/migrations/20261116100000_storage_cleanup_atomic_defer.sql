-- Atomically defer a claimed cleanup job while serializing with final image detachment.
-- Candidate migration only: do not apply to production without owner approval.

create or replace function public.defer_storage_cleanup_job(
  p_id bigint,
  p_bucket text,
  p_object_path text,
  p_lease_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $defer$
declare
  current_job public.storage_cleanup_jobs%rowtype;
  still_referenced boolean;
begin
  if p_id is null
     or p_bucket is null
     or p_bucket not in ('listing-images', 'market-images', 'pending-images')
     or p_object_path is null
     or p_lease_token is null then
    return false;
  end if;

  -- Keep the global lock order identical to attachment, detachment, and claim:
  -- object advisory lock first, then the cleanup queue row lock.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_bucket || ':' || p_object_path, 0)
  );

  select *
    into current_job
    from public.storage_cleanup_jobs
   where id = p_id
     and bucket = p_bucket
     and object_path = p_object_path
     and status = 'processing'
     and lease_token = p_lease_token
   for update;

  if not found then
    return false;
  end if;

  still_referenced := public.is_storage_cleanup_object_referenced(p_bucket, p_object_path);

  if still_referenced then
    update public.storage_cleanup_jobs
       set status = 'staged',
           attempts = 0,
           lease_until = null,
           lease_token = null,
           last_error = 'Image is still referenced by a live listing; deferred until the final reference is removed',
           completed_at = null,
           updated_at = pg_catalog.now()
     where id = p_id;
  else
    -- A final detachment may have committed after the worker's earlier
    -- reference check. Requeue immediately instead of leaving a stale staged job.
    update public.storage_cleanup_jobs
       set status = 'pending',
           attempts = 0,
           lease_until = null,
           lease_token = null,
           last_error = null,
           completed_at = null,
           updated_at = pg_catalog.now()
     where id = p_id;
  end if;

  return true;
end;
$defer$;

revoke all on function public.defer_storage_cleanup_job(bigint, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.defer_storage_cleanup_job(bigint, text, text, uuid)
  to service_role;
