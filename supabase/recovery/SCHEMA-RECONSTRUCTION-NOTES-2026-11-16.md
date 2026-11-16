# Ahla Tounsa — read-only schema reconstruction notes (2026-11-16)

## Scope and safety
- Source: read-only Supabase catalog inspection of project `djzapiwxxuligpdbskfm` (project name `iqdili`).
- No table row contents, credentials, API keys, secrets, storage object contents, or user records were exported.
- No production DDL, DML, migration, Auth operation, Storage operation, setting change, or deployment was performed.
- This is a reconstruction aid, **not** a complete `pg_dump` and not yet a restorable database snapshot.
- All work in this repository is confined to `integration/release-candidate-2026-11-15`; do not merge or deploy without explicit approval.

## Migration ledger observed
- `20261102161723 allow_public_service_submissions`
- `20261102161831 publish_services_without_phone`
- `20261104174400 protect_legacy_contact_tables`
- `20261105130220 lock_down_unused_legacy_listing_tables`
- `20261105142326 add_opt_in_public_contact_for_listings`
- `20261105175224 market_product_images`
- `20261105180017 add_images_to_all_listing_sections`
- `20261106194948 require_turnstile_for_public_posts`
- `20261107205238 add_ask_iqdili_hourly_rate_limit`
- `20261107205310 cleanup_old_ask_rate_limit_entries`
- `20261107205428 create_private_pending_images_bucket`
- `20261107210011 add_pending_image_upload_rate_limit`
- `20261107210508 restrict_public_listing_image_uploads`
- `20261107214706 revoke_excess_admins_table_privileges`
- `20261107222507 add_listing_expiry_and_cleanup_scheduler`
- `20261107222948 add_optional_member_ownership`
- `20261107223417 grant_admin_service_role_delete_posts`
- `20261108084317 add_owner_moderator_roles_and_audit`
- `20261108084428 limit_moderator_updates_to_post_status`
- `20261108084454 add_owner_review_audit_reader`
- `20261108084530 route_all_status_changes_through_authorized_edge_function`
- `20261108153947 add_admin_audit_foreign_key_indexes`
- `20261108172215 revoke_unneeded_table_admin_privileges`
- `20261108172408 secure_site_visit_identity_from_request_ip`
- `20261108172416 disable_legacy_client_supplied_visitor_ids`
- `20261114175919 admin_notification_events`
- `20261114194958 raise_ask_rate_limit_to_15_per_hour`
- `20261114202111 respect_service_contact_privacy`

## Tables and columns observed

