-- Serialize listing deletion with concurrent image attachment and cleanup claims.
-- Candidate migration only: do not apply to production without owner approval.

create or replace function public.lock_storage_image_detachment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $detach$
declare
  image_lock record;
  bucket_name text;
begin
  bucket_name := case
    when old.status = 'pending' then 'pending-images'
    when old.status = 'approved' and tg_table_name = 'market_posts' then 'market-images'
    when old.status = 'approved' then 'listing-images'
    else null
  end;

  if bucket_name is not null then
    for image_lock in
      select distinct paths.path as object_path
        from pg_catalog.unnest(coalesce(old.image_urls, array[]::text[])) as paths(path)
       where paths.path is not null
       order by paths.path
    loop
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(bucket_name || ':' || image_lock.object_path, 0)
      );
    end loop;
  end if;

  return old;
end;
$detach$;

revoke all on function public.lock_storage_image_detachment() from public, anon, authenticated;

drop trigger if exists lock_service_request_image_detachment on public.service_requests;
create trigger lock_service_request_image_detachment
before delete on public.service_requests
for each row execute function public.lock_storage_image_detachment();

drop trigger if exists lock_job_post_image_detachment on public.job_posts;
create trigger lock_job_post_image_detachment
before delete on public.job_posts
for each row execute function public.lock_storage_image_detachment();

drop trigger if exists lock_real_estate_image_detachment on public.real_estate_posts;
create trigger lock_real_estate_image_detachment
before delete on public.real_estate_posts
for each row execute function public.lock_storage_image_detachment();

drop trigger if exists lock_market_post_image_detachment on public.market_posts;
create trigger lock_market_post_image_detachment
before delete on public.market_posts
for each row execute function public.lock_storage_image_detachment();

-- The BEFORE DELETE trigger holds the same per-object transaction lock as
-- attachment and worker-claim triggers until the deletion transaction commits.
-- Thus a concurrent attachment either commits first (and is seen by the
-- reference check) or waits and then sees the cleanup reservation.

-- When an edit or deletion removes the final reference to a previously deferred
-- object, reactivate its staged job in the same transaction. The BEFORE triggers
-- above and the attachment guard already hold the per-object advisory lock.
create or replace function public.reactivate_deferred_storage_cleanup_jobs()
returns trigger
language plpgsql
security definer
set search_path = ''
as $reactivate$
declare
  bucket_name text;
  image_path text;
begin
  bucket_name := case
    when old.status = 'pending' then 'pending-images'
    when old.status = 'approved' and tg_table_name = 'market_posts' then 'market-images'
    when old.status = 'approved' then 'listing-images'
    else null
  end;

  if bucket_name is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;

  for image_path in
    select distinct paths.path
      from pg_catalog.unnest(coalesce(old.image_urls, array[]::text[])) as paths(path)
     where paths.path is not null
     order by paths.path
  loop
    if not public.is_storage_cleanup_object_referenced(bucket_name, image_path) then
      update public.storage_cleanup_jobs
         set status = 'pending',
             attempts = 0,
             lease_until = null,
             lease_token = null,
             last_error = null,
             completed_at = null,
             updated_at = pg_catalog.now()
       where bucket = bucket_name
         and object_path = image_path
         and status = 'staged'
         and last_error = 'Image is still referenced by a live listing; deferred until the final reference is removed';
    end if;
  end loop;

  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$reactivate$;

revoke all on function public.reactivate_deferred_storage_cleanup_jobs() from public, anon, authenticated;

drop trigger if exists reactivate_service_request_image_cleanup on public.service_requests;
create trigger reactivate_service_request_image_cleanup
after update of status, image_urls or delete on public.service_requests
for each row execute function public.reactivate_deferred_storage_cleanup_jobs();

drop trigger if exists reactivate_job_post_image_cleanup on public.job_posts;
create trigger reactivate_job_post_image_cleanup
after update of status, image_urls or delete on public.job_posts
for each row execute function public.reactivate_deferred_storage_cleanup_jobs();

drop trigger if exists reactivate_real_estate_image_cleanup on public.real_estate_posts;
create trigger reactivate_real_estate_image_cleanup
after update of status, image_urls or delete on public.real_estate_posts
for each row execute function public.reactivate_deferred_storage_cleanup_jobs();

drop trigger if exists reactivate_market_post_image_cleanup on public.market_posts;
create trigger reactivate_market_post_image_cleanup
after update of status, image_urls or delete on public.market_posts
for each row execute function public.reactivate_deferred_storage_cleanup_jobs();
