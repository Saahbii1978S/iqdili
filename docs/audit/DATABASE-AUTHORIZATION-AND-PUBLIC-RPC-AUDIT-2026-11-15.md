# Database authorization, public RPC and privilege audit — 2026-11-15

Scope: read-only inspection of live Supabase catalog metadata for project `djzapiwxxuligpdbskfm`: `pg_policies`, table RLS flags and grants, function ACLs, and `pg_get_functiondef` for public listing RPCs, site-visit tracking, and admin helpers. No rows were read from user listing tables or legacy content tables. No SQL writes, migrations, grants, policy edits, or function deployments were performed.

## Executive summary

The live database has a meaningful separation between direct table access and public listing access:

- No `anon` table grants were found on the inspected public tables.
- The four current listing tables grant `SELECT` to `authenticated`, but their SELECT policies are restricted to `is_admin()`; the policies also require admin status for updates.
- The legacy tables and admin/audit tables had no `anon` or `authenticated` table grants in the inspected grants.
- Public listing reads are exposed through four explicitly granted SECURITY DEFINER RPCs. Their SQL definitions return only approved rows and mask phone numbers unless `contact_public` is true.
- The admin helper SECURITY DEFINER functions use an empty search_path and explicit role checks. The moderator-management and admin reporting functions are owner-only.
- A public no-argument site-visit tracking RPC is executable by anon/authenticated. It hashes an IP value with a private salt rather than storing the raw IP, but its trust boundary depends on the gateway-provided `x-forwarded-for` header being sanitized.

## Verified controls

### DB1 — Direct table access is not public

Catalog inspection showed no `anon` table grants on public tables. The four current listing tables (`service_requests`, `job_posts`, `real_estate_posts`, `market_posts`) grant `SELECT` to `authenticated`, with RLS enabled and policies that call `is_admin()`. Their UPDATE policies also use `is_admin()` in both `USING` and `WITH CHECK`.

The admin, staff-role, audit, notification, and legacy tables have RLS enabled and no direct `anon`/`authenticated` table grants in the inspected metadata. The absence of policies on those tables is therefore not equivalent to public exposure under the currently observed grants. Revisit whenever grants change.

### DB2 — Public listing RPCs are constrained by SQL predicates and output shaping

The four public RPCs (`public_service_requests`, `public_job_posts`, `public_real_estate_posts`, `public_market_posts`) are SECURITY DEFINER and executable by `anon` and `authenticated`. Their current definitions:
- select only rows with `status = 'approved'`;
- return explicit column lists rather than `SELECT *`;
- return phone only when `contact_public` is true;
- do not expose `user_id` or moderation status.

The functions use `SET search_path TO ''` and schema-qualify table references. These are good defensive controls.

### DB3 — Admin and owner RPCs enforce role checks

- `is_admin()` checks the current `auth.uid()` against `admins` or `staff_roles`.
- `is_owner()` checks `admins`.
- `admin_set_moderator` checks owner status, rejects null/self targets, verifies the target account exists, and protects owner accounts.
- `admin_list_users` and `admin_list_status_audit` explicitly require owner status.
- `get_site_visitor_stats` explicitly requires an authenticated owner.
- These inspected SECURITY DEFINER functions use an empty search_path and qualified object names.

### DB4 — Privileged overload of site-visit RPC is not publicly executable

The no-argument `record_site_visit()` is executable by `anon` and `authenticated`. The separate `record_site_visit(p_visitor_id uuid)` overload showed an ACL limited to postgres; it is not granted to anon/authenticated in the inspected ACL.

## Findings / verification items

### DB-RPC1 — Public listing RPCs return every approved row without pagination (medium, performance/abuse)

All four public listing RPC definitions order by `created_at desc` but have no limit or cursor parameter. As approved listings grow, each public request can return the full dataset, increasing response size, database work, browser memory, and the cost of repeated anonymous calls.

Recommendation: design keyset pagination with a stable ordering (for example `created_at, id`), fixed server-side maximum page size, and a matching frontend continuation strategy. Keep the status predicate and `contact_public` phone masking in the database. Test all four categories and deep links in staging before release.

### DB-RPC2 — Verify provenance of `x-forwarded-for` used by public visit tracking (medium, trust-boundary verification)

The public `record_site_visit()` reads `request.headers ->> 'x-forwarded-for'`, takes the first comma-separated value, validates it as an IP address, and hashes it with a secret salt from `private.site_visit_config`. It does not store the raw IP. This is privacy-conscious, but the accuracy and abuse resistance of the metric depend on PostgREST/Supabase gateway behavior: client-supplied forwarding headers must not be allowed to control the trusted first address.

Recommendation: verify the actual gateway behavior with safe staging requests and inspect only sanitized metadata. If client input can influence the trusted value, use a gateway-authenticated source or disable public tracking until corrected. Also consider a bounded rate/retention policy for the private visitor table.

### DB-RPC3 — Public SECURITY DEFINER functions are an intentional high-value boundary (ongoing control)

The four listing RPCs and no-argument visit RPC are public SECURITY DEFINER entry points. Current definitions were reviewed and their behavior is narrow, but any future edit must preserve explicit columns, approved-only filtering, phone masking, fixed search_path, and safe input handling. Add regression tests that assert anon cannot directly select listing tables and can see only approved RPC output.

## Follow-up tests

1. Using anon credentials, verify direct SELECT on each current and legacy table is denied, while public listing RPCs return only approved records.
2. Using an authenticated non-admin account, verify direct table SELECT is denied by RLS and admin-only RPCs fail.
3. Using a moderator account, verify only intended admin functions work and owner-only functions fail.
4. Using owner credentials, verify user and status audit RPCs work and expose only the intended fields.
5. In staging, test whether a client-supplied `x-forwarded-for` header can affect `record_site_visit()` input; do not manipulate production visitor counts.
6. Load-test paginated RPC design in staging before replacing current full-list RPCs.

## Release boundary

This report is based on live catalog metadata and function definitions only. No content rows were read. No live database objects, permissions, policies, RPCs, secrets, or visitor records were modified. Any remediation must be reviewed, tested in staging, and separately approved before production rollout.
