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
  image_urls text[] not null default '{}',
  expires_at timestamptz,
  price numeric,
  phone text,
  city text,
  contact_public boolean not null default false
);
create table public.job_posts (like public.service_requests including all);
create table public.real_estate_posts (like public.service_requests including all);
create table public.market_posts (like public.service_requests including all);

create schema if not exists auth;
-- Minimal Auth catalog stub for the local PostgreSQL regression harness.
-- Production Supabase provides this table; the test container does not.
create table if not exists auth.users (
  id uuid primary key
);
create or replace function auth.uid()
returns uuid
language sql stable
as $auth_stub$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$auth_stub$;
create or replace function public.is_admin()
returns boolean
language sql stable
as $admin_stub$
  -- Synthetic owner identity for the isolated RLS harness; all other users
  -- are non-admins. This is not copied to production.
  select auth.uid() = '11111111-1111-4111-8111-111111111111'::uuid;
$admin_stub$;

\ir ../migrations/20261115090000_storage_cleanup_jobs.sql
\ir ../migrations/20261115120000_storage_cleanup_attachment_lock.sql
\ir ../migrations/20261115150000_storage_cleanup_detachment_lock.sql
\ir ../migrations/20261116100000_storage_cleanup_atomic_defer.sql
\ir ../migrations/20261116130000_account_deletion_limits.sql

-- Reproduce the verified production access shape for the four modern listing
-- tables: authenticated direct reads/updates are admin-only; anon has no table
-- grant. The public approved-listing RPCs are not reconstructed in this harness.
alter table public.service_requests enable row level security;
alter table public.job_posts enable row level security;
alter table public.real_estate_posts enable row level security;
alter table public.market_posts enable row level security;

grant select, update on public.service_requests, public.job_posts,
  public.real_estate_posts, public.market_posts to authenticated;

create policy service_requests_admin_select on public.service_requests
  for select to authenticated using (public.is_admin());
create policy service_requests_admin_update on public.service_requests
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy job_posts_admin_select on public.job_posts
  for select to authenticated using (public.is_admin());
create policy job_posts_admin_update on public.job_posts
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy real_estate_posts_admin_select on public.real_estate_posts
  for select to authenticated using (public.is_admin());
create policy real_estate_posts_admin_update on public.real_estate_posts
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy market_posts_admin_select on public.market_posts
  for select to authenticated using (public.is_admin());
create policy market_posts_admin_update on public.market_posts
  for update to authenticated using (public.is_admin()) with check (public.is_admin());


-- Minimal Auth users required by the account-deletion lock FK in the local test database.
insert into auth.users(id) values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222'),
  ('33333333-3333-4333-8333-333333333333'),
  ('44444444-4444-4444-8444-444444444444'),
  ('55555555-5555-4555-8555-555555555555'),
  ('66666666-6666-4666-8666-666666666666'),
  ('77777777-7777-4777-8777-777777777777'),
  ('88888888-8888-4888-8888-888888888888'),
  ('99999999-9999-4999-8999-999999999999');

create or replace function public.test_account_snapshot(p_user_id uuid)
returns jsonb
language sql
stable
as $$
  select pg_catalog.jsonb_build_object(
    'service_requests', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id) from public.service_requests r where r.user_id=p_user_id), '[]'::jsonb),
    'job_posts', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id) from public.job_posts r where r.user_id=p_user_id), '[]'::jsonb),
    'real_estate_posts', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id) from public.real_estate_posts r where r.user_id=p_user_id), '[]'::jsonb),
    'market_posts', coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.id) from public.market_posts r where r.user_id=p_user_id), '[]'::jsonb)
  );
$$;

do $$
declare
  result jsonb;
  expected_row jsonb;
  expected_account_rows jsonb;
  job record;
  claimed record;
  stale_lease_token uuid;
  affected integer;
  deferred boolean;
  n integer;
  u1 uuid := '11111111-1111-4111-8111-111111111111';
  u2 uuid := '22222222-2222-4222-8222-222222222222';
  u3 uuid := '33333333-3333-4333-8333-333333333333';
  u4 uuid := '44444444-4444-4444-8444-444444444444';
  u5 uuid := '55555555-5555-4555-8555-555555555555';
  u6 uuid := '66666666-6666-4666-8666-666666666666';
  u7 uuid := '77777777-7777-4777-8777-777777777777';
  u8 uuid := '88888888-8888-4888-8888-888888888888';
  u9 uuid := '99999999-9999-4999-8999-999999999999';
