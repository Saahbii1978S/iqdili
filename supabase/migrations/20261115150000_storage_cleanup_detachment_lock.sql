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