### Public
- `service_requests`: id bigint identity PK; title text; description text nullable; city text default 'صفاقس'; phone text nullable; created_at timestamptz default now(); status text default 'pending'; contact_public boolean default false; image_urls text[] default '{}'; expires_at timestamptz nullable; user_id uuid nullable FK auth.users(id).
- `job_posts`: id bigint identity PK; title text; description text nullable; city text default 'صفاقس'; phone text nullable; created_at timestamptz default now(); status text default 'pending'; job_type text nullable; work_nature text nullable; contact_public boolean default false; image_urls text[] default '{}'; expires_at timestamptz nullable; user_id uuid nullable FK auth.users(id).
- `real_estate_posts`: id bigint identity PK; title text; property_type text nullable; listing_type text nullable; description text nullable; city text default 'صفاقس'; phone text nullable; created_at timestamptz default now(); status text default 'pending'; price numeric nullable; size numeric nullable; rooms integer nullable; contact_public boolean default false; image_urls text[] default '{}'; expires_at timestamptz nullable; user_id uuid nullable FK auth.users(id).
- `market_posts`: id bigint identity (BY DEFAULT) PK; created_at timestamptz default now(); title text; description text nullable; category text nullable; price numeric nullable; city text nullable; phone text nullable; listing_type text nullable; status text default 'pending'; contact_public boolean default false; image_urls text[] default '{}'; expires_at timestamptz nullable; user_id uuid nullable FK auth.users(id).
- `admins`: user_id uuid PK/FK auth.users(id).
- `services`: id bigint sequence PK; created_at timestamptz default now(); service_type, details, region, suitable_time, phone text nullable.
- `jobs`: id bigint sequence PK; created_at timestamptz default now(); ad_type, job_title, region, job_type, details_salary, contact_info text nullable.
- `properties`: id bigint sequence PK; created_at timestamptz default now(); process_type, property_type, region, description, contact_info text nullable; price, area numeric nullable; rooms_count integer nullable.
- `market`: id bigint sequence PK; created_at timestamptz default now(); ad_type, category, product_name, region, description, contact_phone text nullable; price numeric nullable.
- `realty`: id bigint identity (BY DEFAULT) PK; created_at timestamptz default now(); process_type, property_type, region, description, contact_info text nullable; price numeric default 0; area numeric default 0; rooms_count integer default 0.
- `staff_roles`: user_id uuid PK/FK auth.users(id); role text default 'moderator' with CHECK role='moderator'; granted_by uuid nullable FK auth.users(id); granted_at timestamptz default now().
- `admin_role_events`: id bigint identity PK; actor_id uuid nullable FK auth.users(id); target_user_id uuid nullable FK auth.users(id); action text CHECK action in ('granted','revoked'); created_at timestamptz default now().
- `admin_status_audit`: id bigint identity PK; table_name text; record_id text; old_status/new_status text nullable; actor_id uuid nullable FK auth.users(id); changed_at timestamptz default now().
- `admin_notification_events`: user_id uuid; event_type text; created_at timestamptz default now(); composite PK(user_id,event_type).

### Private
- `ask_rate_limits`: fingerprint text PK with 64-char lowercase hex CHECK; window_started_at timestamptz; request_count integer default 0 CHECK >=0; updated_at timestamptz default now().
- `pending_image_rate_limits`: fingerprint text PK with 64-char lowercase hex CHECK; window_started_at timestamptz default now(); request_count integer default 0 CHECK >=0; updated_at timestamptz default now().
- `site_visitor_days`: visitor_id uuid + visit_day date composite PK; visit_day defaults to Africa/Tunis current date; first_seen/last_seen timestamptz default now(); visit_count integer default 1 CHECK >0.
- `site_visit_config`: id boolean PK default true CHECK id=true; secret bytea. Secret value was not read.

## Views observed
- `approved_market_posts`: approved rows from market_posts, public listing fields only.
- `jobs_public`: selected public fields from jobs.
- `market_public`: selected public fields from market.
- `realty_public`: selected public fields from realty.
- `services_public`: selected public fields from services.

## RLS and policy observations
- RLS is enabled on all 14 public tables observed.
- RLS is disabled on the four private tables listed above. This needs careful privilege and SECURITY DEFINER review; **do not automatically enable RLS**, because the private functions currently write to these tables and blanket enabling without policies may break server-side flows.
- Observed policies: authenticated admins may SELECT and UPDATE job_posts, market_posts, real_estate_posts, service_requests through `is_admin()`; public SELECT policies exist on storage.objects for buckets `market-images` and `listing-images`.
- A separate earlier catalog check found no direct grants to anon/authenticated/PUBLIC/service_role on the private tables, and no USAGE/CREATE on schema private for those roles. This reduces direct exposure but does not replace a full review of owners, default privileges, SECURITY DEFINER execution grants, and exposed-schema configuration.

## Functions and triggers observed
- Public functions include: `admin_list_status_audit`, `admin_list_users`, `admin_set_moderator`, `consume_ask_rate_limit`, `consume_pending_image_rate_limit`, `get_site_visitor_stats`, `is_admin`, `is_owner`, `log_admin_status_change`, `public_job_posts`, `public_market_posts`, `public_real_estate_posts`, `public_service_requests`, `record_site_visit()`, `record_site_visit(uuid)`, and event-trigger function `rls_auto_enable`.
- Private function observed: `enforce_public_post_rate_limit()`.
- Important behavior captured: public post trigger forces new status to pending and enforces a per-phone hourly cap across the four post tables; status-change audit triggers run on status updates; visitor tracking hashes IP with a private salt; admin-only SECURITY DEFINER functions verify owner/admin identity.
- Non-internal triggers include four status-audit triggers, four public-post rate-limit triggers, and Supabase-managed Storage triggers. Storage-managed trigger definitions are recorded only as catalog metadata, not reconstructed as app migrations.

