-- Reconstructed idempotent migration record for version 20261119081823.
-- Production catalog inspection confirms RLS is enabled and direct client-role
-- privileges are absent on these private rate-limit, legacy analytics, and
-- administrative audit tables. Keep the migration aligned with that state.

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
