# AHLA TOUNSA — function, trigger, sequence and ACL verification (2026-11-16)

## Scope and safety
Read-only catalog inspection of production project `iqdili`. No row contents, Auth users, secret values, storage object data, or credentials were read. No production changes or deployments. This report is committed only to `integration/release-candidate-2026-11-15`.

## Application function security metadata
All 17 application functions inspected are owned by `postgres`. All are SECURITY DEFINER. Every function uses an empty `search_path`, except `public.rls_auto_enable()`, which uses `pg_catalog`.

Function execution ACLs observed:
- `admin_list_status_audit()`, `admin_list_users()`, `admin_set_moderator(uuid, boolean)`, `get_site_visitor_stats()`, `is_admin()`, `is_owner()`: EXECUTE for `authenticated` and owner `postgres`.
- `consume_ask_rate_limit(text)`, `consume_pending_image_rate_limit(text)`: EXECUTE for `service_role` and `postgres`.
- `public_job_posts()`, `public_market_posts()`, `public_real_estate_posts()`, `public_service_requests()`: EXECUTE for `anon`, `authenticated`, and `postgres`.
- `record_site_visit()`: EXECUTE for `anon`, `authenticated`, and `postgres`.
- `record_site_visit(uuid)`: EXECUTE for `postgres` only.
- Trigger-only `log_admin_status_change()` and `private.enforce_public_post_rate_limit()`, plus event-trigger `rls_auto_enable()`: EXECUTE for `postgres` only.

Important function behavior confirmed from exact function definitions:
- Public listing RPCs filter to `status = 'approved'`; they return phone only when `contact_public = true`.
- The four public post RPCs expose only their intended public listing columns.
- `private.enforce_public_post_rate_limit()` validates phone digits (8–15), forces every new post to `pending`, takes an advisory transaction lock keyed by normalized phone, and caps combined submissions at five per phone per rolling hour across the four modern post tables.
- `consume_ask_rate_limit` validates a 64-character lowercase hexadecimal fingerprint and enforces 15 requests/hour.
- `consume_pending_image_rate_limit` validates the same fingerprint format and enforces 10 requests/hour.
- `record_site_visit()` obtains the forwarded client IP from request headers, validates it as an IP, reads the private salt at runtime, stores only a keyed SHA-256-derived UUID, and tracks daily visits. The salt value was not queried.
- The legacy overload `record_site_visit(uuid)` is postgres-only and accepts a supplied visitor UUID; it must not be made client-executable.
- Owner-only functions check `is_owner()`; `admin_set_moderator` protects the owner role and logs moderator grants/revocations.
- `admin_list_status_audit` limits output to 100 records.

## Application triggers
All eight application triggers are enabled:
- On each of `job_posts`, `market_posts`, `real_estate_posts`, and `service_requests`:
  - `trg_public_post_rate_limit`: BEFORE INSERT, invokes `private.enforce_public_post_rate_limit()`.
  - `audit_<table>_status`: AFTER UPDATE OF status, invokes `public.log_admin_status_change()`.
- Supabase-managed triggers exist on `storage.buckets` and `storage.objects`; they are managed by Supabase Storage and must not be recreated as application triggers in the local baseline.

## Application event trigger
- `ensure_rls` is enabled for `ddl_command_end`, tags `CREATE TABLE`, `CREATE TABLE AS`, and `SELECT INTO`; invokes `public.rls_auto_enable()`.
- Exact function behavior was verified: it reads `pg_event_trigger_ddl_commands()`, filters to table/partitioned-table creation commands in schema `public`, and enables RLS on the new object. It catches errors and writes a server log rather than aborting the DDL. It is SECURITY DEFINER with `search_path = pg_catalog` and EXECUTE restricted to `postgres`.
- Other observed event triggers belong to Supabase/extension-managed schemas and must not be copied into app migrations.

## Sequences
Eleven public bigint sequences were verified. Each is owned by `postgres`, starts at 1, increments by 1, has minimum 1, maximum signed bigint, cache 1, and does not cycle. Each sequence is attached to the matching table column:
- `admin_role_events_id_seq` → `admin_role_events.id`
- `admin_status_audit_id_seq` → `admin_status_audit.id`
- `job_posts_id_seq` → `job_posts.id`
- `jobs_id_seq` → `jobs.id`
- `market_id_seq` → `market.id`
- `market_posts_id_seq` → `market_posts.id`
- `properties_id_seq` → `properties.id`
- `real_estate_posts_id_seq` → `real_estate_posts.id`
- `realty_id_seq` → `realty.id`
- `service_requests_id_seq` → `service_requests.id`
- `services_id_seq` → `services.id`

The sequence-to-column attachment was verified through catalog dependencies and `pg_get_serial_sequence`. The identity-versus-serial distinction remains important when recreating table DDL.

