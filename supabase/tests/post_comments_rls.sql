\set ON_ERROR_STOP on

-- Isolated PostgreSQL harness: no Supabase project or production data is used.
create role anon nologin;
create role authenticated nologin;

create schema auth;
create table auth.users (id uuid primary key);
grant usage on schema auth to anon, authenticated;

create function auth.uid()
returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create function auth.jwt()
returns jsonb
language sql stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$;

grant execute on function auth.uid() to anon, authenticated;
grant execute on function auth.jwt() to anon, authenticated;

create table public.market_posts (id bigint primary key, status text not null);
create table public.service_requests (id bigint primary key, status text not null);
create table public.job_posts (id bigint primary key, status text not null);
create table public.real_estate_posts (id bigint primary key, status text not null);

insert into public.market_posts values (1, 'approved'), (2, 'approved'), (3, 'pending');
insert into public.service_requests values (1, 'approved'), (2, 'pending');
insert into public.job_posts values (1, 'approved'), (2, 'pending');
insert into public.real_estate_posts values (1, 'approved'), (2, 'pending');

create function public.is_admin()
returns boolean
language sql stable
as $$
  select coalesce((auth.jwt() ->> 'is_admin')::boolean, false);
$$;
grant execute on function public.is_admin() to authenticated;

insert into auth.users values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

\ir ../migrations/20261115144500_post_comments.sql

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';
set request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","is_anonymous":false}';

-- A signed-in, non-anonymous member can comment on each approved category.
insert into public.post_comments (post_table, post_id, user_id, body)
values
  ('market_posts', 1, auth.uid(), 'Market parent'),
  ('service_requests', 1, auth.uid(), 'Service comment'),
  ('job_posts', 1, auth.uid(), 'Job comment'),
  ('real_estate_posts', 1, auth.uid(), 'Real estate comment');

insert into public.post_comments (post_table, post_id, user_id, body)
values ('market_posts', 1, auth.uid(), 'Parent to test replies');

insert into public.post_comments (post_table, post_id, parent_id, user_id, body)
values (
  'market_posts',
  1,
  (select id from public.post_comments where body = 'Parent to test replies'),
  auth.uid(),
  'Valid one-level reply'
);

-- Pending posts and forged authorship must be rejected by RLS.
do $$
begin
  insert into public.post_comments (post_table, post_id, user_id, body)
  values ('market_posts', 3, auth.uid(), 'Should not be accepted');
  raise exception 'RLS accepted a comment on a pending post';
exception when insufficient_privilege then
  null;
end;
$$;

do $$
begin
  insert into public.post_comments (post_table, post_id, user_id, body)
  values ('market_posts', 1, '22222222-2222-4222-8222-222222222222', 'Forged author');
  raise exception 'RLS accepted forged authorship';
exception when insufficient_privilege then
  null;
end;
$$;

-- Anonymous Auth users must not be able to insert comments.
set request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","is_anonymous":true}';
do $$
begin
  insert into public.post_comments (post_table, post_id, user_id, body)
  values ('market_posts', 1, auth.uid(), 'Anonymous comment');
  raise exception 'RLS accepted an anonymous Auth user';
exception when insufficient_privilege then
  null;
end;
$$;
set request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","is_anonymous":false}';

-- Replies cannot cross posts or become nested replies.
do $$
begin
  insert into public.post_comments (post_table, post_id, parent_id, user_id, body)
  values ('market_posts', 2, (select id from public.post_comments where body = 'Parent to test replies'), auth.uid(), 'Cross-post reply');
  raise exception 'Trigger accepted a cross-post reply';
exception when raise_exception then
  if sqlerrm <> 'Reply must target a visible top-level comment on the same post' then
    raise;
  end if;
end;
$$;

do $$
begin
  insert into public.post_comments (post_table, post_id, parent_id, user_id, body)
  values ('market_posts', 1, (select id from public.post_comments where body = 'Valid one-level reply'), auth.uid(), 'Nested reply');
  raise exception 'Trigger accepted a nested reply';
exception when raise_exception then
  if sqlerrm <> 'Reply must target a visible top-level comment on the same post' then
    raise;
  end if;
end;
$$;

-- Owners can edit their own comments, but cannot transfer ownership.
update public.post_comments
set body = 'Edited parent'
where body = 'Parent to test replies';

do $$
begin
  update public.post_comments
  set user_id = '22222222-2222-4222-8222-222222222222'
  where body = 'Edited parent';
  raise exception 'RLS allowed a member to transfer comment ownership';
exception when insufficient_privilege then
  null;
end;
$$;

-- Moderators can hide a comment; its replies must then disappear from public reads.
set request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","is_anonymous":false,"is_admin":true}';
update public.post_comments set status = 'hidden' where body = 'Edited parent';
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claims;

set role anon;
do $$
begin
  if (select count(*) from public.post_comments where post_table = 'market_posts' and post_id = 1) <> 1 then
    raise exception 'Public read policy exposed a hidden parent or its reply';
  end if;
end;
$$;

do $$
begin
  insert into public.post_comments (post_table, post_id, user_id, body)
  values ('market_posts', 1, '11111111-1111-4111-8111-111111111111', 'Anonymous role insert');
  raise exception 'anon database role was able to insert a comment';
exception when insufficient_privilege then
  null;
end;
$$;

reset role;
select 'post_comments RLS regression tests passed' as result;
