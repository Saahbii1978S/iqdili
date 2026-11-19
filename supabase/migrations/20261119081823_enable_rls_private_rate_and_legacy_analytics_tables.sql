-- Restore the migration record for the security hardening already applied
-- to production on 2026-11-19 (version 20261119081823).
-- This migration enables RLS and removes direct client-role table privileges
-- from private rate-limit / legacy analytics storage and audit-event tables.
-- It deliberately preserves postgres and service_role access.

do $migration$
declare
  v_table text;
  v_tables text[] := array[
    'private.ask_rate_limits',
    'private.pending_image_rate_limits',
    'private.site_visit_config',
    'private.site_visitor_days',
    'public.admin_notification_events',
    'public.admin_role_events',
    'public.admin_status_audit'
  ];
begin
  foreach v_table in array v_tables loop
    if to_regclass(v_table) is not null then
      execute format('alter table %s enable row level security', to_regclass(v_table));
      execute format(
        'revoke all privileges on table %s from public, anon, authenticated',
        to_regclass(v_table)
      );
    end if;
  end loop;
end
$migration$;
