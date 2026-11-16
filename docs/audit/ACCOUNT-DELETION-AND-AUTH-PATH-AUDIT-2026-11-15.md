# Account deletion and authentication-path audit — 2026-11-15

Scope: source review of the audit branch Edge Functions. This is a static source audit only; no live requests, account deletions, role changes, database writes, storage mutations, or deployments were performed.

## Executive summary

The account-deletion function verifies the bearer token against Supabase Auth and blocks users present in either `admins` or `staff_roles`. It also enumerates four current listing tables, protects known demo records, validates image paths, and deletes listing rows before Storage objects and the Auth user.

However, the current sequence contains a significant retry/recovery flaw and concurrency gaps. The function should not be treated as production-ready until a durable deletion workflow is implemented and tested.

## Findings

### A1 — Retry after Storage cleanup failure can orphan images permanently (high)

The function first deletes all listing rows for the user. It then deletes the image paths collected from the pre-delete snapshot. If a Storage deletion fails, the function returns 502 while leaving the Auth user in place.

On retry, the listing rows have already been deleted, so the function's fresh SELECT returns no rows and it reconstructs an empty image-path list. It can then proceed to delete the Auth user successfully, leaving the images from the first attempt in Storage with no remaining database references.

Required remediation: persist a deletion job and the exact validated object paths before deleting listing rows; make the job durable and retryable independently of the user's Auth account. Use bounded worker retries, leases, and a dead-letter/alert state. Do not rely on a client retry to reconstruct paths from rows already deleted.

### A2 — Concurrent post creation/edit can escape the collected image snapshot (high)

The function snapshots rows and image paths, then later deletes all rows matching `user_id`. A concurrent post submission or image update after the snapshot may be deleted by the broad user_id DELETE while its newly uploaded image path was not in the collected snapshot. That leaves an orphan object.

Required remediation: prevent new submissions/edits while account deletion is pending (server-enforced deletion state), and use a transaction/outbox or equivalent atomic lifecycle boundary that captures all object paths associated with the deleted rows.

### A3 — No server-enforced recent reauthentication (medium/high)

The endpoint validates that the bearer token is currently valid, but it does not check `auth_time`, recent password reauthentication, or an equivalent recent-authentication signal. The UI's confirmation step is not a server-side reauthentication guarantee.

Required remediation: require a short-lived, server-verifiable reauthentication proof or enforce a recent `auth_time` window. Do not trust a client-supplied boolean or confirmation string as proof of identity.

### A4 — No explicit request-body size limit or endpoint rate limit (medium)

The handler calls `req.json()` without first bounding the body stream and has no endpoint-specific rate limit. The expected payload is tiny, so oversized requests should be rejected before JSON parsing. Rate limiting should be tied to the authenticated user and applied without exposing account existence.

### A5 — Account deletion covers four listing tables only; full user-data inventory needs confirmation (medium)

The function explicitly processes `service_requests`, `job_posts`, `real_estate_posts`, and `market_posts`. This source alone does not prove that all user-linked records across every current or legacy table, audit/event table, and Auth metadata are covered. A schema-wide foreign-key and data-retention inventory is required before describing this as complete account erasure.

### A6 — Origin validation is not an authentication boundary (informational)

The endpoint checks a fixed Origin, which is useful for browser CORS behavior, but non-browser clients can forge or omit Origin. The actual security boundary must remain the validated bearer token, server-side authorization, and any required recent-authentication proof.

## Positive controls confirmed in source

- Supabase Auth validates the supplied bearer token via `/auth/v1/user`.
- Missing server configuration fails closed.
- Accounts found in `admins` or `staff_roles` are blocked from self-deletion.
- The four listing tables are paginated in batches of 1,000 with a 10,000-row ceiling; exceeding the ceiling aborts before deletion.
- Known demo IDs and demo/test-labelled records abort deletion before destructive operations.
- Image paths are validated against the expected folder and a restricted filename pattern.
- Listing rows are deleted before Storage cleanup, avoiding live listings pointing to already-deleted images in the ordinary sequential path.
- The Auth user is deleted only after the preceding operations report success.

## Required staging regression tests

1. Force first Storage batch deletion to fail; retry account deletion and verify all original objects are still discovered and eventually removed.
2. Upload a new image and submit/edit a listing between snapshot and row deletion; verify no orphan object can escape cleanup.
3. Simulate timeout/ambiguous responses for each table DELETE, Storage DELETE, and Auth DELETE; verify retries converge safely.
4. Verify recent-authentication enforcement, expired session, revoked session, malformed bearer token, and cross-user attempts.
5. Verify oversized request body and repeated deletion requests are rejected safely.
6. Create user-linked rows in every current/legacy table and inventory all foreign keys, triggers, auth metadata, and retention obligations.
7. Verify admin/owner accounts and protected demo rows remain untouched under every failure-injection case.
8. Verify deletion job recovery after the Auth user has been deleted; the worker must not depend on the user's JWT or Auth row.

## Release boundary

This report documents source-level findings only. No live function, database schema, RLS policy, Storage object, Auth setting, secret, or scheduled job was changed. Any implementation must remain on the audit branch and pass staging failure-injection tests before separate approval for production deployment.
