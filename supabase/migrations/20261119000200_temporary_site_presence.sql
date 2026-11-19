-- Temporary anonymous presence counts for Ahla Tounsa.
-- A random per-tab UUID is used only as a short-lived presence token.
-- No IP, account identity, device fingerprint, referrer, or browsing history is stored.

create table if not exists private.active_site_presence (
  session_id uuid primary key,
  last_seen timestamptz not null default now()
);

create index if not exists active_site_presence_last_seen_idx
  on private.active_site_presence (last_seen);

alter table private.active_site_presence enable row level security;
revoke all on table private.active_site_presence from public, anon, authenticated;

create or replace function public.heartbeat_site_presence(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if p_session_id is null then
    raise exception 'session token required' using errcode = '22023';
  end if;

  -- Do not count authenticated administrators or the owner.
  if auth.uid() is not null and public.is_admin() then
    return;
  end if;

  delete from private.active_site_presence
  where last_seen < now() - interval '2 minutes';

  insert into private.active_site_presence (session_id, last_seen)
  values (p_session_id, now())
  on conflict (session_id)
  do update set last_seen = excluded.last_seen;
end;
$function$;

create or replace function public.get_active_site_presence_count()
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_count bigint;
begin
  if auth.uid() is null or not public.is_owner() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  delete from private.active_site_presence
  where last_seen < now() - interval '2 minutes';

  select count(*) into v_count
  from private.active_site_presence
  where last_seen >= now() - interval '2 minutes';

  return coalesce(v_count, 0);
end;
$function$;

revoke all on function public.heartbeat_site_presence(uuid) from public;
grant execute on function public.heartbeat_site_presence(uuid) to anon, authenticated;

revoke all on function public.get_active_site_presence_count() from public, anon;
grant execute on function public.get_active_site_presence_count() to authenticated;
