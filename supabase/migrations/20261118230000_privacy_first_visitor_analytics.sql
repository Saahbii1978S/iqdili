-- Privacy-first visitor analytics for Ahla Tounsa.
-- Stores only a keyed digest of the request IP, section IDs, and referrer hostnames.
-- Raw IP addresses, full referrer URLs, query strings, form values, and geolocation are never stored.

create table if not exists private.site_page_events (
  id bigint generated always as identity primary key,
  visitor_id uuid not null,
  page_key text not null,
  referrer_host text,
  created_at timestamptz not null default now(),
  constraint site_page_events_page_key_check
    check (page_key in ('home','services','jobs','realty','market','good','guide','cv','ask','saved','account')),
  constraint site_page_events_referrer_host_check
    check (referrer_host is null or referrer_host ~ '^[a-z0-9.-]{1,253}$')
);

create index if not exists site_page_events_created_at_idx
  on private.site_page_events (created_at desc);
create index if not exists site_page_events_visitor_created_at_idx
  on private.site_page_events (visitor_id, created_at desc);

revoke all on table private.site_page_events from public, anon, authenticated;

create or replace function public.record_site_page_visit(
  p_page_key text,
  p_referrer_host text default null
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_headers json;
  v_forwarded text;
  v_ip text;
  v_salt bytea;
  v_hash text;
  v_visitor_id uuid;
  v_day date := (now() at time zone 'Africa/Tunis')::date;
  v_referrer_host text;
begin
  if auth.uid() is not null and public.is_admin() then
    return;
  end if;

  if p_page_key is null or p_page_key not in
    ('home','services','jobs','realty','market','good','guide','cv','ask','saved','account') then
    raise exception 'invalid page key' using errcode = '22023';
  end if;

  v_referrer_host := lower(btrim(coalesce(p_referrer_host, '')));
  if v_referrer_host = '' or v_referrer_host !~ '^[a-z0-9.-]{1,253}$' then
    v_referrer_host := null;
  end if;

  v_headers := nullif(current_setting('request.headers', true), '')::json;
  v_forwarded := coalesce(v_headers->>'x-forwarded-for', '');
  v_ip := btrim(split_part(v_forwarded, ',', 1));
  if v_ip = '' then
    raise exception 'Client address unavailable';
  end if;
  perform v_ip::inet;

  select secret into v_salt
  from private.site_visit_config
  where id = true;
  if v_salt is null then
    raise exception 'Visitor tracking configuration unavailable';
  end if;

  -- Keyed digest only: the original IP is not persisted.
  v_hash := encode(extensions.digest(convert_to(v_ip, 'UTF8') || v_salt, 'sha256'), 'hex');
  v_visitor_id := (
    substr(v_hash, 1, 8) || '-' ||
    substr(v_hash, 9, 4) || '-' ||
    substr(v_hash, 13, 4) || '-' ||
    substr(v_hash, 17, 4) || '-' ||
    substr(v_hash, 21, 12)
  )::uuid;

  insert into private.site_visitor_days(visitor_id, visit_day, first_seen, last_seen, visit_count)
  values (v_visitor_id, v_day, now(), now(), 1)
  on conflict (visitor_id, visit_day) do update
    set visit_count = private.site_visitor_days.visit_count +
      case when private.site_visitor_days.last_seen < now() - interval '30 minutes' then 1 else 0 end,
        last_seen = now();

  insert into private.site_page_events(visitor_id, page_key, referrer_host)
  values (v_visitor_id, p_page_key, nullif(v_referrer_host, ''));

  -- Enforce the stated 90-day event retention without a separate scheduler.
  delete from private.site_page_events
  where created_at < now() - interval '90 days';
end;
$function$;

revoke all on function public.record_site_page_visit(text, text) from public;
grant execute on function public.record_site_page_visit(text, text) to anon, authenticated;

create or replace function public.get_site_visitor_details()
returns table (
  visitor_label text,
  total_visits bigint,
  last_seen timestamptz,
  pages text[],
  sources text[]
)
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.admins a where a.user_id = auth.uid()
  ) then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return query
  with visit_totals as (
    select d.visitor_id,
           sum(d.visit_count)::bigint as total_visits,
           max(d.last_seen) as last_seen
    from private.site_visitor_days d
    where d.visit_day >= (now() at time zone 'Africa/Tunis')::date - 89
    group by d.visitor_id
  ),
  page_totals as (
    select e.visitor_id,
           coalesce(array_agg(distinct e.page_key order by e.page_key), array[]::text[]) as pages,
           coalesce(array_agg(distinct e.referrer_host order by e.referrer_host)
             filter (where e.referrer_host is not null), array[]::text[]) as sources
    from private.site_page_events e
    where e.created_at >= now() - interval '90 days'
    group by e.visitor_id
  )
  select
    'زائر-' || substr(v.visitor_id::text, 1, 8),
    v.total_visits,
    v.last_seen,
    coalesce(p.pages, array[]::text[]),
    coalesce(p.sources, array[]::text[])
  from visit_totals v
  left join page_totals p on p.visitor_id = v.visitor_id
  order by v.last_seen desc
  limit 200;
end;
$function$;

revoke all on function public.get_site_visitor_details() from public, anon;
grant execute on function public.get_site_visitor_details() to authenticated;
