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
  if has_table_privilege('anon', 'public.storage_cleanup_jobs', 'SELECT')
     or has_table_privilege('authenticated', 'public.storage_cleanup_jobs', 'SELECT') then
    raise exception 'Untrusted roles can read the cleanup queue';
  end if;
  if has_function_privilege('anon', 'public.claim_storage_cleanup_jobs(integer)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.delete_account_posts_and_activate_cleanup(uuid,jsonb)', 'EXECUTE') then
    raise exception 'Untrusted roles can execute privileged cleanup RPCs';
  end if;
  if not has_function_privilege('service_role', 'public.claim_storage_cleanup_jobs(integer)', 'EXECUTE') then
    raise exception 'service_role cannot claim cleanup jobs';
  end if;

  begin
    insert into public.storage_cleanup_jobs(bucket,object_path)
    values ('listing-images','services/../escape.jpg');
    raise exception 'Expected unsafe path constraint to reject traversal';
  exception when check_violation then null;
  end;

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

  -- Account deletion proceeds, but shared image jobs stay staged until the final reference is removed.
  insert into public.service_requests(user_id,title,status,image_urls)
  values
    (u2,'owner listing','approved',array['services/shared.jpg']),
    (u3,'other listing','approved',array['services/shared.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values
    ('listing-images','services/shared.jpg','staged'),
    ('pending-images','services/shared.jpg','staged');

  result := public.delete_account_posts_and_activate_cleanup(
    u2,
    '[{"bucket":"listing-images","object_path":"services/shared.jpg"},{"bucket":"pending-images","object_path":"services/shared.jpg"}]'::jsonb
  );
  if (result->>'deleted_rows')::integer <> 1
     or (result->>'cleanup_jobs')::integer <> 0
     or (result->>'deferred_jobs')::integer <> 2 then
    raise exception 'Shared-image account deletion did not defer cleanup: %', result;
  end if;
  if (select count(*) from public.service_requests where user_id=u2) <> 0 then
    raise exception 'Account deletion did not remove its listing row';
  end if;
  if (select count(*) from public.storage_cleanup_jobs where object_path='services/shared.jpg' and status='staged') <> 2 then
    raise exception 'Shared-image jobs should remain staged until final reference is removed';
  end if;

  result := public.delete_account_posts_and_activate_cleanup(
    u3,
    '[{"bucket":"listing-images","object_path":"services/shared.jpg"},{"bucket":"pending-images","object_path":"services/shared.jpg"}]'::jsonb
  );
  if (result->>'deleted_rows')::integer <> 1
     or (result->>'cleanup_jobs')::integer <> 2
     or (result->>'deferred_jobs')::integer <> 0 then
    raise exception 'Final account deletion did not activate deferred image cleanup: %', result;
  end if;

  -- The worker must refuse an image still referenced by any live listing.
  insert into public.service_requests(user_id,title,status,image_urls)
  values (u2,'shared reference','approved',array['services/retained.jpg']);
  if not public.is_storage_cleanup_object_referenced('listing-images','services/retained.jpg') then
    raise exception 'Worker reference check missed a live listing image';
  end if;
  if not public.is_storage_cleanup_object_referenced('pending-images','services/retained.jpg') then
    raise exception 'Worker reference check missed a pending-bucket image reference';
  end if;
  if public.is_storage_cleanup_object_referenced('market-images','services/retained.jpg') then
    raise exception 'Worker reference check crossed bucket boundaries';
  end if;
  insert into public.market_posts(user_id,title,status,image_urls)
  values (u2,'market image reference','approved',array['market/retained.webp']);
  if not public.is_storage_cleanup_object_referenced('market-images','market/retained.webp') then
    raise exception 'Worker reference check missed a market image';
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

  update public.storage_cleanup_jobs set status='completed'
   where object_path='services/a.jpg';

  -- Single-post deletion and queue activation happen in one transaction.
  insert into public.service_requests(user_id,title,description,status,image_urls)
  values (u2,'atomic post','snapshot','pending',array['services/atomic.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values
    ('listing-images','services/atomic.jpg','staged'),
    ('pending-images','services/atomic.jpg','staged');
  select id into n from public.service_requests where user_id=u2 and title='atomic post';
  result := public.delete_post_and_activate_storage_cleanup(
    'service_requests',n,u2,true,'atomic post','snapshot','pending',
    array['services/atomic.jpg'],
    '[{"bucket":"listing-images","object_path":"services/atomic.jpg"},{"bucket":"pending-images","object_path":"services/atomic.jpg"}]'::jsonb
  );
  if result->>'deleted' <> 'true' or (result->>'activated_jobs')::integer <> 2 then
    raise exception 'Atomic single-post delete did not activate both image jobs: %', result;
  end if;
  if exists(select 1 from public.service_requests where title='atomic post') then
    raise exception 'Atomic single-post delete left the listing row';
  end if;
  if (select count(*) from public.storage_cleanup_jobs where object_path='services/atomic.jpg' and status='pending') <> 2 then
    raise exception 'Atomic single-post delete left cleanup jobs staged';
  end if;

  -- A shared image is deferred, not deleted, until its final listing is removed.
  insert into public.service_requests(user_id,title,description,status,image_urls)
  values
    (u2,'shared one','snapshot','approved',array['services/shared-atomic.jpg']),
    (u3,'shared two','snapshot','approved',array['services/shared-atomic.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values
    ('listing-images','services/shared-atomic.jpg','staged'),
    ('pending-images','services/shared-atomic.jpg','staged');
  select id into n from public.service_requests where user_id=u2 and title='shared one';
  result := public.delete_post_and_activate_storage_cleanup(
    'service_requests',n,u2,true,'shared one','snapshot','approved',
    array['services/shared-atomic.jpg'],
    '[{"bucket":"listing-images","object_path":"services/shared-atomic.jpg"},{"bucket":"pending-images","object_path":"services/shared-atomic.jpg"}]'::jsonb
  );
  if result->>'deleted' <> 'true' or (result->>'activated_jobs')::integer <> 0
     or (result->>'deferred_jobs')::integer <> 2 then
    raise exception 'Shared image was not safely deferred: %', result;
  end if;
  if (select count(*) from public.storage_cleanup_jobs where object_path='services/shared-atomic.jpg' and status='staged') <> 2 then
    raise exception 'Shared image cleanup jobs should remain staged';
  end if;
  select id into n from public.service_requests where user_id=u3 and title='shared two';
  result := public.delete_post_and_activate_storage_cleanup(
    'service_requests',n,u3,true,'shared two','snapshot','approved',
    array['services/shared-atomic.jpg'],
    '[{"bucket":"listing-images","object_path":"services/shared-atomic.jpg"},{"bucket":"pending-images","object_path":"services/shared-atomic.jpg"}]'::jsonb
  );
  if result->>'deleted' <> 'true' or (result->>'activated_jobs')::integer <> 2 then
    raise exception 'Final shared-image deletion did not activate deferred jobs: %', result;
  end if;

  -- A stale listing snapshot cannot delete a changed row.
  insert into public.service_requests(user_id,title,description,status,image_urls)
  values (u2,'stale atomic','old','pending',array['services/newer.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('listing-images','services/older.jpg','staged'),('pending-images','services/older.jpg','staged');
  select id into n from public.service_requests where user_id=u2 and title='stale atomic';
  result := public.delete_post_and_activate_storage_cleanup(
    'service_requests',n,u2,true,'stale atomic','old','pending',
    array['services/older.jpg'],
    '[{"bucket":"listing-images","object_path":"services/older.jpg"},{"bucket":"pending-images","object_path":"services/older.jpg"}]'::jsonb
  );
  if result->>'deleted' <> 'false' then
    raise exception 'Stale listing snapshot unexpectedly deleted a row: %', result;
  end if;
  if not exists(select 1 from public.service_requests where user_id=u2 and title='stale atomic' and image_urls=array['services/newer.jpg']) then
    raise exception 'Stale listing snapshot did not preserve the changed row';
  end if;

  -- Isolate the lease test from pending jobs created by the deletion tests above.
  update public.storage_cleanup_jobs set status='completed', lease_until=null where status in ('pending','processing');

  -- Claiming is exclusive; an expired lease can be reclaimed and increments attempts.
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('market-images','market/a.webp','pending');
  select * into claimed from public.claim_storage_cleanup_jobs(1)
   where object_path='market/a.webp';
  if claimed.id is null then raise exception 'Worker failed to claim pending job'; end if;
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