begin
  if has_table_privilege('anon', 'public.storage_cleanup_jobs', 'SELECT')
     or has_table_privilege('authenticated', 'public.storage_cleanup_jobs', 'SELECT') then
    raise exception 'Untrusted roles can read the cleanup queue';
  end if;
  if has_function_privilege('anon', 'public.claim_storage_cleanup_jobs(integer)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.delete_account_posts_and_activate_cleanup(uuid,jsonb,jsonb)', 'EXECUTE') then
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

  -- Approval is an atomic compare-and-set: only the exact reviewed pending snapshot can publish.
  perform pg_catalog.set_config('request.jwt.claim.sub', u1::text, true);
  insert into public.service_requests(user_id,title,description,status,image_urls)
  values (u1,'approval snapshot','description','pending',array['services/source.jpg']);
  select id into n from public.service_requests where user_id=u1 and title='approval snapshot';
  if not public.approve_post_if_unchanged(
    'service_requests',n,
    (select pg_catalog.to_jsonb(r) from public.service_requests r where r.id=n),
    array['services/approved-unique.jpg'],now()+interval '3 months'
  ) then
    raise exception 'Exact approval snapshot was not approved';
  end if;
  if not exists (
    select 1 from public.service_requests
     where id=n and status='approved'
       and image_urls=array['services/approved-unique.jpg']
  ) then
    raise exception 'Approval did not atomically replace image paths and status';
  end if;

  insert into public.service_requests(user_id,title,description,status,image_urls,price,phone,city,contact_public)
  values (u1,'stale approval','before','pending',array['services/original.jpg'],150,'20000000','Sfax',true);
  select id into n from public.service_requests where user_id=u1 and title='stale approval';
  select pg_catalog.to_jsonb(r) into expected_row from public.service_requests r where r.id=n;
  update public.service_requests set price=200, phone='21111111' where id=n;
  if public.approve_post_if_unchanged(
    'service_requests',n,expected_row,
    array['services/should-not-publish.jpg'],now()+interval '3 months'
  ) then
    raise exception 'Stale approval snapshot was incorrectly published';
  end if;
  if not exists (
    select 1 from public.service_requests
     where id=n and status='pending'
       and description='before'
       and price=200
       and phone='21111111'
       and image_urls=array['services/original.jpg']
  ) then
    raise exception 'Stale approval attempt changed the listing';
  end if;
  delete from public.service_requests where title in ('approval snapshot','stale approval');
  perform pg_catalog.set_config('request.jwt.claim.sub', '', true);

  -- Status changes accept only the intended transition and the exact full reviewed row.
  perform pg_catalog.set_config('request.jwt.claim.sub', u1::text, true);
  insert into public.service_requests(user_id,title,description,status,image_urls,price,phone)
  values (u1,'reject transition','pending content','pending',array['services/reject.jpg'],90,'22222222');
  select id into n from public.service_requests where user_id=u1 and title='reject transition';
  select pg_catalog.to_jsonb(r) into expected_row from public.service_requests r where r.id=n;
  if not public.update_post_status_if_unchanged('service_requests',n,expected_row,'rejected') then
    raise exception 'Valid pending-to-rejected transition was rejected';
  end if;
  if not exists(select 1 from public.service_requests where id=n and status='rejected') then
    raise exception 'Rejected transition did not update status';
  end if;

  insert into public.market_posts(user_id,title,description,status,image_urls,price,phone)
  values (u1,'unpublish transition','approved content','approved',array['market/unpublish.jpg'],50,'23333333');
  select id into n from public.market_posts where user_id=u1 and title='unpublish transition';
  select pg_catalog.to_jsonb(r) into expected_row from public.market_posts r where r.id=n;
  if not public.update_post_status_if_unchanged('market_posts',n,expected_row,'unpublished') then
    raise exception 'Valid approved-to-unpublished transition was rejected';
  end if;
  if not exists(select 1 from public.market_posts where id=n and status='unpublished') then
    raise exception 'Unpublished transition did not update status';
  end if;

  insert into public.real_estate_posts(user_id,title,description,status,image_urls,price,phone)
  values (u1,'stale status transition','before edit','approved',array['realty/stale.jpg'],100,'24444444');
  select id into n from public.real_estate_posts where user_id=u1 and title='stale status transition';
  select pg_catalog.to_jsonb(r) into expected_row from public.real_estate_posts r where r.id=n;
  update public.real_estate_posts set price=200 where id=n;
  if public.update_post_status_if_unchanged('real_estate_posts',n,expected_row,'unpublished') then
    raise exception 'Stale status transition changed a modified listing';
  end if;
  if not exists(select 1 from public.real_estate_posts where id=n and status='approved' and price=200) then
    raise exception 'Stale status transition did not preserve the edited listing';
  end if;
  delete from public.service_requests where title='reject transition';
  delete from public.market_posts where title='unpublish transition';
  delete from public.real_estate_posts where title='stale status transition';
  perform pg_catalog.set_config('request.jwt.claim.sub', '', true);

  -- Successful account deletion removes rows and activates the exact two-bucket image jobs.
  insert into public.service_requests(user_id,title,status,image_urls)
  values (u1,'test listing','approved',array['services/a.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values
    ('listing-images','services/a.jpg','staged'),
    ('pending-images','services/a.jpg','staged');

  result := public.delete_account_posts_and_activate_cleanup(
    u1,
    '[{"bucket":"listing-images","object_path":"services/a.jpg"},{"bucket":"pending-images","object_path":"services/a.jpg"}]'::jsonb,
    public.test_account_snapshot(u1)
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

  -- The persistent deletion lock must reject new listings after the DB transaction,
  -- including the gap where the separate Auth deletion API may need a retry.
  begin
    insert into public.service_requests(user_id,title,status,image_urls)
    values (u1,'late listing after account deletion','pending',array[]::text[]);
    raise exception 'Expected account deletion lock to reject a new listing';
  exception when others then
    if sqlerrm not like '%Account deletion is in progress%' then raise; end if;
  end;
  if exists(select 1 from public.service_requests where user_id=u1) then
    raise exception 'A listing was inserted after account deletion began';
  end if;

  -- The persistent account lock must cover every listing category, not only services.
  begin
    insert into public.job_posts(user_id,title,status,image_urls)
    values (u1,'blocked job','pending',array[]::text[]);
    raise exception 'Expected account deletion lock to block job_posts';
  exception when others then
    if sqlerrm not like '%Account deletion is in progress%' then raise; end if;
  end;
  begin
    insert into public.real_estate_posts(user_id,title,status,image_urls)
    values (u1,'blocked property','pending',array[]::text[]);
    raise exception 'Expected account deletion lock to block real_estate_posts';
  exception when others then
    if sqlerrm not like '%Account deletion is in progress%' then raise; end if;
  end;
  begin
    insert into public.market_posts(user_id,title,status,image_urls)
    values (u1,'blocked market post','pending',array[]::text[]);
    raise exception 'Expected account deletion lock to block market_posts';
  exception when others then
    if sqlerrm not like '%Account deletion is in progress%' then raise; end if;
  end;

  -- Changing ownership into a deletion-locked account must also be rejected.
  insert into public.job_posts(user_id,title,status,image_urls)
  values (u4,'ownership transfer fixture','pending',array[]::text[]);
  begin
    update public.job_posts set user_id=u1 where user_id=u4 and title='ownership transfer fixture';
    raise exception 'Expected ownership transfer into a deletion-locked account to fail';
  exception when others then
    if sqlerrm not like '%Account deletion is in progress%' then raise; end if;
  end;
  if not exists(select 1 from public.job_posts where user_id=u4 and title='ownership transfer fixture') then
    raise exception 'Rejected ownership transfer changed the original listing';
  end if;
  delete from public.job_posts where user_id=u4 and title='ownership transfer fixture';

  -- Account deletion proceeds, but shared image jobs stay staged until the final reference is removed.
  insert into public.service_requests(user_id,title,status,image_urls)
  values
    (u2,'owner listing','approved',array['services/shared.jpg']),
    (u3,'other listing','approved',array['services/shared.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status,attempts,last_error)
  values
    ('listing-images','services/shared.jpg','dead_letter',8,'previously exhausted'),
    ('pending-images','services/shared.jpg','dead_letter',8,'previously exhausted');

  result := public.delete_account_posts_and_activate_cleanup(
    u2,
    '[{"bucket":"listing-images","object_path":"services/shared.jpg"},{"bucket":"pending-images","object_path":"services/shared.jpg"}]'::jsonb,
    public.test_account_snapshot(u2)
  );
  -- The approved listing references only the public bucket; its private source copy
  -- is not retained by the approved row and can be cleaned independently.
  if (result->>'deleted_rows')::integer <> 1
     or (result->>'cleanup_jobs')::integer <> 1
     or (result->>'deferred_jobs')::integer <> 1 then
    raise exception 'Shared-image account deletion did not defer the public copy: %', result;
  end if;
  if (select count(*) from public.service_requests where user_id=u2) <> 0 then
    raise exception 'Account deletion did not remove its listing row';
  end if;
  if (select count(*) from public.storage_cleanup_jobs where object_path='services/shared.jpg' and status='staged') <> 1
     or (select count(*) from public.storage_cleanup_jobs where object_path='services/shared.jpg' and status='pending') <> 1 then
    raise exception 'Public shared image should stay staged while its private copy is independently cleanable';
  end if;

  result := public.delete_account_posts_and_activate_cleanup(
    u3,
    '[{"bucket":"listing-images","object_path":"services/shared.jpg"},{"bucket":"pending-images","object_path":"services/shared.jpg"}]'::jsonb,
    public.test_account_snapshot(u3)
  );
  if (result->>'deleted_rows')::integer <> 1
     or (result->>'cleanup_jobs')::integer <> 2
     or (result->>'deferred_jobs')::integer <> 0 then
    raise exception 'Final account deletion did not activate deferred image cleanup: %', result;
  end if;

  -- A cleanup reservation prevents an object path from being attached again.
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('market-images','market/retired.webp','processing');
  begin
    insert into public.market_posts(user_id,title,status,image_urls)
    values (u4,'must not reuse retired image','approved',array['market/retired.webp']);
    raise exception 'Expected cleanup-reserved image attachment to be rejected';
  exception when others then
    if sqlerrm not like '%Image is reserved for cleanup%' then raise; end if;
  end;
  if exists(select 1 from public.market_posts where title='must not reuse retired image') then
    raise exception 'Cleanup-reserved image was attached to a listing';
  end if;

  -- Isolate the claim test from earlier deletion jobs.
  update public.storage_cleanup_jobs set status='completed', lease_until=null, lease_token=null
   where status in ('pending','processing');

  -- A queued path that already has a live reference is returned to staged,
  -- not handed to the Storage worker for deletion.
  insert into public.market_posts(user_id,title,status,image_urls)
  values (u4,'claim must defer referenced image','approved',array['market/referenced-claim.webp']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('market-images','market/referenced-claim.webp','pending');
  if exists (
    select 1 from public.claim_storage_cleanup_jobs(5)
     where object_path='market/referenced-claim.webp'
  ) then
    raise exception 'Worker claimed an image while a live listing referenced it';
  end if;
  if (select status from public.storage_cleanup_jobs
       where bucket='market-images' and object_path='market/referenced-claim.webp') <> 'staged' then
    raise exception 'Referenced cleanup job was not deferred to staged';
  end if;
  delete from public.market_posts where title='claim must defer referenced image';

  -- The worker must refuse an image still referenced by any live listing.
  insert into public.service_requests(user_id,title,status,image_urls)
  values (u4,'shared reference','approved',array['services/retained.jpg']);
  if not public.is_storage_cleanup_object_referenced('listing-images','services/retained.jpg') then
    raise exception 'Worker reference check missed a live listing image';
  end if;
  if public.is_storage_cleanup_object_referenced('pending-images','services/retained.jpg') then
    raise exception 'Approved listing should not retain a private pending-bucket copy';
  end if;
  insert into public.service_requests(user_id,title,status,image_urls)
  values (u5,'pending private image','pending',array['services/pending-only.jpg']);
  if not public.is_storage_cleanup_object_referenced('pending-images','services/pending-only.jpg') then
    raise exception 'Worker reference check missed a pending listing private image';
  end if;
  if public.is_storage_cleanup_object_referenced('listing-images','services/pending-only.jpg') then
    raise exception 'Pending listing should not retain a public-bucket copy';
  end if;
  delete from public.service_requests where title='pending private image';
  if public.is_storage_cleanup_object_referenced('market-images','services/retained.jpg') then
    raise exception 'Worker reference check crossed bucket boundaries';
  end if;
  insert into public.market_posts(user_id,title,status,image_urls)
  values (u4,'market image reference','approved',array['market/retained.webp']);
  if not public.is_storage_cleanup_object_referenced('market-images','market/retained.webp') then
    raise exception 'Worker reference check missed a market image';
  end if;

  -- A full-row snapshot rejects edits even when image paths stay identical.
  insert into public.service_requests(user_id,title,description,status,image_urls)
  values (u5,'changed listing','before edit','approved',array['services/new.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('listing-images','services/new.jpg','staged'),('pending-images','services/new.jpg','staged');
  expected_account_rows := public.test_account_snapshot(u5);
  update public.service_requests set description='edited after review'
   where user_id=u5 and title='changed listing';
  begin
    perform public.delete_account_posts_and_activate_cleanup(
      u5,
      '[{"bucket":"listing-images","object_path":"services/new.jpg"},{"bucket":"pending-images","object_path":"services/new.jpg"}]'::jsonb,
      expected_account_rows
    );
    raise exception 'Expected changed full-row snapshot to be rejected';
  exception when others then
    if sqlerrm not like '%changed during deletion%' then raise; end if;
  end;
  if not exists(select 1 from public.service_requests where user_id=u5 and title='changed listing' and description='edited after review') then
    raise exception 'Full-row snapshot rejection did not preserve the edited listing';
  end if;

  -- A newly-added row with no images must also invalidate the account snapshot.
  expected_account_rows := public.test_account_snapshot(u5);
  insert into public.service_requests(user_id,title,status,image_urls)
  values (u5,'new row without images','pending',array[]::text[]);
  begin
    perform public.delete_account_posts_and_activate_cleanup(
      u5, '[]'::jsonb, expected_account_rows
    );
    raise exception 'Expected newly-added empty-image listing to be rejected';
  exception when others then
    if sqlerrm not like '%changed during deletion%' then raise; end if;
  end;
  if not exists(select 1 from public.service_requests where user_id=u5 and title='new row without images') then
    raise exception 'Snapshot rejection deleted a newly-added empty-image listing';
  end if;

  update public.storage_cleanup_jobs set status='completed'
   where object_path='services/a.jpg';

  -- Single-post deletion and queue activation happen in one transaction.
  insert into public.service_requests(user_id,title,description,status,image_urls)
  values (u4,'atomic post','snapshot','pending',array['services/atomic.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values
    ('listing-images','services/atomic.jpg','staged'),
    ('pending-images','services/atomic.jpg','staged');
  select id into n from public.service_requests where user_id=u4 and title='atomic post';
  select pg_catalog.to_jsonb(r) into expected_row from public.service_requests r where r.id=n;
  result := public.delete_post_and_activate_storage_cleanup(
    'service_requests',n,u4,true,expected_row,
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
    (u4,'shared one','snapshot','approved',array['services/shared-atomic.jpg']),
    (u5,'shared two','snapshot','approved',array['services/shared-atomic.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values
    ('listing-images','services/shared-atomic.jpg','staged'),
    ('pending-images','services/shared-atomic.jpg','staged');
  select id into n from public.service_requests where user_id=u4 and title='shared one';
  select pg_catalog.to_jsonb(r) into expected_row from public.service_requests r where r.id=n;
  result := public.delete_post_and_activate_storage_cleanup(
    'service_requests',n,u4,true,expected_row,
    '[{"bucket":"listing-images","object_path":"services/shared-atomic.jpg"},{"bucket":"pending-images","object_path":"services/shared-atomic.jpg"}]'::jsonb
  );
  -- Approved rows reference the public object only; the private copy is independent.
  if result->>'deleted' <> 'true' or (result->>'activated_jobs')::integer <> 1
     or (result->>'deferred_jobs')::integer <> 1 then
    raise exception 'Shared public image was not safely deferred: %', result;
  end if;
  if (select count(*) from public.storage_cleanup_jobs where object_path='services/shared-atomic.jpg' and status='staged') <> 1
     or (select count(*) from public.storage_cleanup_jobs where object_path='services/shared-atomic.jpg' and status='pending') <> 1 then
    raise exception 'Public shared image should stay staged while its private copy is independently cleanable';
  end if;
  select id into n from public.service_requests where user_id=u5 and title='shared two';
  select pg_catalog.to_jsonb(r) into expected_row from public.service_requests r where r.id=n;
  result := public.delete_post_and_activate_storage_cleanup(
    'service_requests',n,u5,true,expected_row,
    '[{"bucket":"listing-images","object_path":"services/shared-atomic.jpg"},{"bucket":"pending-images","object_path":"services/shared-atomic.jpg"}]'::jsonb
  );
  if result->>'deleted' <> 'true' or (result->>'activated_jobs')::integer <> 2 then
    raise exception 'Final shared-image deletion did not activate deferred jobs: %', result;
  end if;

  -- A stale listing snapshot cannot delete a changed row.
  insert into public.service_requests(user_id,title,description,status,image_urls)
  values (u4,'stale atomic','old','pending',array['services/newer.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('listing-images','services/newer.jpg','staged'),('pending-images','services/newer.jpg','staged');
  select id into n from public.service_requests where user_id=u4 and title='stale atomic';
  select pg_catalog.to_jsonb(r) into expected_row from public.service_requests r where r.id=n;
  update public.service_requests set phone='29999999' where id=n;
  result := public.delete_post_and_activate_storage_cleanup(
    'service_requests',n,u4,true,expected_row,
    '[{"bucket":"listing-images","object_path":"services/newer.jpg"},{"bucket":"pending-images","object_path":"services/newer.jpg"}]'::jsonb
  );
  if result->>'deleted' <> 'false' then
    raise exception 'Stale listing snapshot unexpectedly deleted a row: %', result;
  end if;
  if not exists(select 1 from public.service_requests where user_id=u4 and title='stale atomic' and image_urls=array['services/newer.jpg'] and phone='29999999') then
    raise exception 'Stale listing snapshot did not preserve the changed row';
  end if;

  -- Isolate the lease test from pending jobs created by the deletion tests above.
  update public.storage_cleanup_jobs set status='completed', lease_until=null where status in ('pending','processing');

  -- Claiming is exclusive; an expired lease can be reclaimed and increments attempts.
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('market-images','market/a.webp','pending');
  select * into claimed from public.claim_storage_cleanup_jobs(1)
   where object_path='market/a.webp';
  if claimed.id is null or claimed.lease_token is null then
    raise exception 'Worker failed to claim pending job with a lease token';
  end if;
  if (select status from public.storage_cleanup_jobs where id=claimed.id) <> 'processing'
     or claimed.attempts <> 1 then
    raise exception 'Claim did not set processing lease and attempt count';
  end if;
  stale_lease_token := claimed.lease_token;
  if exists(select 1 from public.claim_storage_cleanup_jobs(1) where id=claimed.id) then
    raise exception 'Live lease was claimed by a second worker';
  end if;
  update public.storage_cleanup_jobs set lease_until=now()-interval '1 minute' where id=claimed.id;
  select * into claimed from public.claim_storage_cleanup_jobs(1) where object_path='market/a.webp';
  if claimed.id is null or claimed.attempts <> 2 or claimed.lease_token is null
     or claimed.lease_token = stale_lease_token then
    raise exception 'Expired lease was not reclaimed with a fresh token';
  end if;

  -- A stale worker cannot complete or overwrite a job claimed by the newer worker.
  update public.storage_cleanup_jobs
     set status='completed', lease_until=null, lease_token=null
   where id=claimed.id and status='processing' and lease_token=stale_lease_token;
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'Stale worker changed the newer worker lease';
  end if;
  update public.storage_cleanup_jobs
     set status='completed', lease_until=null, lease_token=null
   where id=claimed.id and status='processing' and lease_token=claimed.lease_token;
  get diagnostics affected = row_count;
  if affected <> 1 then
    raise exception 'Current worker could not complete its own lease';
  end if;

  -- Keep earlier staged fixtures out of the one-row retry claim below.
  update public.storage_cleanup_jobs set updated_at=now() where status='staged';

  -- Failed jobs record updated_at and observe bounded exponential retry backoff.
  insert into public.storage_cleanup_jobs(bucket,object_path,status,updated_at)
  values ('market-images','market/retry-backoff.webp','pending',now());
  select * into claimed from public.claim_storage_cleanup_jobs(1)
   where object_path='market/retry-backoff.webp';
  if claimed.id is null or claimed.attempts <> 1 then
    raise exception 'Retry-backoff fixture was not initially claimed';
  end if;
  update public.storage_cleanup_jobs
     set status='pending',lease_until=null,lease_token=null,updated_at=now()
   where id=claimed.id and status='processing' and lease_token=claimed.lease_token;
  if exists (
    select 1 from public.claim_storage_cleanup_jobs(1)
     where object_path='market/retry-backoff.webp'
  ) then
    raise exception 'Pending retry ignored its backoff window';
  end if;
  update public.storage_cleanup_jobs set updated_at=now()-interval '3 minutes'
   where id=claimed.id and status='pending';
  select * into claimed from public.claim_storage_cleanup_jobs(1)
   where object_path='market/retry-backoff.webp';
  if claimed.id is null or claimed.attempts <> 2 then
    raise exception 'Pending retry was not claimable after its backoff window';
  end if;
  update public.storage_cleanup_jobs
     set status='completed',lease_until=null,lease_token=null,completed_at=now(),updated_at=now()
   where id=claimed.id and status='processing' and lease_token=claimed.lease_token;

  -- Aged staged jobs are reclaimed for crash recovery; referenced jobs can be deferred without a hot loop.
  update public.storage_cleanup_jobs set updated_at=now() where status='staged';
  insert into public.storage_cleanup_jobs(bucket,object_path,status,updated_at)
  values ('listing-images','services/staged-recovery.jpg','staged',now()-interval '11 minutes');
  select * into claimed from public.claim_storage_cleanup_jobs(1)
   where object_path='services/staged-recovery.jpg';
  if claimed.id is null or claimed.attempts <> 1 then
    raise exception 'Worker did not reclaim an aged staged recovery job';
  end if;
  update public.storage_cleanup_jobs
     set status='staged',attempts=0,lease_until=null,lease_token=null,
         updated_at=now(),last_error='still referenced'
   where id=claimed.id and status='processing' and lease_token=claimed.lease_token;
  if exists (
    select 1 from public.claim_storage_cleanup_jobs(1)
     where object_path='services/staged-recovery.jpg'
  ) then
    raise exception 'A deferred staged job was immediately reclaimed again';
  end if;

  -- A referenced image is deferred once, then waits for its final detachment.
  -- The deletion RPC reactivates it; the worker must not poll it every ten minutes.
  insert into public.storage_cleanup_jobs(bucket,object_path,status,updated_at,last_error)
  values (
    'listing-images','services/deferred-reference.jpg','staged',
    now()-interval '11 minutes',
    'Image is still referenced by a live listing; deferred until the final reference is removed'
  );
  if exists (
    select 1 from public.claim_storage_cleanup_jobs(1)
     where object_path='services/deferred-reference.jpg'
  ) then
    raise exception 'A deferred referenced image was repeatedly reclaimed';
  end if;
  n := public.activate_storage_cleanup_jobs(
    '[{"bucket":"listing-images","object_path":"services/deferred-reference.jpg"}]'::jsonb
  );
  if n <> 1 then raise exception 'Final detachment did not reactivate the deferred image'; end if;
  if (select status from public.storage_cleanup_jobs
       where bucket='listing-images' and object_path='services/deferred-reference.jpg') <> 'pending'
     or (select last_error from public.storage_cleanup_jobs
          where bucket='listing-images' and object_path='services/deferred-reference.jpg') is not null then
    raise exception 'Reactivation did not clear deferred state';
  end if;
  select * into claimed from public.claim_storage_cleanup_jobs(1)
   where object_path='services/deferred-reference.jpg';
  if claimed.id is null or claimed.attempts <> 1 then
    raise exception 'Reactivated deferred image was not claimable after final detachment';
  end if;
  update public.storage_cleanup_jobs
     set status='completed',lease_until=null,lease_token=null,completed_at=now(),updated_at=now()
   where id=claimed.id and status='processing' and lease_token=claimed.lease_token;

  -- Removing the final image reference by editing a listing reactivates a deferred job.
  insert into public.service_requests(user_id,title,description,status,image_urls)
  values (u5,'final detach cleanup','snapshot','approved',array['services/final-detach.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status,updated_at,last_error)
  values (
    'listing-images','services/final-detach.jpg','staged',now()-interval '11 minutes',
    'Image is still referenced by a live listing; deferred until the final reference is removed'
  );
  update public.service_requests
     set image_urls=array[]::text[]
   where user_id=u5 and title='final detach cleanup';
  if (select status from public.storage_cleanup_jobs
       where bucket='listing-images' and object_path='services/final-detach.jpg') <> 'pending'
     or (select last_error from public.storage_cleanup_jobs
          where bucket='listing-images' and object_path='services/final-detach.jpg') is not null then
    raise exception 'Final image detachment did not reactivate its deferred cleanup job';
  end if;
  select * into claimed from public.claim_storage_cleanup_jobs(25)
   where object_path='services/final-detach.jpg';
  if claimed.id is null or claimed.attempts <> 1 then
    raise exception 'Reactivated cleanup job was not claimable after final image detachment';
  end if;
  update public.storage_cleanup_jobs
     set status='completed',lease_until=null,lease_token=null,completed_at=now(),updated_at=now()
   where id=claimed.id and status='processing' and lease_token=claimed.lease_token;

  -- Explicit activation RPC confirms every requested job is no longer staged.
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('listing-images','jobs/activation.jpg','staged');
  n := public.activate_storage_cleanup_jobs(
    '[{"bucket":"listing-images","object_path":"jobs/activation.jpg"}]'::jsonb
  );
  if n <> 1 then raise exception 'Activation RPC returned unexpected count: %', n; end if;

  -- An incomplete activation batch must roll back every status update.
  insert into public.storage_cleanup_jobs(bucket,object_path,status)
  values ('listing-images','jobs/activation-rollback.jpg','staged');
  begin
    perform public.activate_storage_cleanup_jobs(
      '[{"bucket":"listing-images","object_path":"jobs/activation-rollback.jpg"},{"bucket":"listing-images","object_path":"jobs/missing-activation.jpg"}]'::jsonb
    );
    raise exception 'Expected incomplete cleanup activation to abort';
  exception when others then
    if sqlerrm not like '%Cleanup activation batch is incomplete%' then raise; end if;
  end;
  if (select status from public.storage_cleanup_jobs
       where bucket='listing-images' and object_path='jobs/activation-rollback.jpg') <> 'staged' then
    raise exception 'Incomplete cleanup activation committed a partial status update';
  end if;

  -- Race ordering A: worker defers while the image is still referenced;
  -- the later final detachment trigger must reactivate the staged job.
  insert into public.service_requests(user_id,title,status,image_urls)
  values (u5,'defer before detach','approved',array['services/defer-before-detach.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status,attempts,lease_token)
  values ('listing-images','services/defer-before-detach.jpg','processing',1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  select id into n from public.storage_cleanup_jobs
   where bucket='listing-images' and object_path='services/defer-before-detach.jpg';
  deferred := public.defer_storage_cleanup_job(
    n,'listing-images','services/defer-before-detach.jpg','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  );
  if not deferred or (select status from public.storage_cleanup_jobs where id=n) <> 'staged' then
    raise exception 'Atomic defer did not stage an image that remains referenced';
  end if;
  delete from public.service_requests where user_id=u5 and title='defer before detach';
  if (select status from public.storage_cleanup_jobs where id=n) <> 'pending'
     or (select last_error from public.storage_cleanup_jobs where id=n) is not null then
    raise exception 'Final detachment did not reactivate a job deferred before deletion';
  end if;

  -- Race ordering B: final detachment commits after the worker's earlier
  -- reference check but before its defer request. The RPC must recheck under
  -- the same object lock and requeue, rather than strand a staged job.
  insert into public.service_requests(user_id,title,status,image_urls)
  values (u5,'detach before defer','approved',array['services/detach-before-defer.jpg']);
  insert into public.storage_cleanup_jobs(bucket,object_path,status,attempts,lease_token)
  values ('listing-images','services/detach-before-defer.jpg','processing',1,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
  select id into n from public.storage_cleanup_jobs
   where bucket='listing-images' and object_path='services/detach-before-defer.jpg';
  delete from public.service_requests where user_id=u5 and title='detach before defer';
  deferred := public.defer_storage_cleanup_job(
    n,'listing-images','services/detach-before-defer.jpg','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  );
  if not deferred
     or (select status from public.storage_cleanup_jobs where id=n) <> 'pending'
     or (select last_error from public.storage_cleanup_jobs where id=n) is not null then
    raise exception 'Atomic defer stranded an image detached immediately before deferral';
  end if;

  if has_function_privilege('anon', 'public.defer_storage_cleanup_job(bigint,text,text,uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.defer_storage_cleanup_job(bigint,text,text,uuid)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.defer_storage_cleanup_job(bigint,text,text,uuid)', 'EXECUTE') then
    raise exception 'Atomic defer RPC permissions are not restricted to service_role';
  end if;
  -- Deleting the Auth identity must cascade only its persistent deletion lock.
  if not exists(select 1 from public.account_deletion_locks where user_id=u1) then
    raise exception 'Expected account deletion lock to persist until Auth deletion';
  end if;
  delete from auth.users where id=u1;
  if exists(select 1 from public.account_deletion_locks where user_id=u1) then
    raise exception 'Auth user deletion did not cascade its account deletion lock';
  end if;

  -- Account listing cap is global across all four categories, not per table.
  if not has_function_privilege('service_role', 'public.account_post_count_within_limit(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.account_post_count_within_limit(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.account_post_count_within_limit(uuid)', 'EXECUTE') then
    raise exception 'Account listing count RPC permissions are not restricted to service_role';
  end if;
  insert into public.service_requests(user_id,title,status)
    select u6,'limit-9999-services-'||g,'pending' from generate_series(1,2500) g;
  insert into public.job_posts(user_id,title,status)
    select u6,'limit-9999-jobs-'||g,'pending' from generate_series(1,2500) g;
  insert into public.real_estate_posts(user_id,title,status)
    select u6,'limit-9999-realty-'||g,'pending' from generate_series(1,2500) g;
  insert into public.market_posts(user_id,title,status)
    select u6,'limit-9999-market-'||g,'pending' from generate_series(1,2499) g;
  if not public.account_post_count_within_limit(u6) then
    raise exception 'Account with 9,999 total listings should be allowed';
  end if;

  insert into public.service_requests(user_id,title,status)
    select u7,'limit-10000-services-'||g,'pending' from generate_series(1,2500) g;
  insert into public.job_posts(user_id,title,status)
    select u7,'limit-10000-jobs-'||g,'pending' from generate_series(1,2500) g;
  insert into public.real_estate_posts(user_id,title,status)
    select u7,'limit-10000-realty-'||g,'pending' from generate_series(1,2500) g;
  insert into public.market_posts(user_id,title,status)
    select u7,'limit-10000-market-'||g,'pending' from generate_series(1,2500) g;
  if public.account_post_count_within_limit(u7) then
    raise exception 'Account with 10,000 total listings should be rejected';
  end if;

  insert into public.service_requests(user_id,title,status)
    select u8,'limit-10001-services-'||g,'pending' from generate_series(1,2501) g;
  insert into public.job_posts(user_id,title,status)
    select u8,'limit-10001-jobs-'||g,'pending' from generate_series(1,2500) g;
  insert into public.real_estate_posts(user_id,title,status)
    select u8,'limit-10001-realty-'||g,'pending' from generate_series(1,2500) g;
  insert into public.market_posts(user_id,title,status)
    select u8,'limit-10001-market-'||g,'pending' from generate_series(1,2500) g;
  if public.account_post_count_within_limit(u8) then
    raise exception 'Account with 10,001 total listings should be rejected';
  end if;

  -- Deletion attempts are capped at three per hour, while a locked deletion can retry.
  if not has_function_privilege('service_role', 'public.consume_account_deletion_rate_limit(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.consume_account_deletion_rate_limit(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.consume_account_deletion_rate_limit(uuid)', 'EXECUTE') then
    raise exception 'Account deletion rate limit RPC permissions are not restricted to service_role';
  end if;
  if not public.consume_account_deletion_rate_limit(u9)
     or not public.consume_account_deletion_rate_limit(u9)
     or not public.consume_account_deletion_rate_limit(u9) then
    raise exception 'The first three account deletion attempts should be allowed';
  end if;
  if public.consume_account_deletion_rate_limit(u9) then
    raise exception 'The fourth account deletion attempt in the same hour should be rejected';
  end if;
  insert into public.account_deletion_locks(user_id) values (u9);
  if not public.consume_account_deletion_rate_limit(u9) then
    raise exception 'An account with an existing deletion lock must be able to retry';
  end if;
  delete from auth.users where id=u9;
  if exists(select 1 from public.account_deletion_rate_limits where user_id=u9) then
    raise exception 'Auth deletion did not cascade the account deletion rate-limit row';
  end if;


  -- Catalog-level security regression checks for privileged public RPCs.
  -- Every SECURITY DEFINER function in public must pin an empty search_path
  -- and must not inherit EXECUTE from PUBLIC, anon, or authenticated.
  if exists (
    select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and (
         not coalesce(p.proconfig, array[]::text[]) @> array['search_path=""']
         or exists (
           select 1
             from pg_catalog.aclexplode(
               coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
             ) acl
            where acl.grantee = 0
              and acl.privilege_type = 'EXECUTE'
         )
         or has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE')
       )
  ) then
    raise exception 'A public SECURITY DEFINER function has an unsafe search_path or untrusted EXECUTE grant';
  end if;

  -- Internal account deletion tables must not be readable or writable by
  -- browser roles, even if a future migration accidentally adds a broad grant.
  if has_table_privilege('anon', 'public.account_deletion_locks', 'SELECT')
     or has_table_privilege('authenticated', 'public.account_deletion_locks', 'SELECT')
     or has_table_privilege('anon', 'public.account_deletion_rate_limits', 'SELECT')
     or has_table_privilege('authenticated', 'public.account_deletion_rate_limits', 'SELECT')
     or has_table_privilege('anon', 'public.account_deletion_rate_limits', 'INSERT')
     or has_table_privilege('authenticated', 'public.account_deletion_rate_limits', 'INSERT')
  then
    raise exception 'Browser roles have direct access to internal account-deletion tables';
  end if;

  -- Privileged queue and account-deletion RPCs must remain service_role-only.
  if has_function_privilege('anon', 'public.block_writes_during_account_deletion()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.block_writes_during_account_deletion()', 'EXECUTE')
     or has_function_privilege('anon', 'public.defer_storage_cleanup_job(bigint,text,text,uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.defer_storage_cleanup_job(bigint,text,text,uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.consume_account_deletion_rate_limit(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.consume_account_deletion_rate_limit(uuid)', 'EXECUTE')
  then
    raise exception 'An internal RPC is executable by a browser role';
  end if;

end $$;


-- Exercise actual PostgreSQL RLS with SET ROLE and synthetic JWT claims.
-- anon must not be able to query the listing tables at all.
insert into public.service_requests(user_id,title,status)
values ('44444444-4444-4444-8444-444444444444','rls-isolation-fixture','approved');

set role anon;
do $rls_anon$
begin
  begin
    perform count(*) from public.service_requests;
    raise exception 'anon unexpectedly read service_requests';
  exception when insufficient_privilege then
    null;
  end;
end;
$rls_anon$;
reset role;

-- A signed-in non-admin has the table grant but RLS must hide all rows and
-- make UPDATE affect zero rows.
set role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',false);
do $rls_nonadmin$
declare visible_rows integer;
begin
  select count(*) into visible_rows from public.service_requests;
  if visible_rows <> 0 then
    raise exception 'Non-admin authenticated user saw % service_requests rows', visible_rows;
  end if;
end;
$rls_nonadmin$;
update public.service_requests
   set title='rls-nonadmin-modified'
 where title='rls-isolation-fixture';
reset role;

do $rls_nonadmin_verify$
begin
  if not exists (
    select 1 from public.service_requests
     where title='rls-isolation-fixture'
       and user_id='22222222-2222-4222-8222-222222222222'
  ) then
    raise exception 'Non-admin UPDATE changed a protected listing';
  end if;
end;
$rls_nonadmin_verify$;

-- The synthetic owner identity can read and update through the authenticated
-- role, matching the verified production is_admin() policy boundary.
set role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
do $rls_admin$
declare visible_rows integer;
begin
  select count(*) into visible_rows from public.service_requests
   where title='rls-isolation-fixture';
  if visible_rows <> 1 then
    raise exception 'Synthetic admin expected one fixture row, found %', visible_rows;
  end if;
end;
$rls_admin$;
update public.service_requests
   set title='rls-admin-modified'
 where title='rls-isolation-fixture';
reset role;

do $rls_admin_verify$
begin
  if not exists (
    select 1 from public.service_requests
     where title='rls-admin-modified'
       and user_id='22222222-2222-4222-8222-222222222222'
  ) then
    raise exception 'Admin UPDATE did not pass the intended RLS policy';
  end if;
end;
$rls_admin_verify$;

delete from public.service_requests where title='rls-admin-modified';
