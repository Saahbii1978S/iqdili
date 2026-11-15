\set ON_ERROR_STOP on

do $$
begin
  create role anon nologin;
exception when duplicate_object then null;
end $$;
do $$
begin
  create role authenticated nologin;
exception when duplicate_object then null;
end $$;
do $$
begin
  create role service_role nologin bypassrls;
exception when duplicate_object then alter role service_role bypassrls;
end $$;

create table public.service_requests (
  id bigint generated always as identity primary key,
  user_id uuid,
  title text not null,
  description text,
  status text not null,
  image_urls text[] not null default '{}'
);
create table public.job_posts (like public.service_requests including all);
create table public.real_estate_posts (like public.service_requests including all);
create table public.market_posts (like public.service_requests including all);

\ir ../migrations/20261115090000_storage_cleanup_jobs.sql

do $$
declare
  result jsonb;
  job record;
  claimed record;
  n integer;
  u1 uuid := '11111111-1111-4111-8111-111111111111';
  u2 uuid := '22222222-2222-4222-8222-222222222222';
  u3 uuid := '33333333-3333-4333-8333-333333333333';
begin
  -- Successful account deletion removes rows and activates the exact two-bucket image jobs.
  insert into public.service_requests(user_id,title,status,image_urls)
  values (u1,'test listing','approved',array['services/a.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values
    ('listing-images','services/a.jpg','staged'),
    ('pending-images','services/a.jpg','staged');

  result := public.delete_account_posts_and_activate_cleanup(
    u1,
    '[{"bucket":"listing-images","object_path":"services/a.jpg"},{"bucket":"pending-images","object_path":"services/a.jpg"}]'::jsonb
  );
  if (result->>'deleted_rows')::integer <> 1 or (result->>'cleanup_jobs')::integer <> 2 then
    raise exception 'Unexpected successful account deletion result: %', result;
  end if;
  if exists(select 1 from public.service_requests where user_id=u1) then
    raise exception 'Account listing row was not deleted';
  end if;
  if (select count(*) from public.storage_cleanup_jobs where object_path='services/a.jpg' and status='pending') <> 2 then
    raise exception 'Account cleanup jobs were not activated';
  end if;

  -- Shared paths are not deleted when another account still references the same image.
  insert into public.service_requests(user_id,title,status,image_urls)
  values
    (u2,'owner listing','approved',array['services/shared.jpg']),
    (u3,'other listing','approved',array['services/shared.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values
    ('listing-images','services/shared.jpg','staged'),
    ('pending-images','services/shared.jpg','staged');

  begin
    perform public.delete_account_posts_and_activate_cleanup(
      u2,
      '[{"bucket":"listing-images","object_path":"services/shared.jpg"},{"bucket":"pending-images","object_path":"services/shared.jpg"}]'::jsonb
    );
    raise exception 'Expected shared-image deletion to be rejected';
  exception when others then
    if sqlerrm not like '%still referenced by another listing%' then raise; end if;
  end;
  if (select count(*) from public.service_requests where user_id=u2) <> 1 then
    raise exception 'Shared-image rejection did not roll back listing deletion';
  end if;
  if (select count(*) from public.storage_cleanup_jobs where object_path='services/shared.jpg' and status='staged') <> 2 then
    raise exception 'Shared-image rejection changed queue state';
  end if;

  -- A stale snapshot is rejected atomically.
  insert into public.service_requests(user_id,title,status,image_urls)
  values (u3,'changed listing','approved',array['services/new.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('listing-images','services/old.jpg','staged'),('pending-images','services/old.jpg','staged');
  begin
    perform public.delete_account_posts_and_activate_cleanup(
      u3,
      '[{"bucket":"listing-images","object_path":"services/old.jpg"},{"bucket":"pending-images","object_path":"services/old.jpg"}]'::jsonb
    );
    raise exception 'Expected stale snapshot to be rejected';
  exception when others then
    if sqlerrm not like '%changed during deletion%' then raise; end if;
  end;
  if not exists(select 1 from public.service_requests where user_id=u3 and image_urls=array['services/new.jpg']) then
    raise exception 'Stale snapshot rejection did not preserve the changed row';
  end if;

  -- Claiming is exclusive; an expired lease can be reclaimed and increments attempts.
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('market-images','market/a.webp','pending');
  select * into claimed from public.claim_storage_cleanup_jobs(1)
   where object_path='market/a.webp';
  if claimed.id is null or claimed.status is not null then
    -- The function returns only id/bucket/path/attempts; status is checked in the table below.
    if claimed.id is null then raise exception 'Worker failed to claim pending job'; end if;
  end if;
  if (select status from public.storage_cleanup_jobs where id=claimed.id) <> 'processing'
     or claimed.attempts <> 1 then
    raise exception 'Claim did not set processing lease and attempt count';
  end if;
  if exists(select 1 from public.claim_storage_cleanup_jobs(1) where id=claimed.id) then
    raise exception 'Live lease was claimed by a second worker';
  end if;
  update public.storage_cleanup_jobs set lease_until=now()-interval '1 minute' where id=claimed.id;
  select * into claimed from public.claim_storage_cleanup_jobs(1) where object_path='market/a.webp';
  if claimed.id is null or claimed.attempts <> 2 then
    raise exception 'Expired lease was not reclaimed';
  end if;

  -- Explicit activation RPC confirms every requested job is no longer staged.
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('listing-images','jobs/activation.jpg','staged');
  n := public.activate_storage_cleanup_jobs(
    '[{"bucket":"listing-images","object_path":"jobs/activation.jpg"}]'::jsonb
  );
  if n <> 1 then raise exception 'Activation RPC returned unexpected count: %', n; end if;
end $$;
