-- Public comments and one-level replies for approved marketplace posts.
-- Apply only after reviewing this migration in a non-production Supabase branch.

create schema if not exists ahla_internal;
revoke all on schema ahla_internal from public;
grant usage on schema ahla_internal to anon, authenticated;

create table if not exists public.post_comments (
  id bigint generated always as identity primary key,
  post_table text not null check (post_table in (
    'market_posts',
    'service_requests',
    'job_posts',
    'real_estate_posts'
  )),
  post_id bigint not null,
  parent_id bigint references public.post_comments(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  status text not null default 'published' check (status in ('published', 'hidden')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists post_comments_post_idx
  on public.post_comments (post_table, post_id, created_at);
create index if not exists post_comments_parent_idx
  on public.post_comments (parent_id);
create index if not exists post_comments_user_idx
  on public.post_comments (user_id, created_at desc);

alter table public.post_comments enable row level security;

create or replace function ahla_internal.comment_target_is_public(p_post_table text, p_post_id bigint)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_post_table = 'market_posts' then
    return exists (select 1 from public.market_posts where id = p_post_id and status = 'approved');
  elsif p_post_table = 'service_requests' then
    return exists (select 1 from public.service_requests where id = p_post_id and status = 'approved');
  elsif p_post_table = 'job_posts' then
    return exists (select 1 from public.job_posts where id = p_post_id and status = 'approved');
  elsif p_post_table = 'real_estate_posts' then
    return exists (select 1 from public.real_estate_posts where id = p_post_id and status = 'approved');
  end if;
  return false;
end;
$$;

revoke all on function ahla_internal.comment_target_is_public(text, bigint) from public;
grant execute on function ahla_internal.comment_target_is_public(text, bigint) to anon, authenticated;

create or replace function ahla_internal.comment_parent_is_public(
  p_parent_id bigint,
  p_post_table text,
  p_post_id bigint
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.post_comments parent
    where parent.id = p_parent_id
      and parent.post_table = p_post_table
      and parent.post_id = p_post_id
      and parent.parent_id is null
      and parent.status = 'published'
      and ahla_internal.comment_target_is_public(parent.post_table, parent.post_id)
  );
$$;

revoke all on function ahla_internal.comment_parent_is_public(bigint, text, bigint) from public;
grant execute on function ahla_internal.comment_parent_is_public(bigint, text, bigint) to anon, authenticated;

create or replace function ahla_internal.validate_post_comment_parent()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  parent_post_table text;
  parent_post_id bigint;
  parent_parent_id bigint;
begin
  if new.parent_id is null then
    return new;
  end if;

  select post_table, post_id, parent_id
    into parent_post_table, parent_post_id, parent_parent_id
  from public.post_comments
  where id = new.parent_id and status = 'published';

  if not found
     or parent_post_table is distinct from new.post_table
     or parent_post_id is distinct from new.post_id
     or parent_parent_id is not null then
    raise exception 'Reply must target a visible top-level comment on the same post';
  end if;

  return new;
end;
$$;

drop trigger if exists validate_post_comment_parent on public.post_comments;
create trigger validate_post_comment_parent
before insert or update of post_table, post_id, parent_id
on public.post_comments
for each row execute function ahla_internal.validate_post_comment_parent();

drop policy if exists "Public can read published post comments" on public.post_comments;
create policy "Public can read published post comments"
on public.post_comments for select
to anon, authenticated
using (
  status = 'published'
  and ahla_internal.comment_target_is_public(post_table, post_id)
  and (
    parent_id is null
    or ahla_internal.comment_parent_is_public(parent_id, post_table, post_id)
  )
);

drop policy if exists "Signed-in members can comment on approved posts" on public.post_comments;
create policy "Signed-in members can comment on approved posts"
on public.post_comments for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, true) = false
  and status = 'published'
  and char_length(btrim(body)) between 1 and 1000
  and ahla_internal.comment_target_is_public(post_table, post_id)
);

drop policy if exists "Members can edit their own comments" on public.post_comments;
drop policy if exists "Members and moderators can edit comments" on public.post_comments;
create policy "Members can edit their own comments"
on public.post_comments for update
to authenticated
using (user_id = (select auth.uid()) and status = 'published')
with check (
  user_id = (select auth.uid())
  and status = 'published'
  and ahla_internal.comment_target_is_public(post_table, post_id)
  and char_length(btrim(body)) between 1 and 1000
);

drop policy if exists "Moderators can manage comment visibility" on public.post_comments;

drop policy if exists "Members and moderators can delete comments" on public.post_comments;
create policy "Members and moderators can delete comments"
on public.post_comments for delete
to authenticated
using (
  user_id = (select auth.uid())
  or public.is_admin()
);

drop policy if exists "Moderators can manage comment visibility" on public.post_comments;

grant select on public.post_comments to anon, authenticated;
grant insert, update, delete on public.post_comments to authenticated;
