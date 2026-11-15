# Read-only Supabase audit — 2026-11-15

Project: `iqdili` (Supabase project ref: `djzapiwxxuligpdbskfm`)  
Database engine: PostgreSQL 17.11  
Project status at inspection: ACTIVE_HEALTHY

This document records read-only findings. No production database rows, policies, grants, functions, buckets, or settings were changed.

## Listing data inventory

| Table | Rows |
|---|---:|
| `service_requests` | 0 |
| `job_posts` | 0 |
| `real_estate_posts` | 0 |
| `market_posts` | 0 |
| Legacy `services` | 1 |
| Legacy `jobs` | 1 |
| Legacy `properties` | 0 |
| Legacy `realty` | 0 |
| Legacy `market` | 0 |

The legacy service row is visibly marked as a test in its description. The single legacy job row is titled “نجار” and is not conclusively identifiable as a test from the inspected non-contact fields. Neither row was modified or copied.

The current listing tables are empty at the time of inspection. The site's current public listing RPC functions query the current tables, not the legacy tables. Do not migrate the legacy job row without owner confirmation.

## Legacy table access

RLS is enabled on the five legacy listing tables. They have no RLS policies, and the inspected grants query showed no direct `anon`, `authenticated`, or `PUBLIC` table grants. This is consistent with the legacy tables being retained but not directly exposed through the Data API.

The four current public listing RPCs are SECURITY DEFINER, use an empty search_path, return only `status='approved'` rows, and mask phone numbers unless `contact_public` is true. Their anonymous execution is intentional for the public listing UI, but should remain narrowly scoped to these read-only approved-listing results.

## Privileged function review

The inspected administrative SECURITY DEFINER functions have internal owner checks where sensitive:
- `admin_list_status_audit()` and `admin_list_users()` call `is_owner()`.
- `admin_set_moderator(uuid, boolean)` calls `is_owner()`, blocks changing the owner's own role, and protects owner records.
- `get_site_visitor_stats()` checks an authenticated owner/admin identity.
- `is_admin()` and `is_owner()` only return role predicates.
- `record_site_visit()` stores a keyed digest, not the raw IP address.

Two overloads of `record_site_visit` exist. The legacy caller-supplied UUID overload has EXECUTE revoked for both anon and authenticated. The no-argument function remains callable for anonymous visit counting and derives the identifier from the request address before hashing it.

## Advisor findings

The Supabase security advisor reports:
- 10 tables with RLS enabled and no policies. The inspected set includes legacy tables and internal admin/audit tables. The absence of direct grants on the inspected legacy/admin tables is a mitigating control; do not add blanket policies.
- 5 anonymous-callable SECURITY DEFINER functions: the four intentionally public read-only listing RPCs and `record_site_visit()`.
- 11 authenticated-callable SECURITY DEFINER functions, including administrative helpers. The sensitive functions inspected contain internal owner/admin checks. Continue reviewing each function before changing grants.

The health advisor returned no findings.

## Recovery artifacts

- `supabase/recovery/database.types.ts` is a generated TypeScript schema-types snapshot (25,541 characters at capture time). It helps recover client-side table/function types, but is **not** a complete SQL schema backup.
- `supabase/migrations/RECOVERY-MANIFEST.md` records the 28 applied migration names and versions.
- The 28 original SQL migration files were not found in the expected `supabase/migrations/` paths on `main` during this audit.

These files do not back up row data, Auth users, Storage object bytes, database policies/triggers/functions in full, or scheduled jobs. Obtain a real database backup and a separate Storage/Auth recovery plan from the Supabase dashboard before treating the project as recoverable.

## Next safe actions

1. Keep the legacy rows untouched until the owner confirms whether the “نجار” row is a test or genuine.
2. Export a full database backup and verify a restore in an isolated environment.
3. Reconstruct missing migration history only from authoritative source SQL or a schema dump; do not invent and replay migrations.
4. Keep the public RPC functions limited to approved listings and phone opt-in.
5. Review each SECURITY DEFINER grant individually; do not blanket-revoke or blanket-grant.
