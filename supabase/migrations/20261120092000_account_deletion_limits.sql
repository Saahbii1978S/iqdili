-- Bound account deletion work and rate-limit repeated deletion attempts.
-- Candidate migration only: apply to a disposable/staging project first.

create table if not exists public.account_deletion_rate_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null default pg_catalog.now(),
  attempts integer not null default 0 check (attempts >= 0)
);

alter table public.account_deletion_rate_limits enable row level security;
revoke all on table public.account_deletion_rate_limits from public, anon, authenticated;
grant all on table public.account_deletion_rate_limits to service_role;

-- Permit deletion only while the account has fewer than 10,000 listings
-- across all four supported public listing tables.
create or replace function public.account_post_count_within_limit(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $count$
  select p_user_id is not null
     and (
       select count(*)
       from (
         select 1 from public.service_requests where user_id = p_user_id
         union all
         select 1 from public.job_posts where user_id = p_user_id
         union all
         select 1 from public.real_estate_posts where user_id = p_user_id
         union all
         select 1 from public.market_posts where user_id = p_user_id
       ) account_posts
     ) < 10000;
$count$;

revoke all on function public.account_post_count_within_limit(uuid) from public, anon, authenticated;
grant execute on function public.account_post_count_within_limit(uuid) to service_role;

-- Allow at most three deletion attempts per account in a rolling one-hour
-- window. Once the listing transaction has created a deletion lock, retries
-- remain allowed so a transient Auth deletion failure cannot strand the user.
create or replace function public.consume_account_deletion_rate_limit(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $rate$
declare
  allowed boolean := false;
begin
  if p_user_id is null then
    return false;
  end if;

  if exists (
    select 1
      from public.account_deletion_locks
     where user_id = p_user_id
  ) then
    return true;
  end if;

  insert into public.account_deletion_rate_limits(user_id, window_started_at, attempts)
  values (p_user_id, pg_catalog.now(), 1)
  on conflict (user_id) do update
    set window_started_at = case
          when public.account_deletion_rate_limits.window_started_at
                 <= pg_catalog.now() - interval '1 hour'
            then pg_catalog.now()
          else public.account_deletion_rate_limits.window_started_at
        end,
        attempts = case
          when public.account_deletion_rate_limits.window_started_at
                 <= pg_catalog.now() - interval '1 hour'
            then 1
          else public.account_deletion_rate_limits.attempts + 1
        end
  where public.account_deletion_rate_limits.window_started_at
          <= pg_catalog.now() - interval '1 hour'
     or public.account_deletion_rate_limits.attempts < 3
  returning true into allowed;

  return coalesce(allowed, false);
end;
$rate$;

revoke all on function public.consume_account_deletion_rate_limit(uuid) from public, anon, authenticated;
grant execute on function public.consume_account_deletion_rate_limit(uuid) to service_role;