## Indexes and extensions
- Catalog inspection found primary-key indexes plus indexes for expiry cleanup, optional ownership, admin audit/role lookup, rate-limit cleanup, and visitor last-seen queries.
- Relevant installed extensions observed include `pgcrypto`, `uuid-ossp`, `pg_stat_statements`, `pg_net`, `pg_cron`, `pg_graphql`, and `plpgsql`. Supabase-managed extension inventory contains many additional available (not installed) extensions; do not recreate all available extensions.

## Known gaps before a faithful local restore
1. Obtain complete schema-only dump through an approved export path, or reconstruct all DDL in dependency order from full catalog definitions.
2. Capture exact column-level grants, schema grants, default privileges, function EXECUTE grants, view ownership/security options, sequences, event triggers, publication membership, storage buckets/policies, Auth configuration, and scheduled jobs.
3. Recreate only necessary extensions available in the local Supabase image.
4. Apply schema to local environment and compare object-by-object; never use production data.
5. Run synthetic-only Auth/PostgREST/Storage integration tests after the local schema is complete.

## Explicit exclusions
- No production rows or secrets.
- No private salt value.
- No storage object names or contents.
- No production changes or deployments.


## Follow-up privilege verification (read-only)
- Direct role checks confirm `anon`, `authenticated`, and `service_role` have neither `USAGE` nor `CREATE` on schema `private`.
- Those three roles also lack direct `SELECT`/`INSERT` on `private.ask_rate_limits` and `SELECT` on `private.site_visit_config`; the `postgres` owner has these privileges.
- Therefore the Supabase table-list advisory about disabled RLS is a warning that must be tracked, but its blanket statement that these tables are directly exposed through the client roles is not supported by the current direct privilege checks. Do not auto-enable RLS: the SECURITY DEFINER functions are designed to access these private tables, and any policy/privilege change requires a separate security design and explicit approval.
- The full grant inventory also includes Supabase-managed `storage` relations and is not treated as application DDL.


## Additional catalog verification (read-only, 2026-11-16)
- Exact view SQL was captured for the five public views. They are simple filtered/projection views; `approved_market_posts` filters `market_posts` to `status = 'approved'`. The other four expose selected columns from the legacy `services`, `jobs`, `market`, and `realty` tables. No materialized views were found in `public` or `private`.
- Eleven public sequences were found, all owned by `postgres`: the sequence objects for `admin_role_events`, `admin_status_audit`, `service_requests`, `job_posts`, `real_estate_posts`, `market_posts`, `jobs`, `services`, `properties`, `market`, and `realty`.
- Storage bucket metadata (no objects queried): `market-images` and `listing-images` are public; `pending-images` is private. Each has a 3 MiB upload limit and permits JPEG, PNG, and WebP.
- The active scheduled job inventory contains one job: `expire-posts-daily`, scheduled at `17 3 * * *` (03:17 daily, database scheduler timezone not independently established). The command/body was deliberately not read.
- No publication table memberships were found.
- Schema ACL inspection confirms `anon`, `authenticated`, and `service_role` have USAGE (but not CREATE) on `public`; the same roles have USAGE (but not CREATE) on `storage`. They have neither USAGE nor CREATE on `private`. This is consistent with the earlier direct private-table privilege checks.
- Default-privilege catalog entries exist for multiple Supabase-managed schemas and for both `supabase_admin` and `postgres` owners in `public`. The postgres-owned public defaults are restrictive for anon/authenticated/service_role (only destructive/maintenance-style privileges are present in the ACL representation); the Supabase-managed defaults are broader. These mixed owner-specific defaults must be recreated deliberately, not copied wholesale into an app bootstrap.
- A full column-grant query also returned extensive Supabase-managed Storage metadata. It was not copied into this application reconstruction note; a complete faithful restore still requires an approved schema-only dump or a carefully scoped object-by-object DDL reconstruction.

