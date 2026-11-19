-- Durable Storage cleanup queue for post/account deletion workflows.
-- Keep accounts in a deletion-pending state if the Auth deletion API fails.
-- This prevents new listings or edits from appearing after the listing transaction.
create table if not exists public.account_deletion_locks (
  -- Keep the lock while Auth deletion is retryable, then remove it automatically
  -- when the Auth user is finally deleted.
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default pg_catalog.now()
);
alter table public.account_deletion_locks enable row level security;
revoke all on table public.account_deletion_locks from public, anon, authenticated;
grant all on table public.account_deletion_locks to service_role;

create or replace function public.block_writes_during_account_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $block$
declare
  lock_key bigint;
begin
  for lock_key in
    select distinct pg_catalog.hashtextextended(v.user_id::text, 0)
      from (values
        (case when tg_op = 'UPDATE' then old.user_id else null end),
        (new.user_id)
      ) as v(user_id)
     where v.user_id is not null
     order by 1
  loop
    perform pg_catalog.pg_advisory_xact_lock(lock_key);
  end loop;

  if exists (
    select 1 from public.account_deletion_locks l
     where l.user_id = new.user_id
        or (tg_op = 'UPDATE' and l.user_id = old.user_id)
  ) then
    raise exception 'Account deletion is in progress; listing writes are blocked';
  end if;

  return new;
end;
$block$;

revoke all on function public.block_writes_during_account_deletion() from public, anon, authenticated;

drop trigger if exists block_service_requests_during_account_deletion on public.service_requests;
create trigger block_service_requests_during_account_deletion
before insert or update on public.service_requests
for each row execute function public.block_writes_during_account_deletion();

drop trigger if exists block_job_posts_during_account_deletion on public.job_posts;
create trigger block_job_posts_during_account_deletion
before insert or update on public.job_posts
for each row execute function public.block_writes_during_account_deletion();

drop trigger if exists block_real_estate_posts_during_account_deletion on public.real_estate_posts;
create trigger block_real_estate_posts_during_account_deletion
before insert or update on public.real_estate_posts
for each row execute function public.block_writes_during_account_deletion();

drop trigger if exists block_market_posts_during_account_deletion on public.market_posts;
create trigger block_market_posts_during_account_deletion
before insert or update on public.market_posts
for each row execute function public.block_writes_during_account_deletion();

-- Candidate migration only: do not apply to production without owner approval.
create table if not exists public.storage_cleanup_jobs (
  id bigint generated always as identity primary key,
  bucket text not null check (bucket in ('listing-images','market-images','pending-images')),
  object_path text not null check (
    length(object_path) between 1 and 220
    and object_path !~ '(^|/)\.\.(/|$)'
    and object_path !~ '(^|/)\.(/|$)'
    and object_path !~ '//'
    and object_path ~* '^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$'
  ),
  status text not null default 'staged' check (status in ('staged','pending','processing','completed','dead_letter')),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  lease_until timestamptz,
  lease_token uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (bucket, object_path)
);

create index if not exists storage_cleanup_jobs_pending_idx
  on public.storage_cleanup_jobs (updated_at, id)
  where status in ('staged','pending','processing');

alter table public.storage_cleanup_jobs enable row level security;
revoke all on table public.storage_cleanup_jobs from anon, authenticated;
grant all on table public.storage_cleanup_jobs to service_role;
grant usage, select on sequence public.storage_cleanup_jobs_id_seq to service_role;

-- Claim jobs atomically so concurrent workers never process the same object at once.
create or replace function public.claim_storage_cleanup_jobs(p_limit integer default 20)
returns table(id bigint, bucket text, object_path text, attempts integer, lease_token uuid)
language sql
security invoker
set search_path = ''
as $$
  with exhausted as (
    update public.storage_cleanup_jobs j
       set status = 'dead_letter',
           lease_until = null,
           lease_token = null,
           updated_at = pg_catalog.now(),
           last_error = coalesce(j.last_error, 'Maximum retry count reached')
     where j.attempts >= 8
       and (j.status = 'pending' or (j.status = 'processing' and j.lease_until < pg_catalog.now()))
    returning j.id
  ),
  candidates as (
    select j.id
      from public.storage_cleanup_jobs j
     where j.attempts < 8
       and (
         j.status = 'pending'
         or (j.status = 'processing' and j.lease_until < pg_catalog.now())
         or (j.status = 'staged' and j.updated_at < pg_catalog.now() - interval '10 minutes')
       )
     order by j.updated_at, j.id
     for update skip locked
     limit least(greatest(coalesce(p_limit, 20), 1), 25)
  ),
  claimed as (
    update public.storage_cleanup_jobs j
       set status = 'processing',
           attempts = j.attempts + 1,
           lease_until = pg_catalog.now() + interval '5 minutes',
           lease_token = pg_catalog.gen_random_uuid(),
           updated_at = pg_catalog.now()
      from candidates c
     where j.id = c.id
    returning j.id, j.bucket, j.object_path, j.attempts, j.lease_token
  )
  select c.id, c.bucket, c.object_path, c.attempts, c.lease_token from claimed c;
$$;

revoke all on function public.claim_storage_cleanup_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_storage_cleanup_jobs(integer) to service_role;


