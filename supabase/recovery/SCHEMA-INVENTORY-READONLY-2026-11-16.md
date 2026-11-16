# Read-only production schema inventory — 2026-11-16

## Scope and safety

This inventory was collected through read-only metadata queries against the connected Ahla Tounsa Supabase project. No DDL, DML, Auth, Storage, settings, or migration operations were run against production. No row contents, user records, phone numbers, tokens, secrets, or storage objects were exported.

This file is an inventory only. It is **not** a restorable database dump and must not be used as a substitute for the original migration history.

## Migration history

The Supabase migration ledger reports 28 applied migrations, from version `20261102161723` through `20261114202111`. The repository does not currently contain the complete original SQL files for these migrations. The ledger names alone do not reconstruct their exact SQL.

## Catalog inventory

Read-only catalog counts:

- Public base tables: 14
- Public views/materialized views: 5
- Private base tables: 4
- Policies in public/private/storage: 10
- Constraints in public/private: 36
- Indexes in public/private: 33
- Public functions: 16
- Private functions: 1
- Non-internal triggers in public/private/storage: 19

Public tables observed include:
`service_requests`, `job_posts`, `real_estate_posts`, `admins`, `market_posts`, `services`, `jobs`, `properties`, `market`, `realty`, `staff_roles`, `admin_role_events`, `admin_status_audit`, and `admin_notification_events`.

Private tables observed:
- `private.ask_rate_limits`
- `private.pending_image_rate_limits`
- `private.site_visitor_days`
- `private.site_visit_config`

The verbose table inventory also confirmed primary keys and foreign-key links from the four user-owned listing tables to `auth.users(id)`, plus the relevant columns/defaults. Full table definitions, view SQL, policies, function bodies, trigger bodies, grants, extensions and storage bucket policies still need a reproducible export before a faithful local restore can be declared.

## Security observation — private schema

The Supabase table inspection raised a critical advisory because RLS is disabled on the four private tables listed above.

A separate read-only check found:
- No direct table grants to `anon`, `authenticated`, `PUBLIC`, or `service_role` on those private tables in `information_schema.role_table_grants`.
- `anon`, `authenticated`, and `service_role` do not currently have `USAGE` or `CREATE` privilege on schema `private`.

This reduces the apparent direct exposure through those roles, but it does not replace a complete review of owner-level access, SECURITY DEFINER functions, default privileges, exposed-schema configuration, and service operations. **Do not blindly enable RLS** on these tables: doing so without deliberately designed policies could break legitimate server-side operations. No remediation was applied.

## Next safe steps

1. Recover an authoritative schema-only dump or exact original migration SQL through a supported read-only export path.
2. Compare the dump against the catalog inventory and repository migrations.
3. Build the local schema only after the comparison is complete; keep production credentials out of GitHub Actions and the repository.
4. Run integration tests against local Auth/PostgREST/Storage, with synthetic test users and data only.

## Verification boundary

The successful local Supabase smoke test proves that the local services can start and respond. It does not prove that the local database matches production or that application integration tests are complete.
