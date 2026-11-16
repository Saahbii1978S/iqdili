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
