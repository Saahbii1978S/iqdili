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
  -- Preserve replies by preventing deletion of a parent while replies still reference it.
  parent_id bigint references public.post_comments(id),
  -- Keep the comment and its thread position when its author account is deleted.
  user_id uuid references auth.users(id) on delete set null,
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
security definer
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

-- Owners may edit their own text. Only administrators may change visibility,
-- and moderators cannot rewrite another member's comment while moderating it.
create or replace function ahla_internal.prevent_post_comment_identity_change()
returns trigger
language plpgsql
set search_path = ''
as $comment_guard$
begin
  if new.id is distinct from old.id
     or (
       new.user_id is distinct from old.user_id
       and not (old.user_id is not null and new.user_id is null and pg_trigger_depth() > 1)
     )
     or new.post_table is distinct from old.post_table
     or new.post_id is distinct from old.post_id
     or new.parent_id is distinct from old.parent_id
     or new.created_at is distinct from old.created_at then
    raise exception 'Comment id, ownership, target, parent and creation time are immutable';
  end if;

  if new.status is distinct from old.status and not public.is_admin() then
    raise exception 'Only administrators may change comment visibility';
  end if;

  -- Avoid calling is_admin() for account-deletion FK updates: auth service roles
  -- intentionally do not have EXECUTE on that function, and the body is unchanged.
  if new.body is distinct from old.body
     and old.user_id is distinct from auth.uid() then
    if public.is_admin() then
      raise exception 'Administrators may moderate visibility but cannot rewrite another member comment';
    end if;
  end if;

  return new;
end;
$comment_guard$;

drop trigger if exists prevent_post_comment_identity_change on public.post_comments;
create trigger prevent_post_comment_identity_change
before update on public.post_comments
for each row execute function ahla_internal.prevent_post_comment_identity_change();

-- The database owns the update timestamp; clients cannot forge it.
create or replace function ahla_internal.set_post_comment_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $set_updated_at$
begin
  new.updated_at = now();
  return new;
end;
$set_updated_at$;

drop trigger if exists set_post_comment_updated_at on public.post_comments;
create trigger set_post_comment_updated_at
before update on public.post_comments
for each row execute function ahla_internal.set_post_comment_updated_at();

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

-- Moderators need SELECT visibility on hidden rows before PostgreSQL permits UPDATE.
drop policy if exists "Moderators can read comments for moderation" on public.post_comments;
create policy "Moderators can read comments for moderation"
on public.post_comments for select
to authenticated
using (public.is_admin());

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
create policy "Moderators can manage comment visibility"
on public.post_comments for update
to authenticated
using (public.is_admin())
with check (
  public.is_admin()
  and status in ('published', 'hidden')
  and char_length(btrim(body)) between 1 and 1000
);

drop policy if exists "Members and moderators can delete comments" on public.post_comments;
drop policy if exists "Members can delete their own comments" on public.post_comments;
create policy "Members can delete their own comments"
on public.post_comments for delete
to authenticated
using (user_id = (select auth.uid()));

grant select on public.post_comments to anon, authenticated;
grant insert, update, delete on public.post_comments to authenticated;


-- Expose a privacy-safe read surface: never return the author's UUID to clients.
-- The view applies the same public-post and visible-parent constraints as the table RLS.
create or replace view public.post_comments_public
with (security_barrier = true)
as
select
  c.id, c.post_table, c.post_id, c.parent_id, c.body, c.created_at,
  (c.user_id = (select auth.uid())) as is_mine
from public.post_comments c
where c.status = 'published'
  and ahla_internal.comment_target_is_public(c.post_table, c.post_id)
  and (
    c.parent_id is null
    or ahla_internal.comment_parent_is_public(c.parent_id, c.post_table, c.post_id)
  );

revoke all on public.post_comments from anon, authenticated;
grant select on public.post_comments_public to anon, authenticated;

-- Moderation gets a separate privileged read surface, including hidden rows.
create or replace view public.post_comments_moderation
with (security_barrier = true)
as
select c.*
from public.post_comments c
where public.is_admin();
grant select on public.post_comments_moderation to authenticated;

grant insert, update, delete on public.post_comments to authenticated;

create or replace function public.update_own_post_comment(p_comment_id bigint, p_body text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare affected integer;
begin
  if (select auth.uid()) is null
     or char_length(btrim(coalesce(p_body, ''))) not between 1 and 1000 then
    return false;
  end if;
  update public.post_comments
     set body = btrim(p_body)
   where id = p_comment_id
     and user_id = (select auth.uid())
     and status = 'published';
  get diagnostics affected = row_count;
  return affected = 1;
end;
$$;
revoke all on function public.update_own_post_comment(bigint, text) from public, anon;
grant execute on function public.update_own_post_comment(bigint, text) to authenticated;

create or replace function public.delete_own_post_comment(p_comment_id bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare affected integer;
begin
  if (select auth.uid()) is null then return false; end if;
  delete from public.post_comments
   where id = p_comment_id
     and user_id = (select auth.uid());
  get diagnostics affected = row_count;
  return affected = 1;
end;
$$;
revoke all on function public.delete_own_post_comment(bigint) from public, anon;
grant execute on function public.delete_own_post_comment(bigint) to authenticated;

create or replace function public.set_post_comment_visibility(p_comment_id bigint, p_status text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $
declare affected integer;
begin
  if (select auth.uid()) is null
     or not public.is_admin()
     or p_status not in ('published', 'hidden') then
    return false;
  end if;
  update public.post_comments
     set status = p_status
   where id = p_comment_id;
  get diagnostics affected = row_count;
  return affected = 1;
end;
$;
revoke all on function public.set_post_comment_visibility(bigint, text) from public, anon;
grant execute on function public.set_post_comment_visibility(bigint, text) to authenticated;