-- Atomically approve only the exact pending snapshot reviewed by the administrator.
-- Image paths are replaced with per-attempt unique public paths in the same update.
create or replace function public.approve_post_if_unchanged(
  p_table text,
  p_id bigint,
  p_expected_row jsonb,
  p_new_image_urls text[],
  p_expires_at timestamptz
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $approval$
declare
  changed boolean := false;
begin
  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_expected_row is null
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or p_expected_row->>'status' <> 'pending'
     or p_expires_at is null
     or p_new_image_urls is null
     or pg_catalog.cardinality(p_new_image_urls) > 20
     or auth.uid() is null
     or not public.is_admin() then
    raise exception 'Approval is not authorized or request is invalid';
  end if;

  -- Compare the complete row, including price, phone, city, category,
  -- property/job fields and contact visibility settings.
  execute pg_catalog.format(
    'update public.%I as listing
        set status = ''approved'', image_urls = $1, expires_at = $2
      where listing.id = $3
        and pg_catalog.to_jsonb(listing) = $4
      returning true',
    p_table
  )
  into changed
  using p_new_image_urls, p_expires_at, p_id, p_expected_row;

  return coalesce(changed, false);
end;
$approval$;

revoke all on function public.approve_post_if_unchanged(text, bigint, jsonb, text[], timestamptz)
  from public, anon;
grant execute on function public.approve_post_if_unchanged(text, bigint, jsonb, text[], timestamptz)
  to authenticated;

-- Atomically change a reviewed listing status only if the complete row is unchanged.
create or replace function public.update_post_status_if_unchanged(
  p_table text,
  p_id bigint,
  p_expected_row jsonb,
  p_new_status text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $status$
declare
  expected_status text;
  changed boolean := false;
begin
  expected_status := case
    when p_new_status = 'rejected' then 'pending'
    when p_new_status = 'unpublished' then 'approved'
    else null
  end;

  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_expected_row is null
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or expected_status is null
     or p_expected_row->>'status' is distinct from expected_status
     or auth.uid() is null
     or not public.is_admin() then
    raise exception 'Status change is not authorized or request is invalid';
  end if;

  execute pg_catalog.format(
    'update public.%I as listing
        set status = $1, image_urls = array[]::text[]
      where listing.id = $2
        and pg_catalog.to_jsonb(listing) = $3
      returning true',
    p_table
  )
  into changed
  using p_new_status, p_id, p_expected_row;

  return coalesce(changed, false);
end;
$status$;

revoke all on function public.update_post_status_if_unchanged(text, bigint, jsonb, text)
  from public, anon;
grant execute on function public.update_post_status_if_unchanged(text, bigint, jsonb, text)
  to authenticated;

-- Activate only the exact paths whose listing-row deletion succeeded.
create or replace function public.activate_storage_cleanup_jobs(p_jobs jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  activated_count integer;
  requested_count integer;
begin
  if pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500 then
    raise exception 'Invalid cleanup job batch';
  end if;

  select count(*) into requested_count
    from (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested;

  update public.storage_cleanup_jobs q
     set status = 'pending',
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = null,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  select count(*) into activated_count
    from public.storage_cleanup_jobs q
    join (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested using (bucket, object_path)
   where q.status in ('pending','processing','completed','dead_letter');

  if activated_count <> requested_count then
    -- Raising is essential: returning 0 would still commit any staged->pending
    -- updates above, leaving a partially activated batch.
    raise exception 'Cleanup activation batch is incomplete: expected %, found %',
      requested_count, activated_count;
  end if;
  return activated_count;
end;
$$;

revoke all on function public.activate_storage_cleanup_jobs(jsonb) from public, anon, authenticated;
grant execute on function public.activate_storage_cleanup_jobs(jsonb) to service_role;

-- Delete one account's listing rows and activate their exact image jobs in one transaction.
create or replace function public.delete_account_posts_and_activate_cleanup(
  p_user_id uuid,
  p_jobs jsonb,
  p_expected_rows jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  requested_count integer;
  mismatch_count integer;
  queue_count integer;
  deleted_count integer := 0;
  affected integer;
  active_count integer;
begin
  if p_user_id is null
     or pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500
     or pg_catalog.jsonb_typeof(p_expected_rows) is distinct from 'object'
     or pg_catalog.jsonb_typeof(p_expected_rows->'service_requests') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'job_posts') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'real_estate_posts') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'market_posts') is distinct from 'array' then
    raise exception 'Invalid account cleanup request';
  end if;

  -- Serialize listing writes for this account and persist a deletion lock.
  -- The lock remains if the separate Auth deletion call fails, so retries are safe
  -- and no new listing can be created in the gap after this transaction commits.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));
  insert into public.account_deletion_locks(user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;

  -- Lock every currently-owned listing row before comparing snapshots so edits
  -- and deletes cannot race the account deletion transaction.
  perform 1 from public.service_requests r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.job_posts r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.real_estate_posts r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.market_posts r where r.user_id = p_user_id order by r.id for update;

  -- Compare every column and every row, not only image paths. This also detects
  -- newly-added rows without images and edits to protected/demo content.
  if (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
        from public.service_requests r where r.user_id = p_user_id)
       <> p_expected_rows->'service_requests'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.job_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'job_posts'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.real_estate_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'real_estate_posts'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.market_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'market_posts' then
    raise exception 'Account listings changed during deletion; retry with a fresh snapshot';
  end if;

  select count(*) into requested_count
    from (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested;

  with requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  ),
  actual as (
    select 'listing-images'::text as bucket, u.path as object_path
      from public.service_requests r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.service_requests r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'listing-images'::text, u.path
      from public.job_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.job_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'listing-images'::text, u.path
      from public.real_estate_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.real_estate_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'market-images'::text, u.path
      from public.market_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.market_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
  )
  select count(*) into mismatch_count
    from (
      (select bucket, object_path from requested
       except
       select bucket, object_path from actual)
      union all
      (select bucket, object_path from actual
       except
       select bucket, object_path from requested)
    ) differences;

  if mismatch_count <> 0 then
    raise exception 'Account listings changed during deletion; retry with a fresh snapshot';
  end if;

  select count(*) into queue_count
    from public.storage_cleanup_jobs q
    join (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested using (bucket, object_path)
   where q.status in ('staged','pending','processing','completed','dead_letter');

  if queue_count <> requested_count then
    raise exception 'Account cleanup queue is incomplete; account deletion aborted';
  end if;

  delete from public.service_requests where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.job_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.real_estate_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.market_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  update public.storage_cleanup_jobs q
     set status = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path) then 'staged'
           else 'pending'
         end,
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path)
             then 'Image is still referenced by a live listing; deferred until the final reference is removed'
           else null
         end,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  with requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  )
  select count(*) into active_count
    from public.storage_cleanup_jobs q
    join requested x using (bucket, object_path)
   where q.status in ('pending','processing','completed','dead_letter');

  return pg_catalog.jsonb_build_object(
    'deleted_rows', deleted_count,
    'cleanup_jobs', active_count,
    'deferred_jobs', requested_count - active_count
  );
end;
$$;