## Table and column ACL observations
ACLs are object-specific and must not be replaced with blanket grants:
- Private tables are owned by `postgres`; the only explicit table ACL entry returned was the owner.
- Modern listing tables grant `authenticated` SELECT and `service_role` the required server-side privileges; anon has selected column-level SELECT grants only on public-safe listing columns.
- The four modern listing tables have anon column-level SELECT grants on public-safe fields, deliberately excluding private phone/contact fields and other internal fields.
- `admin_notification_events` has service_role privileges only beyond owner.
- `admins` has service_role privileges only beyond owner.
- `staff_roles`, `admin_role_events`, and `admin_status_audit` have narrow, object-specific ACLs; do not infer broad table access from function EXECUTE grants.
- Legacy table and view ACLs differ by object. Legacy public views grant read access, while legacy base tables are not uniformly public.
- The public schema grants USAGE to client roles; private schema grants only to its owner. Storage schema ACLs are Supabase-managed and must not be copied wholesale.
- Explicit column-level ACLs were observed on modern listing tables for anon. Reconstruct them separately from table-level ACLs.

## Remaining work before local baseline
The catalog data is now substantially more complete, but do not call the local database a faithful restore yet. Remaining items include:
1. Capture the full exact table ACL and column ACL map in machine-readable form and compare it against the intended local role model.
2. Capture default ACLs and all grants for sequences, functions, schemas, views, and storage objects.
3. Capture exact extension dependencies and any missing extension configuration.
4. Capture all Storage bucket metadata and every Storage policy; do not read or export Storage objects.
5. Capture scheduler job definition without changing or executing it.
6. Build the local-only baseline, apply it only to local Supabase, and compare object-by-object.
7. Run synthetic-only Auth, PostgREST, RLS, Storage, and Edge Function integration tests.

## Explicit exclusions
No production rows, user records, password hashes, secret values, private salt value, storage object names, or storage object contents were queried. No production DDL/DML or settings were changed.


## Default privileges and Storage bucket metadata
A read-only query of `pg_default_acl` found:
- For objects created by `postgres` in schema `public`, default privileges exist for tables (`r`), sequences (`S`), and functions (`f`). The table default ACL grants broad table privileges to `anon`, `authenticated`, and `service_role`; function EXECUTE defaults are also granted to those roles. This is an important security-sensitive default for future objects. The existing `ensure_rls` event trigger enables RLS on new public tables, but RLS with no policies denies ordinary client access; do not assume default grants alone imply accessible rows. Any change to default ACLs requires a separate reviewed migration and explicit approval.
- Default ACLs also exist for objects owned by `supabase_admin` in `public`, and for `postgres` in `storage`. These are platform-managed and must not be copied wholesale into application migrations.
- No default ACL row was returned for schema `private`.

Storage bucket metadata (no objects read):
- `listing-images`: public; 3 MiB maximum; JPEG, PNG, WebP.
- `market-images`: public; 3 MiB maximum; JPEG, PNG, WebP.
- `pending-images`: private; 3 MiB maximum; JPEG, PNG, WebP.
- The only application Storage policies returned by the catalog query are public SELECT on `storage.objects` for `market-images` and `listing-images`. No public-read policy exists for `pending-images`.


## Storage policy completeness, extensions, and scheduler metadata
- A complete read-only query of `pg_policies` for schema `storage` returned exactly two policies:
  - `Market images public read`: permissive SELECT for role `public`, restricted to bucket `market-images`.
  - `Public read listing images`: permissive SELECT for role `public`, restricted to bucket `listing-images`.
- No Storage INSERT, UPDATE, or DELETE policies were returned. No public read policy exists for `pending-images`.
- Installed extensions and versions observed:
  - `pg_cron` 1.6.4 (`pg_catalog`)
  - `pg_net` 0.20.4 (`extensions`)
  - `pg_stat_statements` 1.11 (`extensions`)
  - `pgcrypto` 1.3 (`extensions`)
  - `plpgsql` 1.0 (`pg_catalog`)
  - `supabase_vault` 0.3.1 (`vault`)
  - `uuid-ossp` 1.1 (`extensions`)
- The database timezone setting is `UTC`. The active `expire-posts-daily` job is scheduled as `17 3 * * *`. Its command/body was intentionally not read, and it was not run or modified. Do not infer local Tunisia execution time from the schedule alone without checking the scheduler's timezone semantics.
- The extension inventory is evidence for compatibility planning only. Supabase-managed extensions/schemas and platform event triggers must be provisioned by the local Supabase stack where supported, not recreated as ordinary app DDL.

## Default ACL caution
The public-schema default ACL for objects created by `postgres` grants broad table privileges and function EXECUTE to client roles by default, and grants sequence privileges according to its recorded ACL. This means every new table/function created under that owner must be reviewed immediately:
- New public tables must have RLS enabled and deliberate policies; the `ensure_rls` event trigger enables RLS but does not create policies.
- New SECURITY DEFINER functions must have explicit, least-privilege EXECUTE grants/revokes; do not rely on defaults.
- Do not silently change the production default ACL. A future hardening migration would require impact analysis and explicit user approval.
