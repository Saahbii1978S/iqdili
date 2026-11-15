# Read-only database authorization audit — 2026-11-15

Scope: metadata and function-definition inspection of the live Supabase project. No DDL, DML, settings, Storage objects, Auth users, or production functions were changed.

## Executive result

No confirmed anonymous read path into the five legacy base tables was found in this inspection. The legacy views `jobs_public`, `market_public`, `realty_public`, and `services_public` have `security_invoker=true`; their underlying tables have RLS enabled, no policies, and no SELECT grants to `anon` or `authenticated`. The views themselves grant SELECT, but invoker security means callers still need privileges on the base tables. This is materially safer than an owner-executed view. Keep these legacy tables/views unused until their intended lifecycle is decided.

The current public listing RPCs are intentionally callable by `anon` and `authenticated`. Their inspected definitions filter to `status = 'approved'` and return phone only when `contact_public` is true. They are SECURITY DEFINER with an empty search_path. This appears consistent with public listing behavior, but requires endpoint-level negative tests before being treated as fully verified.

## Findings

### 1. Public listing RPCs — intentional exposure, test required

The following functions are executable by anon and authenticated:
- `public_job_posts()`
- `public_market_posts()`
- `public_real_estate_posts()`
- `public_service_requests()`

Inspected definitions:
- filter to approved records only;
- conditionally expose phone only when `contact_public` is true;
- return listing content and image URL arrays;
- use SECURITY DEFINER and `SET search_path TO ''`.

No current rows were present in the four current listing tables at audit time. This does not prove future behavior; add regression tests for pending/rejected exclusion and private-contact suppression.

### 2. Admin SECURITY DEFINER functions — explicit authorization guards found

The following functions are executable by authenticated users, but the inspected bodies check owner/admin authorization:
- `admin_list_status_audit()` calls `is_owner()`;
- `admin_list_users()` calls `is_owner()`;
- `admin_set_moderator(uuid, boolean)` calls `is_owner()`, rejects null/self targets, verifies the target user, and protects owner accounts;
- `get_site_visitor_stats()` explicitly requires an authenticated user present in `public.admins`.

`is_admin()` and `is_owner()` return boolean membership checks based on `auth.uid()`. All inspected functions set an empty search_path. These are positive code-review observations, not a substitute for negative authorization tests using non-admin and moderator accounts.

### 3. Visitor tracking RPC — public write surface to validate

`record_site_visit()` is executable by anon and authenticated. The inspected implementation:
- reads `x-forwarded-for` from request headers;
- validates the first value as an IP;
- combines it with a private salt and stores a keyed SHA-256-derived visitor identifier, not the raw IP;
- updates daily visitor counters.

Before relying on the metric, verify in a controlled staging test that the Supabase gateway supplies a trusted forwarding header and that clients cannot spoof it. Also test rate/abuse behavior and confirm the public function cannot access or modify unrelated records. The overload accepting `p_visitor_id` is not executable by anon or authenticated.

### 4. RLS-enabled tables without policies — currently no public grants

The security advisor reports 10 RLS-enabled tables without policies:
`admin_notification_events`, `admin_role_events`, `admin_status_audit`, `admins`, `jobs`, `market`, `properties`, `realty`, `services`, `staff_roles`.

For the inspected public tables, anon/authenticated table grants were absent. Thus the advisor finding is not itself proof of exposure. Preserve the restricted grants; do not add broad policies just to silence the advisor.

### 5. Legacy views — invoker security verified

`jobs_public`, `market_public`, `realty_public`, and `services_public` have both `security_barrier=true` and `security_invoker=true`. Their base tables have RLS enabled, zero policies, and no SELECT grants to anon/authenticated. The view `approved_market_posts` also has `security_invoker=true`, with no anon/authenticated SELECT grant on the view.

### 6. Storage policy snapshot

The inspected `storage.objects` policies grant public SELECT only for `market-images` and `listing-images`. No public INSERT/UPDATE/DELETE policy appeared in the policy listing. This is a metadata review only; upload and deletion flows still need integration tests.

### 7. Advisor items to track

Security advisor snapshot:
- 10 RLS-enabled tables without policies (explained above; verify grants remain restricted).
- 5 anon-executable SECURITY DEFINER findings, corresponding to the four public listing RPCs plus `record_site_visit()`.
- 11 authenticated-executable SECURITY DEFINER findings, including the admin functions above and the public listing RPCs.
- leaked-password protection disabled.

Do not revoke privileges or alter Auth settings based only on the advisor count. Confirm intended callers and frontend/Edge Function dependencies first. Leaked-password protection can be considered as a separate Auth hardening change after explicit approval and impact review.

## Data-state observation

Counts at audit time:
- Current listing tables `job_posts`, `service_requests`, `market_posts`, `real_estate_posts`: 0 rows each.
- Legacy tables `jobs` and `services`: 1 row each.
- Legacy tables `market`, `realty`, `properties`: 0 rows.

No row contents were read and no records were modified or deleted. In particular, the two legacy rows remain untouched.

## Required next tests (staging or disposable environment only)

1. Anonymous and ordinary authenticated calls to each public listing RPC: pending/rejected records must never appear.
2. Contact privacy matrix: `contact_public=false` must return null phone; true may return phone.
3. Non-admin calls to every admin RPC must fail with authorization error and disclose no rows.
4. Moderator versus owner tests: moderators must not list users, inspect owner audit, or grant/revoke moderator roles unless explicitly intended.
5. Visitor tracking: spoofed/missing forwarding header, repeated calls, malformed header, and unrelated-table isolation.
6. Storage: anonymous reads only from intended public buckets; anonymous writes/deletes must fail; private pending objects remain inaccessible.
7. Legacy views: anonymous and authenticated SELECT should fail against the legacy views unless base-table access is deliberately granted later.

## Change boundary

This document is an audit record and test plan, not a migration or approval to change production. No production changes were made. Do not alter legacy rows, public RPC grants, Auth settings, Storage policies, or database schema without separate approval.