revoke all on function public.delete_account_posts_and_activate_cleanup(uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.delete_account_posts_and_activate_cleanup(uuid, jsonb, jsonb) to service_role;

-- Fail closed if another listing still references the exact queued object.
-- Only rows whose current status uses a given bucket protect its objects.
-- Pending rows use private pending-images; approved rows use their public bucket.
create or replace function public.is_storage_cleanup_object_referenced(
  p_bucket text,
  p_object_path text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  referenced boolean;
begin
  if p_bucket not in ('listing-images','market-images','pending-images')
     or p_object_path is null
     or length(p_object_path) < 1
     or length(p_object_path) > 220 then
    return true;
  end if;

  if p_bucket = 'market-images' then
    select exists (
      select 1 from public.market_posts r
       where r.status = 'approved'
         and p_object_path = any(coalesce(r.image_urls, array[]::text[]))
    ) into referenced;
    return referenced;
  end if;

  if p_bucket = 'listing-images' then
    select
      exists (select 1 from public.service_requests r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      or exists (select 1 from public.job_posts r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      or exists (select 1 from public.real_estate_posts r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      into referenced;
    return referenced;
  end if;

  select
    exists (select 1 from public.service_requests r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.job_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.real_estate_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.market_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    into referenced;
  return referenced;
end;
$$;

revoke all on function public.is_storage_cleanup_object_referenced(text, text) from public, anon, authenticated;
grant execute on function public.is_storage_cleanup_object_referenced(text, text) to service_role;

-- Atomically delete one reviewed listing snapshot and activate only images no longer referenced.
create or replace function public.delete_post_and_activate_storage_cleanup(
  p_table text,
  p_id bigint,
  p_expected_user_id uuid,
  p_require_owner boolean,
  p_expected_row jsonb,
  p_jobs jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  expected_bucket text;
  requested_count integer;
  expected_count integer;
  queued_count integer;
  activated_count integer;
  deleted_count integer;
begin
  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_require_owner is null
     or (p_require_owner and p_expected_user_id is null)
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or pg_catalog.jsonb_typeof(p_expected_row->'image_urls') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500 then
    raise exception 'Invalid post cleanup request';
  end if;

  expected_bucket := case when p_table = 'market_posts' then 'market-images' else 'listing-images' end;

  with expected as (
    select expected_bucket as bucket, p.path as object_path
      from pg_catalog.jsonb_array_elements_text(p_expected_row->'image_urls') as p(path)
    union
    select 'pending-images'::text, p.path
      from pg_catalog.jsonb_array_elements_text(p_expected_row->'image_urls') as p(path)
  ),
  requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  )
  select
    (select count(*) from requested),
    (select count(*) from expected),
    (select count(*) from (
      (select bucket, object_path from requested except select bucket, object_path from expected)
      union all
      (select bucket, object_path from expected except select bucket, object_path from requested)
    ) differences)
  into requested_count, expected_count, queued_count;

  if requested_count <> expected_count or queued_count <> 0 then
    raise exception 'Cleanup job list does not match the reviewed image snapshot';
  end if;

  select count(*) into queued_count
    from public.storage_cleanup_jobs q
    join pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
      on q.bucket = x.bucket and q.object_path = x.object_path
   where q.status in ('staged','pending','processing','completed','dead_letter');

  if queued_count <> requested_count then
    raise exception 'Cleanup queue is incomplete; post deletion aborted';
  end if;

  execute pg_catalog.format(
    'delete from public.%I as listing where id = $1 and pg_catalog.to_jsonb(listing) = $2 and (not $3 or user_id = $4)',
    p_table
  )
  using p_id, p_expected_row, p_require_owner, p_expected_user_id;

  get diagnostics deleted_count = row_count;
  if deleted_count <> 1 then
    return pg_catalog.jsonb_build_object('deleted', false, 'activated_jobs', 0);
  end if;

  update public.storage_cleanup_jobs q
     set status = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path) then 'staged'
           else 'pending'
         end,
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path)
             then 'Image is still referenced by a live listing; deferred until the final reference is removed'
           else null
         end,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  select count(*) into activated_count
    from public.storage_cleanup_jobs q
    join pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
      on q.bucket = x.bucket and q.object_path = x.object_path
   where q.status in ('pending','processing','completed','dead_letter');

  return pg_catalog.jsonb_build_object(
    'deleted', true,
    'activated_jobs', activated_count,
    'deferred_jobs', requested_count - activated_count
  );
end;
$$;

revoke all on function public.delete_post_and_activate_storage_cleanup(text, bigint, uuid, boolean, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.delete_post_and_activate_storage_cleanup(text, bigint, uuid, boolean, jsonb, jsonb) to service_role;

  ),
  status text not null default 'staged' check (status in ('staged','pending','processing','completed','dead_letter')),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  lease_until timestamptz,
  lease_token uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (bucket, object_path)
);

create index if not exists storage_cleanup_jobs_pending_idx
  on public.storage_cleanup_jobs (updated_at, id)
  where status in ('staged','pending','processing');

alter table public.storage_cleanup_jobs enable row level security;
revoke all on table public.storage_cleanup_jobs from anon, authenticated;
grant all on table public.storage_cleanup_jobs to service_role;
grant usage, select on sequence public.storage_cleanup_jobs_id_seq to service_role;

-- Claim jobs atomically so concurrent workers never process the same object at once.
create or replace function public.claim_storage_cleanup_jobs(p_limit integer default 20)
returns table(id bigint, bucket text, object_path text, attempts integer, lease_token uuid)
language sql
security invoker
set search_path = ''
as $$
  with exhausted as (
    update public.storage_cleanup_jobs j
       set status = 'dead_letter',
           lease_until = null,
           lease_token = null,
           updated_at = pg_catalog.now(),
           last_error = coalesce(j.last_error, 'Maximum retry count reached')
     where j.attempts >= 8
       and (j.status = 'pending' or (j.status = 'processing' and j.lease_until < pg_catalog.now()))
    returning j.id
  ),
  candidates as (
    select j.id
      from public.storage_cleanup_jobs j
     where j.attempts < 8
       and (
         j.status = 'pending'
         or (j.status = 'processing' and j.lease_until < pg_catalog.now())
         or (j.status = 'staged' and j.updated_at < pg_catalog.now() - interval '10 minutes')
       )
     order by j.updated_at, j.id
     for update skip locked
     limit least(greatest(coalesce(p_limit, 20), 1), 25)
  ),
  claimed as (
    update public.storage_cleanup_jobs j
       set status = 'processing',
           attempts = j.attempts + 1,
           lease_until = pg_catalog.now() + interval '5 minutes',
           lease_token = pg_catalog.gen_random_uuid(),
           updated_at = pg_catalog.now()
      from candidates c
     where j.id = c.id
    returning j.id, j.bucket, j.object_path, j.attempts, j.lease_token
  )
  select c.id, c.bucket, c.object_path, c.attempts, c.lease_token from claimed c;
$$;

revoke all on function public.claim_storage_cleanup_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_storage_cleanup_jobs(integer) to service_role;


-- Atomically approve only the exact pending snapshot reviewed by the administrator.
-- Image paths are replaced with per-attempt unique public paths in the same update.
create or replace function public.approve_post_if_unchanged(
  p_table text,
  p_id bigint,
  p_expected_row jsonb,
  p_new_image_urls text[],
  p_expires_at timestamptz
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $approval$
declare
  changed boolean := false;
begin
  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_expected_row is null
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or p_expected_row->>'status' <> 'pending'
     or p_expires_at is null
     or p_new_image_urls is null
     or pg_catalog.cardinality(p_new_image_urls) > 20
     or auth.uid() is null
     or not public.is_admin() then
    raise exception 'Approval is not authorized or request is invalid';
  end if;

  -- Compare the complete row, including price, phone, city, category,
  -- property/job fields and contact visibility settings.
  execute pg_catalog.format(
    'update public.%I as listing
        set status = ''approved'', image_urls = $1, expires_at = $2
      where listing.id = $3
        and pg_catalog.to_jsonb(listing) = $4
      returning true',
    p_table
  )
  into changed
  using p_new_image_urls, p_expires_at, p_id, p_expected_row;

  return coalesce(changed, false);
end;
$approval$;

revoke all on function public.approve_post_if_unchanged(text, bigint, jsonb, text[], timestamptz)
  from public, anon;
grant execute on function public.approve_post_if_unchanged(text, bigint, jsonb, text[], timestamptz)
  to authenticated;

-- Atomically change a reviewed listing status only if the complete row is unchanged.
create or replace function public.update_post_status_if_unchanged(
  p_table text,
  p_id bigint,
  p_expected_row jsonb,
  p_new_status text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $status$
declare
  expected_status text;
  changed boolean := false;
begin
  expected_status := case
    when p_new_status = 'rejected' then 'pending'
    when p_new_status = 'unpublished' then 'approved'
    else null
  end;

  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_expected_row is null
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or expected_status is null
     or p_expected_row->>'status' is distinct from expected_status
     or auth.uid() is null
     or not public.is_admin() then
    raise exception 'Status change is not authorized or request is invalid';
  end if;

  execute pg_catalog.format(
    'update public.%I as listing
        set status = $1, image_urls = array[]::text[]
      where listing.id = $2
        and pg_catalog.to_jsonb(listing) = $3
      returning true',
    p_table
  )
  into changed
  using p_new_status, p_id, p_expected_row;

  return coalesce(changed, false);
end;
$status$;

revoke all on function public.update_post_status_if_unchanged(text, bigint, jsonb, text)
  from public, anon;
grant execute on function public.update_post_status_if_unchanged(text, bigint, jsonb, text)
  to authenticated;

-- Activate only the exact paths whose listing-row deletion succeeded.
create or replace function public.activate_storage_cleanup_jobs(p_jobs jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  activated_count integer;
  requested_count integer;
begin
  if pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500 then
    raise exception 'Invalid cleanup job batch';
  end if;

  select count(*) into requested_count
    from (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested;

  update public.storage_cleanup_jobs q
     set status = 'pending',
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = null,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  select count(*) into activated_count
    from public.storage_cleanup_jobs q
    join (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested using (bucket, object_path)
   where q.status in ('pending','processing','completed','dead_letter');

  if activated_count <> requested_count then
    -- Raising is essential: returning 0 would still commit any staged->pending
    -- updates above, leaving a partially activated batch.
    raise exception 'Cleanup activation batch is incomplete: expected %, found %',
      requested_count, activated_count;
  end if;
  return activated_count;
end;
$$;

revoke all on function public.activate_storage_cleanup_jobs(jsonb) from public, anon, authenticated;
grant execute on function public.activate_storage_cleanup_jobs(jsonb) to service_role;

-- Delete one account's listing rows and activate their exact image jobs in one transaction.
create or replace function public.delete_account_posts_and_activate_cleanup(
  p_user_id uuid,
  p_jobs jsonb,
  p_expected_rows jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  requested_count integer;
  mismatch_count integer;
  queue_count integer;
  deleted_count integer := 0;
  affected integer;
  active_count integer;
begin
  if p_user_id is null
     or pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500
     or pg_catalog.jsonb_typeof(p_expected_rows) is distinct from 'object'
     or pg_catalog.jsonb_typeof(p_expected_rows->'service_requests') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'job_posts') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'real_estate_posts') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'market_posts') is distinct from 'array' then
    raise exception 'Invalid account cleanup request';
  end if;

  -- Serialize listing writes for this account and persist a deletion lock.
  -- The lock remains if the separate Auth deletion call fails, so retries are safe
  -- and no new listing can be created in the gap after this transaction commits.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));
  insert into public.account_deletion_locks(user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;

  -- Lock every currently-owned listing row before comparing snapshots so edits
  -- and deletes cannot race the account deletion transaction.
  perform 1 from public.service_requests r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.job_posts r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.real_estate_posts r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.market_posts r where r.user_id = p_user_id order by r.id for update;

  -- Compare every column and every row, not only image paths. This also detects
  -- newly-added rows without images and edits to protected/demo content.
  if (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
        from public.service_requests r where r.user_id = p_user_id)
       <> p_expected_rows->'service_requests'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.job_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'job_posts'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.real_estate_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'real_estate_posts'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.market_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'market_posts' then
    raise exception 'Account listings changed during deletion; retry with a fresh snapshot';
  end if;

  select count(*) into requested_count
    from (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested;

  with requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  ),
  actual as (
    select 'listing-images'::text as bucket, u.path as object_path
      from public.service_requests r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.service_requests r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'listing-images'::text, u.path
      from public.job_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.job_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'listing-images'::text, u.path
      from public.real_estate_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.real_estate_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'market-images'::text, u.path
      from public.market_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.market_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
  )
  select count(*) into mismatch_count
    from (
      (select bucket, object_path from requested
       except
       select bucket, object_path from actual)
      union all
      (select bucket, object_path from actual
       except
       select bucket, object_path from requested)
    ) differences;

  if mismatch_count <> 0 then
    raise exception 'Account listings changed during deletion; retry with a fresh snapshot';
  end if;

  select count(*) into queue_count
    from public.storage_cleanup_jobs q
    join (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested using (bucket, object_path)
   where q.status in ('staged','pending','processing','completed','dead_letter');

  if queue_count <> requested_count then
    raise exception 'Account cleanup queue is incomplete; account deletion aborted';
  end if;

  delete from public.service_requests where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.job_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.real_estate_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.market_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  update public.storage_cleanup_jobs q
     set status = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path) then 'staged'
           else 'pending'
         end,
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path)
             then 'Image is still referenced by a live listing; deferred until the final reference is removed'
           else null
         end,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  with requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  )
  select count(*) into active_count
    from public.storage_cleanup_jobs q
    join requested x using (bucket, object_path)
   where q.status in ('pending','processing','completed','dead_letter');

  return pg_catalog.jsonb_build_object(
    'deleted_rows', deleted_count,
    'cleanup_jobs', active_count,
    'deferred_jobs', requested_count - active_count
  );
end;
$$;

revoke all on function public.delete_account_posts_and_activate_cleanup(uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.delete_account_posts_and_activate_cleanup(uuid, jsonb, jsonb) to service_role;

-- Fail closed if another listing still references the exact queued object.
-- Only rows whose current status uses a given bucket protect its objects.
-- Pending rows use private pending-images; approved rows use their public bucket.
create or replace function public.is_storage_cleanup_object_referenced(
  p_bucket text,
  p_object_path text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  referenced boolean;
begin
  if p_bucket not in ('listing-images','market-images','pending-images')
     or p_object_path is null
     or length(p_object_path) < 1
     or length(p_object_path) > 220 then
    return true;
  end if;

  if p_bucket = 'market-images' then
    select exists (
      select 1 from public.market_posts r
       where r.status = 'approved'
         and p_object_path = any(coalesce(r.image_urls, array[]::text[]))
    ) into referenced;
    return referenced;
  end if;

  if p_bucket = 'listing-images' then
    select
      exists (select 1 from public.service_requests r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      or exists (select 1 from public.job_posts r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      or exists (select 1 from public.real_estate_posts r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      into referenced;
    return referenced;
  end if;

  select
    exists (select 1 from public.service_requests r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.job_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.real_estate_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.market_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    into referenced;
  return referenced;
end;
$$;

revoke all on function public.is_storage_cleanup_object_referenced(text, text) from public, anon, authenticated;
grant execute on function public.is_storage_cleanup_object_referenced(text, text) to service_role;

-- Atomically delete one reviewed listing snapshot and activate only images no longer referenced.
create or replace function public.delete_post_and_activate_storage_cleanup(
  p_table text,
  p_id bigint,
  p_expected_user_id uuid,
  p_require_owner boolean,
  p_expected_row jsonb,
  p_jobs jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  expected_bucket text;
  requested_count integer;
  expected_count integer;
  queued_count integer;
  activated_count integer;
  deleted_count integer;
begin
  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_require_owner is null
     or (p_require_owner and p_expected_user_id is null)
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or pg_catalog.jsonb_typeof(p_expected_row->'image_urls') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500 then
    raise exception 'Invalid post cleanup request';
  end if;

  expected_bucket := case when p_table = 'market_posts' then 'market-images' else 'listing-images' end;

  with expected as (
    select expected_bucket as bucket, p.path as object_path
      from pg_catalog.jsonb_array_elements_text(p_expected_row->'image_urls') as p(path)
    union
    select 'pending-images'::text, p.path
      from pg_catalog.jsonb_array_elements_text(p_expected_row->'image_urls') as p(path)
  ),
  requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  )
  select
    (select count(*) from requested),
    (select count(*) from expected),
    (select count(*) from (
      (select bucket, object_path from requested except select bucket, object_path from expected)
      union all
      (select bucket, object_path from expected except select bucket, object_path from requested)
    ) differences)
  into requested_count, expected_count, queued_count;

  if requested_count <> expected_count or queued_count <> 0 then
    raise exception 'Cleanup job list does not match the reviewed image snapshot';
  end if;

  select count(*) into queued_count
    from public.storage_cleanup_jobs q
    join pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
      on q.bucket = x.bucket and q.object_path = x.object_path
   where q.status in ('staged','pending','processing','completed','dead_letter');

  if queued_count <> requested_count then
    raise exception 'Cleanup queue is incomplete; post deletion aborted';
  end if;

  execute pg_catalog.format(
    'delete from public.%I as listing where id = $1 and pg_catalog.to_jsonb(listing) = $2 and (not $3 or user_id = $4)',
    p_table
  )
  using p_id, p_expected_row, p_require_owner, p_expected_user_id;

  get diagnostics deleted_count = row_count;
  if deleted_count <> 1 then
    return pg_catalog.jsonb_build_object('deleted', false, 'activated_jobs', 0);
  end if;

  update public.storage_cleanup_jobs q
     set status = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path) then 'staged'
           else 'pending'
         end,
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path)
             then 'Image is still referenced by a live listing; deferred until the final reference is removed'
           else null
         end,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  select count(*) into activated_count
    from public.storage_cleanup_jobs q
    join pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
      on q.bucket = x.bucket and q.object_path = x.object_path
   where q.status in ('pending','processing','completed','dead_letter');

  return pg_catalog.jsonb_build_object(
    'deleted', true,
    'activated_jobs', activated_count,
    'deferred_jobs', requested_count - activated_count
  );
end;
$$;

revoke all on function public.delete_post_and_activate_storage_cleanup(text, bigint, uuid, boolean, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.delete_post_and_activate_storage_cleanup(text, bigint, uuid, boolean, jsonb, jsonb) to service_role;

  ),
  status text not null default 'staged' check (status in ('staged','pending','processing','completed','dead_letter')),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  lease_until timestamptz,
  lease_token uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (bucket, object_path)
);

create index if not exists storage_cleanup_jobs_pending_idx
  on public.storage_cleanup_jobs (updated_at, id)
  where status in ('staged','pending','processing');

alter table public.storage_cleanup_jobs enable row level security;
revoke all on table public.storage_cleanup_jobs from anon, authenticated;
grant all on table public.storage_cleanup_jobs to service_role;
grant usage, select on sequence public.storage_cleanup_jobs_id_seq to service_role;

-- Claim jobs atomically so concurrent workers never process the same object at once.
create or replace function public.claim_storage_cleanup_jobs(p_limit integer default 20)
returns table(id bigint, bucket text, object_path text, attempts integer, lease_token uuid)
language sql
security invoker
set search_path = ''
as $$
  with exhausted as (
    update public.storage_cleanup_jobs j
       set status = 'dead_letter',
           lease_until = null,
           lease_token = null,
           updated_at = pg_catalog.now(),
           last_error = coalesce(j.last_error, 'Maximum retry count reached')
     where j.attempts >= 8
       and (j.status = 'pending' or (j.status = 'processing' and j.lease_until < pg_catalog.now()))
    returning j.id
  ),
  candidates as (
    select j.id
      from public.storage_cleanup_jobs j
     where j.attempts < 8
       and (
         j.status = 'pending'
         or (j.status = 'processing' and j.lease_until < pg_catalog.now())
         or (j.status = 'staged' and j.updated_at < pg_catalog.now() - interval '10 minutes')
       )
     order by j.updated_at, j.id
     for update skip locked
     limit least(greatest(coalesce(p_limit, 20), 1), 25)
  ),
  claimed as (
    update public.storage_cleanup_jobs j
       set status = 'processing',
           attempts = j.attempts + 1,
           lease_until = pg_catalog.now() + interval '5 minutes',
           lease_token = pg_catalog.gen_random_uuid(),
           updated_at = pg_catalog.now()
      from candidates c
     where j.id = c.id
    returning j.id, j.bucket, j.object_path, j.attempts, j.lease_token
  )
  select c.id, c.bucket, c.object_path, c.attempts, c.lease_token from claimed c;
$$;

revoke all on function public.claim_storage_cleanup_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_storage_cleanup_jobs(integer) to service_role;


-- Atomically approve only the exact pending snapshot reviewed by the administrator.
-- Image paths are replaced with per-attempt unique public paths in the same update.
create or replace function public.approve_post_if_unchanged(
  p_table text,
  p_id bigint,
  p_expected_row jsonb,
  p_new_image_urls text[],
  p_expires_at timestamptz
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $approval$
declare
  changed boolean := false;
begin
  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_expected_row is null
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or p_expected_row->>'status' <> 'pending'
     or p_expires_at is null
     or p_new_image_urls is null
     or pg_catalog.cardinality(p_new_image_urls) > 20
     or auth.uid() is null
     or not public.is_admin() then
    raise exception 'Approval is not authorized or request is invalid';
  end if;

  -- Compare the complete row, including price, phone, city, category,
  -- property/job fields and contact visibility settings.
  execute pg_catalog.format(
    'update public.%I as listing
        set status = ''approved'', image_urls = $1, expires_at = $2
      where listing.id = $3
        and pg_catalog.to_jsonb(listing) = $4
      returning true',
    p_table
  )
  into changed
  using p_new_image_urls, p_expires_at, p_id, p_expected_row;

  return coalesce(changed, false);
end;
$approval$;

revoke all on function public.approve_post_if_unchanged(text, bigint, jsonb, text[], timestamptz)
  from public, anon;
grant execute on function public.approve_post_if_unchanged(text, bigint, jsonb, text[], timestamptz)
  to authenticated;

-- Atomically change a reviewed listing status only if the complete row is unchanged.
create or replace function public.update_post_status_if_unchanged(
  p_table text,
  p_id bigint,
  p_expected_row jsonb,
  p_new_status text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $status$
declare
  expected_status text;
  changed boolean := false;
begin
  expected_status := case
    when p_new_status = 'rejected' then 'pending'
    when p_new_status = 'unpublished' then 'approved'
    else null
  end;

  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_expected_row is null
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or expected_status is null
     or p_expected_row->>'status' is distinct from expected_status
     or auth.uid() is null
     or not public.is_admin() then
    raise exception 'Status change is not authorized or request is invalid';
  end if;

  execute pg_catalog.format(
    'update public.%I as listing
        set status = $1, image_urls = array[]::text[]
      where listing.id = $2
        and pg_catalog.to_jsonb(listing) = $3
      returning true',
    p_table
  )
  into changed
  using p_new_status, p_id, p_expected_row;

  return coalesce(changed, false);
end;
$status$;

revoke all on function public.update_post_status_if_unchanged(text, bigint, jsonb, text)
  from public, anon;
grant execute on function public.update_post_status_if_unchanged(text, bigint, jsonb, text)
  to authenticated;

-- Activate only the exact paths whose listing-row deletion succeeded.
create or replace function public.activate_storage_cleanup_jobs(p_jobs jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  activated_count integer;
  requested_count integer;
begin
  if pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500 then
    raise exception 'Invalid cleanup job batch';
  end if;

  select count(*) into requested_count
    from (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested;

  update public.storage_cleanup_jobs q
     set status = 'pending',
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = null,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  select count(*) into activated_count
    from public.storage_cleanup_jobs q
    join (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested using (bucket, object_path)
   where q.status in ('pending','processing','completed','dead_letter');

  if activated_count <> requested_count then
    -- Raising is essential: returning 0 would still commit any staged->pending
    -- updates above, leaving a partially activated batch.
    raise exception 'Cleanup activation batch is incomplete: expected %, found %',
      requested_count, activated_count;
  end if;
  return activated_count;
end;
$$;

revoke all on function public.activate_storage_cleanup_jobs(jsonb) from public, anon, authenticated;
grant execute on function public.activate_storage_cleanup_jobs(jsonb) to service_role;

-- Delete one account's listing rows and activate their exact image jobs in one transaction.
create or replace function public.delete_account_posts_and_activate_cleanup(
  p_user_id uuid,
  p_jobs jsonb,
  p_expected_rows jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  requested_count integer;
  mismatch_count integer;
  queue_count integer;
  deleted_count integer := 0;
  affected integer;
  active_count integer;
begin
  if p_user_id is null
     or pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500
     or pg_catalog.jsonb_typeof(p_expected_rows) is distinct from 'object'
     or pg_catalog.jsonb_typeof(p_expected_rows->'service_requests') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'job_posts') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'real_estate_posts') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'market_posts') is distinct from 'array' then
    raise exception 'Invalid account cleanup request';
  end if;

  -- Serialize listing writes for this account and persist a deletion lock.
  -- The lock remains if the separate Auth deletion call fails, so retries are safe
  -- and no new listing can be created in the gap after this transaction commits.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));
  insert into public.account_deletion_locks(user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;

  -- Lock every currently-owned listing row before comparing snapshots so edits
  -- and deletes cannot race the account deletion transaction.
  perform 1 from public.service_requests r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.job_posts r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.real_estate_posts r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.market_posts r where r.user_id = p_user_id order by r.id for update;

  -- Compare every column and every row, not only image paths. This also detects
  -- newly-added rows without images and edits to protected/demo content.
  if (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
        from public.service_requests r where r.user_id = p_user_id)
       <> p_expected_rows->'service_requests'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.job_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'job_posts'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.real_estate_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'real_estate_posts'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.market_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'market_posts' then
    raise exception 'Account listings changed during deletion; retry with a fresh snapshot';
  end if;

  select count(*) into requested_count
    from (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested;

  with requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  ),
  actual as (
    select 'listing-images'::text as bucket, u.path as object_path
      from public.service_requests r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.service_requests r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'listing-images'::text, u.path
      from public.job_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.job_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'listing-images'::text, u.path
      from public.real_estate_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.real_estate_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'market-images'::text, u.path
      from public.market_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.market_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
  )
  select count(*) into mismatch_count
    from (
      (select bucket, object_path from requested
       except
       select bucket, object_path from actual)
      union all
      (select bucket, object_path from actual
       except
       select bucket, object_path from requested)
    ) differences;

  if mismatch_count <> 0 then
    raise exception 'Account listings changed during deletion; retry with a fresh snapshot';
  end if;

  select count(*) into queue_count
    from public.storage_cleanup_jobs q
    join (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested using (bucket, object_path)
   where q.status in ('staged','pending','processing','completed','dead_letter');

  if queue_count <> requested_count then
    raise exception 'Account cleanup queue is incomplete; account deletion aborted';
  end if;

  delete from public.service_requests where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.job_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.real_estate_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.market_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  update public.storage_cleanup_jobs q
     set status = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path) then 'staged'
           else 'pending'
         end,
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path)
             then 'Image is still referenced by a live listing; deferred until the final reference is removed'
           else null
         end,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  with requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  )
  select count(*) into active_count
    from public.storage_cleanup_jobs q
    join requested x using (bucket, object_path)
   where q.status in ('pending','processing','completed','dead_letter');

  return pg_catalog.jsonb_build_object(
    'deleted_rows', deleted_count,
    'cleanup_jobs', active_count,
    'deferred_jobs', requested_count - active_count
  );
end;
$$;

revoke all on function public.delete_account_posts_and_activate_cleanup(uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.delete_account_posts_and_activate_cleanup(uuid, jsonb, jsonb) to service_role;

-- Fail closed if another listing still references the exact queued object.
-- Only rows whose current status uses a given bucket protect its objects.
-- Pending rows use private pending-images; approved rows use their public bucket.
create or replace function public.is_storage_cleanup_object_referenced(
  p_bucket text,
  p_object_path text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  referenced boolean;
begin
  if p_bucket not in ('listing-images','market-images','pending-images')
     or p_object_path is null
     or length(p_object_path) < 1
     or length(p_object_path) > 220 then
    return true;
  end if;

  if p_bucket = 'market-images' then
    select exists (
      select 1 from public.market_posts r
       where r.status = 'approved'
         and p_object_path = any(coalesce(r.image_urls, array[]::text[]))
    ) into referenced;
    return referenced;
  end if;

  if p_bucket = 'listing-images' then
    select
      exists (select 1 from public.service_requests r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      or exists (select 1 from public.job_posts r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      or exists (select 1 from public.real_estate_posts r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      into referenced;
    return referenced;
  end if;

  select
    exists (select 1 from public.service_requests r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.job_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.real_estate_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.market_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    into referenced;
  return referenced;
end;
$$;

revoke all on function public.is_storage_cleanup_object_referenced(text, text) from public, anon, authenticated;
grant execute on function public.is_storage_cleanup_object_referenced(text, text) to service_role;

-- Atomically delete one reviewed listing snapshot and activate only images no longer referenced.
create or replace function public.delete_post_and_activate_storage_cleanup(
  p_table text,
  p_id bigint,
  p_expected_user_id uuid,
  p_require_owner boolean,
  p_expected_row jsonb,
  p_jobs jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  expected_bucket text;
  requested_count integer;
  expected_count integer;
  queued_count integer;
  activated_count integer;
  deleted_count integer;
begin
  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_require_owner is null
     or (p_require_owner and p_expected_user_id is null)
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or pg_catalog.jsonb_typeof(p_expected_row->'image_urls') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500 then
    raise exception 'Invalid post cleanup request';
  end if;

  expected_bucket := case when p_table = 'market_posts' then 'market-images' else 'listing-images' end;

  with expected as (
    select expected_bucket as bucket, p.path as object_path
      from pg_catalog.jsonb_array_elements_text(p_expected_row->'image_urls') as p(path)
    union
    select 'pending-images'::text, p.path
      from pg_catalog.jsonb_array_elements_text(p_expected_row->'image_urls') as p(path)
  ),
  requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  )
  select
    (select count(*) from requested),
    (select count(*) from expected),
    (select count(*) from (
      (select bucket, object_path from requested except select bucket, object_path from expected)
      union all
      (select bucket, object_path from expected except select bucket, object_path from requested)
    ) differences)
  into requested_count, expected_count, queued_count;

  if requested_count <> expected_count or queued_count <> 0 then
    raise exception 'Cleanup job list does not match the reviewed image snapshot';
  end if;

  select count(*) into queued_count
    from public.storage_cleanup_jobs q
    join pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
      on q.bucket = x.bucket and q.object_path = x.object_path
   where q.status in ('staged','pending','processing','completed','dead_letter');

  if queued_count <> requested_count then
    raise exception 'Cleanup queue is incomplete; post deletion aborted';
  end if;

  execute pg_catalog.format(
    'delete from public.%I as listing where id = $1 and pg_catalog.to_jsonb(listing) = $2 and (not $3 or user_id = $4)',
    p_table
  )
  using p_id, p_expected_row, p_require_owner, p_expected_user_id;

  get diagnostics deleted_count = row_count;
  if deleted_count <> 1 then
    return pg_catalog.jsonb_build_object('deleted', false, 'activated_jobs', 0);
  end if;

  update public.storage_cleanup_jobs q
     set status = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path) then 'staged'
           else 'pending'
         end,
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path)
             then 'Image is still referenced by a live listing; deferred until the final reference is removed'
           else null
         end,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  select count(*) into activated_count
    from public.storage_cleanup_jobs q
    join pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
      on q.bucket = x.bucket and q.object_path = x.object_path
   where q.status in ('pending','processing','completed','dead_letter');

  return pg_catalog.jsonb_build_object(
    'deleted', true,
    'activated_jobs', activated_count,
    'deferred_jobs', requested_count - activated_count
  );
end;
$$;

revoke all on function public.delete_post_and_activate_storage_cleanup(text, bigint, uuid, boolean, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.delete_post_and_activate_storage_cleanup(text, bigint, uuid, boolean, jsonb, jsonb) to service_role;

  ),
  status text not null default 'staged' check (status in ('staged','pending','processing','completed','dead_letter')),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  lease_until timestamptz,
  lease_token uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (bucket, object_path)
);

create index if not exists storage_cleanup_jobs_pending_idx
  on public.storage_cleanup_jobs (updated_at, id)
  where status in ('staged','pending','processing');

alter table public.storage_cleanup_jobs enable row level security;
revoke all on table public.storage_cleanup_jobs from anon, authenticated;
grant all on table public.storage_cleanup_jobs to service_role;
grant usage, select on sequence public.storage_cleanup_jobs_id_seq to service_role;

-- Claim jobs atomically so concurrent workers never process the same object at once.
create or replace function public.claim_storage_cleanup_jobs(p_limit integer default 20)
returns table(id bigint, bucket text, object_path text, attempts integer, lease_token uuid)
language sql
security invoker
set search_path = ''
as $$
  with exhausted as (
    update public.storage_cleanup_jobs j
       set status = 'dead_letter',
           lease_until = null,
           lease_token = null,
           updated_at = pg_catalog.now(),
           last_error = coalesce(j.last_error, 'Maximum retry count reached')
     where j.attempts >= 8
       and (j.status = 'pending' or (j.status = 'processing' and j.lease_until < pg_catalog.now()))
    returning j.id
  ),
  candidates as (
    select j.id
      from public.storage_cleanup_jobs j
     where j.attempts < 8
       and (
         j.status = 'pending'
         or (j.status = 'processing' and j.lease_until < pg_catalog.now())
         or (j.status = 'staged' and j.updated_at < pg_catalog.now() - interval '10 minutes')
       )
     order by j.updated_at, j.id
     for update skip locked
     limit least(greatest(coalesce(p_limit, 20), 1), 25)
  ),
  claimed as (
    update public.storage_cleanup_jobs j
       set status = 'processing',
           attempts = j.attempts + 1,
           lease_until = pg_catalog.now() + interval '5 minutes',
           lease_token = pg_catalog.gen_random_uuid(),
           updated_at = pg_catalog.now()
      from candidates c
     where j.id = c.id
    returning j.id, j.bucket, j.object_path, j.attempts, j.lease_token
  )
  select c.id, c.bucket, c.object_path, c.attempts, c.lease_token from claimed c;
$$;

revoke all on function public.claim_storage_cleanup_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_storage_cleanup_jobs(integer) to service_role;


-- Atomically approve only the exact pending snapshot reviewed by the administrator.
-- Image paths are replaced with per-attempt unique public paths in the same update.
create or replace function public.approve_post_if_unchanged(
  p_table text,
  p_id bigint,
  p_expected_row jsonb,
  p_new_image_urls text[],
  p_expires_at timestamptz
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $approval$
declare
  changed boolean := false;
begin
  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_expected_row is null
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or p_expected_row->>'status' <> 'pending'
     or p_expires_at is null
     or p_new_image_urls is null
     or pg_catalog.cardinality(p_new_image_urls) > 20
     or auth.uid() is null
     or not public.is_admin() then
    raise exception 'Approval is not authorized or request is invalid';
  end if;

  -- Compare the complete row, including price, phone, city, category,
  -- property/job fields and contact visibility settings.
  execute pg_catalog.format(
    'update public.%I as listing
        set status = ''approved'', image_urls = $1, expires_at = $2
      where listing.id = $3
        and pg_catalog.to_jsonb(listing) = $4
      returning true',
    p_table
  )
  into changed
  using p_new_image_urls, p_expires_at, p_id, p_expected_row;

  return coalesce(changed, false);
end;
$approval$;

revoke all on function public.approve_post_if_unchanged(text, bigint, jsonb, text[], timestamptz)
  from public, anon;
grant execute on function public.approve_post_if_unchanged(text, bigint, jsonb, text[], timestamptz)
  to authenticated;

-- Atomically change a reviewed listing status only if the complete row is unchanged.
create or replace function public.update_post_status_if_unchanged(
  p_table text,
  p_id bigint,
  p_expected_row jsonb,
  p_new_status text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $status$
declare
  expected_status text;
  changed boolean := false;
begin
  expected_status := case
    when p_new_status = 'rejected' then 'pending'
    when p_new_status = 'unpublished' then 'approved'
    else null
  end;

  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_expected_row is null
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or expected_status is null
     or p_expected_row->>'status' is distinct from expected_status
     or auth.uid() is null
     or not public.is_admin() then
    raise exception 'Status change is not authorized or request is invalid';
  end if;

  execute pg_catalog.format(
    'update public.%I as listing
        set status = $1, image_urls = array[]::text[]
      where listing.id = $2
        and pg_catalog.to_jsonb(listing) = $3
      returning true',
    p_table
  )
  into changed
  using p_new_status, p_id, p_expected_row;

  return coalesce(changed, false);
end;
$status$;

revoke all on function public.update_post_status_if_unchanged(text, bigint, jsonb, text)
  from public, anon;
grant execute on function public.update_post_status_if_unchanged(text, bigint, jsonb, text)
  to authenticated;

-- Activate only the exact paths whose listing-row deletion succeeded.
create or replace function public.activate_storage_cleanup_jobs(p_jobs jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  activated_count integer;
  requested_count integer;
begin
  if pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500 then
    raise exception 'Invalid cleanup job batch';
  end if;

  select count(*) into requested_count
    from (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested;

  update public.storage_cleanup_jobs q
     set status = 'pending',
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = null,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  select count(*) into activated_count
    from public.storage_cleanup_jobs q
    join (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested using (bucket, object_path)
   where q.status in ('pending','processing','completed','dead_letter');

  if activated_count <> requested_count then
    -- Raising is essential: returning 0 would still commit any staged->pending
    -- updates above, leaving a partially activated batch.
    raise exception 'Cleanup activation batch is incomplete: expected %, found %',
      requested_count, activated_count;
  end if;
  return activated_count;
end;
$$;

revoke all on function public.activate_storage_cleanup_jobs(jsonb) from public, anon, authenticated;
grant execute on function public.activate_storage_cleanup_jobs(jsonb) to service_role;

-- Delete one account's listing rows and activate their exact image jobs in one transaction.
create or replace function public.delete_account_posts_and_activate_cleanup(
  p_user_id uuid,
  p_jobs jsonb,
  p_expected_rows jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  requested_count integer;
  mismatch_count integer;
  queue_count integer;
  deleted_count integer := 0;
  affected integer;
  active_count integer;
begin
  if p_user_id is null
     or pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500
     or pg_catalog.jsonb_typeof(p_expected_rows) is distinct from 'object'
     or pg_catalog.jsonb_typeof(p_expected_rows->'service_requests') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'job_posts') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'real_estate_posts') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_expected_rows->'market_posts') is distinct from 'array' then
    raise exception 'Invalid account cleanup request';
  end if;

  -- Serialize listing writes for this account and persist a deletion lock.
  -- The lock remains if the separate Auth deletion call fails, so retries are safe
  -- and no new listing can be created in the gap after this transaction commits.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));
  insert into public.account_deletion_locks(user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;

  -- Lock every currently-owned listing row before comparing snapshots so edits
  -- and deletes cannot race the account deletion transaction.
  perform 1 from public.service_requests r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.job_posts r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.real_estate_posts r where r.user_id = p_user_id order by r.id for update;
  perform 1 from public.market_posts r where r.user_id = p_user_id order by r.id for update;

  -- Compare every column and every row, not only image paths. This also detects
  -- newly-added rows without images and edits to protected/demo content.
  if (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
        from public.service_requests r where r.user_id = p_user_id)
       <> p_expected_rows->'service_requests'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.job_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'job_posts'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.real_estate_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'real_estate_posts'
     or (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id), '[]'::jsonb)
           from public.market_posts r where r.user_id = p_user_id)
       <> p_expected_rows->'market_posts' then
    raise exception 'Account listings changed during deletion; retry with a fresh snapshot';
  end if;

  select count(*) into requested_count
    from (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested;

  with requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  ),
  actual as (
    select 'listing-images'::text as bucket, u.path as object_path
      from public.service_requests r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.service_requests r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'listing-images'::text, u.path
      from public.job_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.job_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'listing-images'::text, u.path
      from public.real_estate_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.real_estate_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'market-images'::text, u.path
      from public.market_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
    union
    select 'pending-images'::text, u.path
      from public.market_posts r cross join lateral pg_catalog.unnest(r.image_urls) as u(path)
     where r.user_id = p_user_id
  )
  select count(*) into mismatch_count
    from (
      (select bucket, object_path from requested
       except
       select bucket, object_path from actual)
      union all
      (select bucket, object_path from actual
       except
       select bucket, object_path from requested)
    ) differences;

  if mismatch_count <> 0 then
    raise exception 'Account listings changed during deletion; retry with a fresh snapshot';
  end if;

  select count(*) into queue_count
    from public.storage_cleanup_jobs q
    join (
      select distinct x.bucket, x.object_path
        from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
    ) requested using (bucket, object_path)
   where q.status in ('staged','pending','processing','completed','dead_letter');

  if queue_count <> requested_count then
    raise exception 'Account cleanup queue is incomplete; account deletion aborted';
  end if;

  delete from public.service_requests where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.job_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.real_estate_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  delete from public.market_posts where user_id = p_user_id;
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;

  update public.storage_cleanup_jobs q
     set status = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path) then 'staged'
           else 'pending'
         end,
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path)
             then 'Image is still referenced by a live listing; deferred until the final reference is removed'
           else null
         end,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  with requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  )
  select count(*) into active_count
    from public.storage_cleanup_jobs q
    join requested x using (bucket, object_path)
   where q.status in ('pending','processing','completed','dead_letter');

  return pg_catalog.jsonb_build_object(
    'deleted_rows', deleted_count,
    'cleanup_jobs', active_count,
    'deferred_jobs', requested_count - active_count
  );
end;
$$;

revoke all on function public.delete_account_posts_and_activate_cleanup(uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.delete_account_posts_and_activate_cleanup(uuid, jsonb, jsonb) to service_role;

-- Fail closed if another listing still references the exact queued object.
-- Only rows whose current status uses a given bucket protect its objects.
-- Pending rows use private pending-images; approved rows use their public bucket.
create or replace function public.is_storage_cleanup_object_referenced(
  p_bucket text,
  p_object_path text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  referenced boolean;
begin
  if p_bucket not in ('listing-images','market-images','pending-images')
     or p_object_path is null
     or length(p_object_path) < 1
     or length(p_object_path) > 220 then
    return true;
  end if;

  if p_bucket = 'market-images' then
    select exists (
      select 1 from public.market_posts r
       where r.status = 'approved'
         and p_object_path = any(coalesce(r.image_urls, array[]::text[]))
    ) into referenced;
    return referenced;
  end if;

  if p_bucket = 'listing-images' then
    select
      exists (select 1 from public.service_requests r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      or exists (select 1 from public.job_posts r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      or exists (select 1 from public.real_estate_posts r where r.status = 'approved' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
      into referenced;
    return referenced;
  end if;

  select
    exists (select 1 from public.service_requests r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.job_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.real_estate_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    or exists (select 1 from public.market_posts r where r.status = 'pending' and p_object_path = any(coalesce(r.image_urls, array[]::text[])))
    into referenced;
  return referenced;
end;
$$;

revoke all on function public.is_storage_cleanup_object_referenced(text, text) from public, anon, authenticated;
grant execute on function public.is_storage_cleanup_object_referenced(text, text) to service_role;

-- Atomically delete one reviewed listing snapshot and activate only images no longer referenced.
create or replace function public.delete_post_and_activate_storage_cleanup(
  p_table text,
  p_id bigint,
  p_expected_user_id uuid,
  p_require_owner boolean,
  p_expected_row jsonb,
  p_jobs jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  expected_bucket text;
  requested_count integer;
  expected_count integer;
  queued_count integer;
  activated_count integer;
  deleted_count integer;
begin
  if p_table not in ('service_requests','job_posts','real_estate_posts','market_posts')
     or p_id is null
     or p_require_owner is null
     or (p_require_owner and p_expected_user_id is null)
     or pg_catalog.jsonb_typeof(p_expected_row) is distinct from 'object'
     or pg_catalog.jsonb_typeof(p_expected_row->'image_urls') is distinct from 'array'
     or pg_catalog.jsonb_typeof(p_jobs) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500 then
    raise exception 'Invalid post cleanup request';
  end if;

  expected_bucket := case when p_table = 'market_posts' then 'market-images' else 'listing-images' end;

  with expected as (
    select expected_bucket as bucket, p.path as object_path
      from pg_catalog.jsonb_array_elements_text(p_expected_row->'image_urls') as p(path)
    union
    select 'pending-images'::text, p.path
      from pg_catalog.jsonb_array_elements_text(p_expected_row->'image_urls') as p(path)
  ),
  requested as (
    select distinct x.bucket, x.object_path
      from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
  )
  select
    (select count(*) from requested),
    (select count(*) from expected),
    (select count(*) from (
      (select bucket, object_path from requested except select bucket, object_path from expected)
      union all
      (select bucket, object_path from expected except select bucket, object_path from requested)
    ) differences)
  into requested_count, expected_count, queued_count;

  if requested_count <> expected_count or queued_count <> 0 then
    raise exception 'Cleanup job list does not match the reviewed image snapshot';
  end if;

  select count(*) into queued_count
    from public.storage_cleanup_jobs q
    join pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
      on q.bucket = x.bucket and q.object_path = x.object_path
   where q.status in ('staged','pending','processing','completed','dead_letter');

  if queued_count <> requested_count then
    raise exception 'Cleanup queue is incomplete; post deletion aborted';
  end if;

  execute pg_catalog.format(
    'delete from public.%I as listing where id = $1 and pg_catalog.to_jsonb(listing) = $2 and (not $3 or user_id = $4)',
    p_table
  )
  using p_id, p_expected_row, p_require_owner, p_expected_user_id;

  get diagnostics deleted_count = row_count;
  if deleted_count <> 1 then
    return pg_catalog.jsonb_build_object('deleted', false, 'activated_jobs', 0);
  end if;

  update public.storage_cleanup_jobs q
     set status = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path) then 'staged'
           else 'pending'
         end,
         attempts = 0,
         lease_until = null,
         lease_token = null,
         last_error = case
           when public.is_storage_cleanup_object_referenced(q.bucket, q.object_path)
             then 'Image is still referenced by a live listing; deferred until the final reference is removed'
           else null
         end,
         completed_at = null,
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status in ('staged','pending','completed','dead_letter');

  select count(*) into activated_count
    from public.storage_cleanup_jobs q
    join pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
      on q.bucket = x.bucket and q.object_path = x.object_path
   where q.status in ('pending','processing','completed','dead_letter');

  return pg_catalog.jsonb_build_object(
    'deleted', true,
    'activated_jobs', activated_count,
    'deferred_jobs', requested_count - activated_count
  );
end;
$$;

revoke all on function public.delete_post_and_activate_storage_cleanup(text, bigint, uuid, boolean, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.delete_post_and_activate_storage_cleanup(text, bigint, uuid, boolean, jsonb, jsonb) to service_role;
