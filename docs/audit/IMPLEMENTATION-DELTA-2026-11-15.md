# Implementation delta — 2026-11-15

This addendum reconciles the earlier source-audit findings with the current candidate code on `audit/safe-fixes-2026-11-15`. It supersedes earlier statements below only where explicitly noted. It does not approve deployment.

## Verified candidate changes

### Account deletion recovery and race controls

The current candidate `delete-account/index.ts` now:
- Validates the bearer token with Supabase Auth, then requires a JWT `auth_time` within ten minutes via `hasRecentAuthentication`.
- Bounds the JSON request to 1 KiB before parsing.
- Blocks self-deletion for both `admins` and `staff_roles`.
- Scans all four current listing tables with bounded pagination and aborts on protected demo records or invalid image paths.
- Stages exact Storage cleanup jobs before the database transaction.
- Calls `delete_account_posts_and_activate_cleanup`, which compares the complete row snapshots, serializes account writes, inserts a durable account-deletion lock, deletes all four listing categories, and activates only exact image jobs that are no longer referenced.
- Deletes the Auth user only after the database transaction succeeds. If Auth deletion fails, the durable account lock and cleanup jobs remain so the user can retry without allowing new listings to race into the gap.

Accordingly, earlier findings A1 (lost image paths on retry), A2 (concurrent new listing escape), and A3 (no server-side recent-authentication check) in `ACCOUNT-DELETION-AND-AUTH-PATH-AUDIT-2026-11-15.md` are **addressed in candidate source**, subject to staging verification. The request-size portion of A4 is also addressed; no endpoint-specific rate limit was found in the current candidate and remains open.

The fixed ten-page pagination ceiling remains conservative: a table containing exactly 10,000 rows is rejected rather than processed. This is safe against silent truncation but remains an operational limit.

### Storage cleanup lifecycle

The candidate adds a durable queue, bounded worker batches, leases, retry counters, dead-letter state, exact-object Storage HEAD/DELETE requests, and reference checks. Listing deletion and cleanup activation are coupled through database RPC transactions. Image attachment is guarded against paths already pending/processing/completed/dead-lettered for cleanup; delete/claim/attachment paths use per-object advisory locks.

The candidate `admin-approve-post` deliberately stages recovery jobs for both destination and source objects before copying. The worker can later remove unreferenced partial copies after the grace period, while preserving paths still referenced by a live listing.

### Automated checks

The latest observed GitHub Actions run for `Safety regression tests` completed successfully. It type-checks Edge Functions, runs Deno tests, applies the candidate migrations to an isolated PostgreSQL service, and runs the SQL regression suite.

This is not a live Supabase integration test and does not establish real multi-session concurrency behavior or Storage API failure recovery against an actual bucket.

## Remaining release blockers

1. **No worker schedule is created by this repository change.** The runbook requires owner-configured Vault secrets and a pg_cron/pg_net schedule in staging, then production only after approval. Until that is configured, staged/pending jobs will not be cleaned automatically.
2. **No staging Supabase project was used for end-to-end validation.** The CI PostgreSQL test does not validate Supabase Auth, PostgREST grants/schema exposure, Storage HEAD/copy/DELETE, Vault, pg_net, or Cron.
3. **No dedicated account-deletion endpoint failure-injection suite exists.** Add tests for Auth deletion failure and retry, the 9,999/10,000/10,001 pagination boundaries, concurrent insert/update during deletion, and failure/timeout at every external step.
4. **No real concurrent-session test has been run** for the object attachment, deletion, and worker-claim interleavings. The advisory-lock and trigger design needs staging tests using separate database sessions.
5. **No endpoint-specific rate limit was found** for `delete-account`. Keep the bounded body and recent-authentication check, and add a user-scoped rate limit before production.
6. **Account-erasure scope and retention policy still need a final owner decision.** The schema-wide FK inventory is now reconciled in `USER-DATA-RELATIONSHIP-INVENTORY-2026-11-15.md`; the endpoint explicitly removes the four listing categories, protects admin/staff accounts, and leaves audit/event retention to policy. Do not describe this as complete erasure of every possible user-linked record until notification-event retention, Auth metadata, and legacy unowned records are addressed.
7. **Five existing private `pending-images` objects remain untouched.** They are not part of this change and must not be bulk-deleted.
8. **Backup and restore readiness is unverified.** A healthy project status and migration manifest are not a backup or a tested restore.

## Safety boundary

- No candidate migration was applied to the live Supabase project.
- No Edge Function was deployed.
- No Cron job or Vault secret was created.
- No listing, user, Storage object, role, or production setting was changed.
- All existing test/demo listings and the five private pending objects remain untouched.
- Do not merge or deploy this candidate until staging acceptance tests pass and the owner explicitly approves the production release.


## Reconciliation addendum — live foreign-key metadata

A fresh read-only query against the live project's PostgreSQL catalog (`pg_constraint` joined to the referenced `auth.users` relation) confirms the following. This catalog query is authoritative for the current FK definitions and resolves the earlier conflicting summary; the prior information_schema query returned an empty result and was not reliable for this inventory.

- `service_requests.user_id`, `job_posts.user_id`, `real_estate_posts.user_id`, and `market_posts.user_id` reference `auth.users(id) ON DELETE SET NULL`. The candidate explicitly deletes these rows before deleting the Auth user.
- `admins.user_id` and `staff_roles.user_id` use `ON DELETE CASCADE`; the candidate checks both role tables and refuses self-deletion when a matching role exists.
- `admin_role_events.actor_id`, `admin_role_events.target_user_id`, `admin_status_audit.actor_id`, and `staff_roles.granted_by` use `ON DELETE SET NULL`. These audit/grant records remain, with the user reference nulled.
- The inspected `admin_notification_events.user_id` column has no FK to `auth.users`; its retention or deletion must be decided separately.
- Legacy tables `jobs`, `services`, `market`, `realty`, and `properties` have no inspected account-ownership FK. Do not infer ownership or delete their rows automatically.

This is metadata-only verification: no row contents, account identities, or event payloads were read, and no live data or schema was changed. The remaining blocker is a documented retention/minimization decision for notification events and any Auth metadata, not an unresolved FK inventory.