## Reconstruction decision
The catalog work has improved the inventory but **does not yet justify generating or applying a supposedly faithful full migration**. In particular, the complete function definitions and EXECUTE grants, all table/column ACLs, trigger and event-trigger definitions, exact sequence ownership/default links, and Supabase-managed Auth/Storage internals still need controlled treatment. Keep the local Supabase smoke-test workflow as infrastructure verification only; do not run synthetic integration tests against an incomplete schema.


## Function, trigger, event-trigger and identity detail (read-only, 2026-11-16)
### Application functions and EXECUTE ACL
- All 17 application functions inventoried in `public` and `private` are owned by `postgres`; the application SECURITY DEFINER functions use an empty `search_path` (the RLS event-trigger function uses `pg_catalog`). Function ACLs were read from `pg_proc.proacl`, not inferred from table grants.
- Owner-only functions `admin_list_users`, `admin_list_status_audit`, and `admin_set_moderator` have EXECUTE for `authenticated` and verify `public.is_owner()` internally. `get_site_visitor_stats` also checks the authenticated owner identity before returning aggregates.
- Public listing functions `public_service_requests`, `public_job_posts`, `public_real_estate_posts`, and `public_market_posts` have EXECUTE for `anon` and `authenticated`; each filters to approved posts. Each returns phone only when `contact_public` is true. The other public fields are explicitly projected.
- `consume_ask_rate_limit` and `consume_pending_image_rate_limit` have EXECUTE for `service_role` (and postgres), validate a 64-character lowercase hex fingerprint, and enforce 15/hour and 10/hour respectively, with stale-row cleanup.
- The no-argument `record_site_visit()` is executable by anon/authenticated and derives the visitor key from the request's forwarded IP plus a private salt, storing only a keyed digest-derived UUID. The overload `record_site_visit(uuid)` is postgres-only in its ACL. `is_admin()` and `is_owner()` are authenticated-executable identity predicates. Trigger-only functions `log_admin_status_change()` and `private.enforce_public_post_rate_limit()` are postgres-only. `rls_auto_enable()` is postgres-only.
- `admin_list_users()` returns user email and account timestamps, but its body explicitly requires owner status. `admin_list_status_audit()` similarly checks owner status and caps output at 100 rows.

### Application triggers
- Eight non-internal application triggers were captured; all are enabled:
  - Four AFTER UPDATE OF status audit triggers on `service_requests`, `job_posts`, `real_estate_posts`, and `market_posts`, invoking `public.log_admin_status_change()`.
  - Four BEFORE INSERT rate-limit triggers on those same tables, invoking `private.enforce_public_post_rate_limit()`.
- The private insert trigger validates phone digit length (8–15), forcibly resets new status to `pending`, obtains a transaction advisory lock keyed by normalized phone, and enforces a maximum of five combined posts per phone in a rolling hour across the four tables.
- The status audit trigger records a change only when status differs and `auth.uid()` is non-null.

### Event triggers
- Application-owned event trigger: `ensure_rls`, enabled on `ddl_command_end` for `CREATE TABLE`, `CREATE TABLE AS`, and `SELECT INTO`. It invokes `public.rls_auto_enable()`, which enables RLS on newly created tables in `public` and logs failures rather than aborting the DDL.
- Other observed event triggers (`issue_graphql_placeholder`, `issue_pg_cron_access`, `issue_pg_graphql_access`, `issue_pg_net_access`, `pgrst_ddl_watch`, `pgrst_drop_watch`) are Supabase/extension-managed and must not be copied as application migrations.

