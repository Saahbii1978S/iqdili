# Account deletion audit — 2026-11-15

Scope: read-only comparison of the `delete-account` candidate on `audit/safe-fixes-2026-11-15`, the active Supabase Edge Function (version 4), the account-deletion page, and current database foreign-key metadata.

No production data, Storage objects, Auth users, function deployments, secrets, or database settings were changed.

## Confirmed protections

- The function accepts POST only and requires the exact configured website Origin.
- It does not accept a user ID from the request body. It validates the supplied bearer session through `/auth/v1/user` and derives the target ID from that response.
- It rejects malformed/missing bearer authorization and fails closed if required Supabase environment variables are absent.
- It confirms `confirm: "DELETE"`.
- It checks both `admins.user_id` and `staff_roles.user_id`; query errors stop deletion, and a matching role blocks deletion. Current schema confirms both columns exist.
- It reads all four current listing tables before destructive work, protects known demo IDs and test/demo-labelled rows, and validates image paths against the expected folder and extension.
- Database listing rows are deleted before Storage objects, so a Storage failure does not leave those same rows publicly active without their images.
- Current foreign keys from `admin_role_events` and `admin_status_audit` to `auth.users` use ON DELETE SET NULL; these audit references should not block Auth deletion. `admins` and `staff_roles` are protected before deletion.

## Findings requiring remediation before production reliance

### A1 — No durable Storage-cleanup recovery record (high)

The function deletes all four categories of database rows, then deletes Storage objects in batches, then deletes the Auth user. If a Storage batch fails after the database rows have been removed, the function returns 502 and leaves the Auth user present. However, the paths needed for cleanup existed only in the in-memory `pathsByTable` snapshot. A retry re-reads no listing rows and therefore cannot rediscover the remaining orphaned paths. The current error message asks the user to contact administration, but no durable cleanup ticket or retry record is created.

Required design: atomically persist a cleanup job containing exact validated bucket/path pairs before or alongside row deletion; process it with a bounded, leased worker and retry/dead-letter state. Never reconstruct paths from broad bucket prefixes.

### A2 — Snapshot/delete race can lose image paths (high)

The function reads each user's rows and `image_urls`, then later deletes rows using only `user_id=eq.<id>`. A concurrent edit or new post between those steps can cause the DELETE to remove a row whose latest image paths were not in the earlier snapshot. Those files can become orphaned. A concurrent upload/post may also race with the account deletion flow.

Required design: serialize account deletion against post creation/editing (for example, a server-side deletion state checked by every write path) and perform row capture + delete + durable outbox creation transactionally. A client-side sequence of REST calls cannot guarantee this boundary.

### A3 — Password re-entry is enforced only by the webpage (medium/high)

The deletion page re-enters the password with `signInWithPassword`, but the Edge Function itself only validates that the bearer token identifies a user. A caller with a still-valid access token can invoke the function directly without going through the page's password prompt. The page is useful UX, not a server-side recent-authentication control.

Required design: enforce recent authentication server-side (validate a trusted JWT `auth_time`/session-age claim or another server-verifiable reauthentication proof) before any destructive work. Do not rely on the browser to enforce it.

### A4 — No request-body byte limit or rate limit (medium)

The function calls `req.json()` directly without a streaming byte cap and has no endpoint-level rate limit. The expected body is tiny, but a caller can submit an unnecessarily large body while holding a valid session.

Required design: use the shared `readLimitedRequest` helper with a small JSON limit before parsing, and add a server-side rate limit keyed to the authenticated user. Ensure rejected requests do not consume unrelated upload/post quotas.

### A5 — Per-table pagination cap is fixed at 10,000 rows (low/operational)

The scan requests ten pages of 1,000 rows. If a table has 10,000 rows exactly, `complete` remains false and the function returns 413; this is a conservative cap, not silent truncation. The behaviour should be documented and tested at 9,999, 10,000, and 10,001 rows, or replaced with a durable paginated cleanup job for large accounts.

## Frontend observations

- The deletion page requires an active session, asks for the account password again, and requires the exact Arabic confirmation phrase before invoking the function.
- The page correctly tells users that legacy posts submitted without an account are not automatically linked or removed.
- The page reports completion only when the function returns `ok: true`; it does not claim success on a failed invocation.

## Test plan required before changing the function

1. Invalid method, Origin, missing/oversized bearer header, invalid token, malformed user response, malformed JSON, wrong confirmation.
2. Role-check 403/5xx and confirmed admin/moderator accounts: no row or Storage changes.
3. Protected demo IDs and demo/test text in each table: no row or Storage changes.
4. Invalid image path, wrong folder, traversal, duplicate paths, empty image list.
5. Pagination boundaries at 999, 1,000, 9,999, 10,000, and 10,001 rows.
6. Failure at every DB delete step; ambiguous network result; concurrent row edit/new post while deletion is in progress.
7. Storage failure on the first, middle, and final batch; retry must recover exact remaining paths after the original rows are gone.
8. Auth deletion failure after successful row and Storage cleanup; retry must complete without harming unrelated data.
9. Direct Edge Function invocation with an old but otherwise valid access token must fail the recent-authentication check.
10. Oversized JSON and repeated calls must be bounded and rate-limited.

## Current status

- The branch candidate and active Supabase `delete-account` version 4 have matching function logic in the inspected source.
- No dedicated `delete-account` test file exists in the function directory.
- This audit is documentation only. No function source, live database, Storage object, Auth account, cron job, secret, or deployment was changed.
- Do not deploy or merge until the high-severity recovery/race issues and server-side recent-authentication control are designed, tested, and explicitly approved.
