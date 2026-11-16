-- Candidate-only safeguards for account deletion. Do not apply to production without explicit approval.

create table if not exists public.account_deletion_rate_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null,
  attempts integer not null check (attempts >= 1),
  updated_at timestamptz not null default pg_catalog.now()
);

alter table public.account_deletion_rate_limits enable row level security;
revoke all on table public.account_deletion_rate_limits from public, anon, authenticated;
grant all on table public.account_deletion_rate_limits to service_role;

-- The Edge Function supplies only the Auth user ID returned by the verified Auth endpoint.
-- An existing deletion lock is retryable and therefore bypasses the attempt counter.
create or replace function public.consume_account_deletion_rate_limit(p_user_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $rate_limit$
declare
  current_attempts integer;
begin
  if p_user_id is null then
    raise exception 'A verified user ID is required';
  end if;

  if exists (
    select 1 from public.account_deletion_locks l where l.user_id = p_user_id
  ) then
    return true;
  end if;

  insert into public.account_deletion_rate_limits(user_id, window_started_at, attempts, updated_at)
  values (p_user_id, pg_catalog.now(), 1, pg_catalog.now())
  on conflict (user_id) do update
    set window_started_at = case
          when public.account_deletion_rate_limits.window_started_at <= pg_catalog.now() - interval '1 hour'
            then pg_catalog.now()
          else public.account_deletion_rate_limits.window_started_at
        end,
        attempts = case
          when public.account_deletion_rate_limits.window_started_at <= pg_catalog.now() - interval '1 hour'
            then 1
          else public.account_deletion_rate_limits.attempts + 1
        end,
        updated_at = pg_catalog.now()
  returning attempts into current_attempts;

  return current_attempts <= 3;
end;
$rate_limit$;

revoke all on function public.consume_account_deletion_rate_limit(uuid) from public, anon, authenticated;
grant execute on function public.consume_account_deletion_rate_limit(uuid) to service_role;

-- Count all four listing categories together. 9,999 is permitted; 10,000+ is rejected.
create or replace function public.account_post_count_within_limit(p_user_id uuid)
returns boolean
language sql
security invoker
set search_path = ''
as $count_limit$
  select p_user_id is not null and (
    select count(*) < 10000
    from (
      select 1 from public.service_requests where user_id = p_user_id
      union all
      select 1 from public.job_posts where user_id = p_user_id
      union all
      select 1 from public.real_estate_posts where user_id = p_user_id
      union all
      select 1 from public.market_posts where user_id = p_user_id
    ) as account_posts
  );
$count_limit$;

revoke all on function public.account_post_count_within_limit(uuid) from public, anon, authenticated;
grant execute on function public.account_post_count_within_limit(uuid) to service_role;