### Identity generation details
- Identity columns: `admin_role_events.id`, `admin_status_audit.id`, `job_posts.id`, `real_estate_posts.id`, and `service_requests.id` are GENERATED ALWAYS; `market_posts.id` and `realty.id` are GENERATED BY DEFAULT.
- Legacy sequence-default columns: `jobs.id`, `market.id`, `properties.id`, and `services.id` use explicit `nextval(..._id_seq)` defaults. The public sequence inventory lists 11 sequence objects total, including the six identity-backed sequences.
- Sequence ownership was observed as postgres for all 11; exact `OWNED BY` dependency links should still be confirmed before writing a restorable DDL script.

## Security review notes (not changes)
- Positive checks: public listing RPCs enforce approved-only visibility and contact opt-in; owner management RPCs perform explicit owner checks; sensitive private rate-limit/visitor tables are reached through SECURITY DEFINER functions with empty search paths and are not directly granted to client roles.
- Important caveat: `record_site_visit(uuid)` is a SECURITY DEFINER overload that accepts a caller-supplied UUID but is postgres-only according to its function ACL, while the no-argument IP-derived overload is the client-facing one. Preserve this distinction in any reconstruction.
- The custom `ensure_rls` event trigger is part of application security behavior and must be represented in a faithful local reconstruction. Do not disable it or replace it with blanket RLS changes.
- These are catalog/body reviews only, not runtime penetration tests. No function was invoked and no data was changed.


## View security, exact application policies and sequence dependencies (read-only, 2026-11-16)
- All five public views are owned by postgres and explicitly set `security_invoker=true`. The four legacy public views (`jobs_public`, `market_public`, `realty_public`, `services_public`) also set `security_barrier=true`. `approved_market_posts` is a filtered projection view and sets security_invoker, without security_barrier.
- Exact application RLS policies observed:
  - On each of `job_posts`, `market_posts`, `real_estate_posts`, and `service_requests`: authenticated-only SELECT policy with `is_admin()`, plus authenticated-only UPDATE policy with both USING and WITH CHECK set to `is_admin()`.
  - On `storage.objects`: public SELECT policies restricted to bucket IDs `market-images` and `listing-images`. No public-read policy was found for `pending-images`.
- RLS state was checked table-by-table: all 14 public tables have RLS enabled and none is FORCE RLS; all four private tables have RLS disabled and none is FORCE RLS. The direct schema/table ACL checks above remain essential context for the private tables.
- All 11 public sequences have a dependency on a corresponding table column. Identity sequences use dependency type `i`; legacy `nextval` sequences for `jobs`, `market`, `properties`, and `services` use dependency type `a`. Exact table/column pairs were verified for all sequences.
- No policies were found in `private`; the only application policies outside public tables are the two Storage object SELECT policies above. These exact policies and view options are required for faithful local reconstruction; do not broaden them.


## Constraint and index inventory (read-only, 2026-11-16)
- Catalog counts: public has 14 primary keys, 10 foreign keys, and 2 CHECK constraints; private has 4 primary keys and 6 CHECK constraints. All observed constraints were validated.
- Public foreign keys include Auth-user references with the observed delete actions: `admins.user_id` and `staff_roles.user_id` cascade; optional post ownership references on the four modern post tables set NULL; `staff_roles.granted_by` and both admin-role event actor/target references set NULL. Audit actor reference also sets NULL.
- Private checks enforce 64-character lowercase-hex fingerprints, nonnegative request counts, positive visitor counts, and the singleton boolean config key.
- Non-primary application indexes captured:
  - Private: `ask_rate_limits_updated_at_idx`, `pending_image_rate_limits_updated_at_idx`, `site_visitor_days_last_seen_idx`.
  - Public admin/audit: `admin_role_events_actor_id_idx`, `admin_role_events_target_user_id_idx`, `admin_status_audit_actor_id_idx`, `staff_roles_granted_by_idx`.
  - Each of the four modern post tables has a partial `user_id IS NOT NULL` index and a partial expiry index restricted to approved rows with non-null `expires_at`.
- The catalog grant inventory confirms client-role access is not uniform across tables and views; object-specific grants must be recreated rather than using a broad blanket GRANT. A complete grant reconstruction still needs a carefully filtered ACL export, including view and column ACLs, and should not import Supabase-managed object privileges.
