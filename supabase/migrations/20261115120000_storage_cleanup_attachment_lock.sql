-- Serialize image attachment and Storage deletion decisions with one per-object advisory lock.
-- Candidate migration only: do not apply to production without owner approval.

create or replace function public.guard_storage_image_attachment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $guard$
declare
  old_status text;
  old_images text[];
  new_status text;
  new_images text[];
  image_lock record;
begin
  if tg_op = 'UPDATE' then
    old_status := old.status;
    old_images := coalesce(old.image_urls, array[]::text[]);
  end if;
  new_status := new.status;
  new_images := coalesce(new.image_urls, array[]::text[]);

  -- Lock all active old/new object locators in deterministic order. The worker's
  -- claim RPC takes the identical lock before changing a job to processing.
  for image_lock in
    select distinct refs.bucket, refs.object_path
      from (
        select
          case
            when source.status = 'pending' then 'pending-images'
            when source.status = 'approved' and tg_table_name = 'market_posts' then 'market-images'
            when source.status = 'approved' then 'listing-images'
            else null
          end as bucket,
          unnest(source.image_urls) as object_path
        from (
          select old_status as status, old_images as image_urls
          union all
          select new_status as status, new_images as image_urls
        ) source
      ) refs
     where refs.bucket is not null
       and refs.object_path is not null
     order by refs.bucket, refs.object_path
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(image_lock.bucket || ':' || image_lock.object_path, 0)
    );
  end loop;

  -- Once cleanup is pending, leased, completed, or exhausted, a path is
  -- permanently retired and cannot be attached to a new/updated listing.
  -- Staged uploads remain attachable until the worker atomically claims them.
  if new_status in ('pending','approved') then
    if exists (
      select 1
        from pg_catalog.unnest(new_images) as paths(path)
        join public.storage_cleanup_jobs cleanup
          on cleanup.object_path = paths.path
         and cleanup.bucket = case
           when new_status = 'pending' then 'pending-images'
           when tg_table_name = 'market_posts' then 'market-images'
           else 'listing-images'
         end
       where cleanup.status in ('pending','processing','completed','dead_letter')
    ) then
      raise exception 'Image is reserved for cleanup and cannot be attached to a listing';
    end if;
  end if;

  return new;
end;
$guard$;

revoke all on function public.guard_storage_image_attachment() from public, anon, authenticated;

drop trigger if exists guard_service_request_image_cleanup on public.service_requests;
create trigger guard_service_request_image_cleanup
before insert or update of status, image_urls on public.service_requests
for each row execute function public.guard_storage_image_attachment();

drop trigger if exists guard_job_post_image_cleanup on public.job_posts;
create trigger guard_job_post_image_cleanup
before insert or update of status, image_urls on public.job_posts
for each row execute function public.guard_storage_image_attachment();

drop trigger if exists guard_real_estate_image_cleanup on public.real_estate_posts;
create trigger guard_real_estate_image_cleanup
before insert or update of status, image_urls on public.real_estate_posts
for each row execute function public.guard_storage_image_attachment();

drop trigger if exists guard_market_post_image_cleanup on public.market_posts;
create trigger guard_market_post_image_cleanup
before insert or update of status, image_urls on public.market_posts
for each row execute function public.guard_storage_image_attachment();

-- A claim and an attachment now serialize on the same object lock:
-- * if the attachment commits first, the claim sees the reference and defers;
-- * if the claim commits first, the attachment sees processing and is rejected.
create or replace function public.claim_storage_cleanup_jobs(p_limit integer default 20)
returns table(id bigint, bucket text, object_path text, attempts integer, lease_token uuid)
language plpgsql
security invoker
set search_path = ''
as $claim$
declare
  candidate record;
  current_job public.storage_cleanup_jobs%rowtype;
begin
  for candidate in
    select j.id, j.bucket, j.object_path
      from public.storage_cleanup_jobs j
     where (
       (j.status = 'pending'
         and (
           j.attempts = 0
           or j.updated_at < pg_catalog.now() - pg_catalog.make_interval(
             mins => least(60, pg_catalog.power(2, least(j.attempts, 6))::integer)
           )
         ))
       or (j.status = 'processing' and j.lease_until < pg_catalog.now())
       or (j.status = 'staged' and j.updated_at < pg_catalog.now() - interval '10 minutes')
     )
     order by j.updated_at, j.id
     for update skip locked
     limit least(greatest(coalesce(p_limit, 20), 1), 25)
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(candidate.bucket || ':' || candidate.object_path, 0)
    );

    select j.* into current_job
      from public.storage_cleanup_jobs j
     where j.id = candidate.id
     for update;

    if not found then
      continue;
    end if;

    if public.is_storage_cleanup_object_referenced(current_job.bucket, current_job.object_path) then
      update public.storage_cleanup_jobs
         set status = 'staged',
             attempts = 0,
             lease_until = null,
             lease_token = null,
             last_error = 'Image is still referenced by a live listing; deferred until the final reference is removed',
             updated_at = pg_catalog.now()
       where storage_cleanup_jobs.id = current_job.id;
      continue;
    end if;

    if current_job.attempts >= 8 then
      update public.storage_cleanup_jobs
         set status = 'dead_letter',
             lease_until = null,
             lease_token = null,
             last_error = coalesce(last_error, 'Maximum retry count reached'),
             updated_at = pg_catalog.now()
       where storage_cleanup_jobs.id = current_job.id;
      continue;
    end if;

    update public.storage_cleanup_jobs
       set status = 'processing',
           attempts = storage_cleanup_jobs.attempts + 1,
           lease_until = pg_catalog.now() + interval '5 minutes',
           lease_token = pg_catalog.gen_random_uuid(),
           updated_at = pg_catalog.now()
     where storage_cleanup_jobs.id = current_job.id
     returning storage_cleanup_jobs.* into current_job;

    id := current_job.id;
    bucket := current_job.bucket;
    object_path := current_job.object_path;
    attempts := current_job.attempts;
    lease_token := current_job.lease_token;
    return next;
  end loop;
end;
$claim$;

revoke all on function public.claim_storage_cleanup_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_storage_cleanup_jobs(integer) to service_role;
