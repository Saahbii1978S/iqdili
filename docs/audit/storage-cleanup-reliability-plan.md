# Storage cleanup and notification delivery reliability plan

**Status:** design only; not an executable migration or deployment instruction.  
**Scope:** AHLA TOUNSA / Iqdili production reliability.  
**Safety:** no production database, Storage object, Edge Function, secret, or listing was changed while preparing this plan.

## 1. Findings this plan addresses

- Several live deletion paths remove the database row before Storage cleanup. If cleanup then fails, the row no longer contains the object paths needed for a reliable retry.
- `delete-account` can partially delete rows across multiple tables before a later table or Storage operation fails.
- `delete-my-post` and `admin-delete-post` report cleanup status but there is no durable retry queue.
- `admin-approve-post` can create a public image copy before the approval status update. If the status update fails, the copy may remain public.
- `admin_notification_events` currently acts as a deduplication marker (primary key: `user_id, event_type`). A failure after inserting the marker but before confirmed Brevo acceptance can suppress a later retry.

## 2. Recommended storage-cleanup outbox

Use a dedicated, non-exposed schema (for example `private`) and a durable table conceptually containing:

| Field | Purpose |
|---|---|
| `id` UUID primary key | Stable cleanup task identity |
| `bucket_id` text | Strict allowlist: only the expected project buckets |
| `object_path` text | Exact object key, never a user-supplied URL |
| `source_table` text | Allowlisted source table |
| `source_record_id` text/UUID | Source record reference, if it still exists |
| `reason` text | Small enum such as listing-delete, account-delete, approval-compensation |
| `status` text | pending, processing, retry, completed, dead |
| `attempt_count` integer | Number of worker attempts |
| `next_attempt_at` timestamptz | Backoff schedule |
| `locked_until` timestamptz | Worker lease expiry |
| `last_error_code` text | Sanitized error category; never store credentials or full responses |
| `created_at`, `updated_at`, `completed_at` | Audit timestamps |

Add a uniqueness rule for an object cleanup task so concurrent deletion paths cannot create uncontrolled duplicate work. Preserve task history; do not hard-delete failed tasks. Keep the schema outside exposed API schemas, enable RLS as defense in depth, and grant no access to anon/authenticated. Only a narrowly scoped worker role/function should claim and update tasks.

### Critical transaction rule

**Insert cleanup tasks and delete the associated database row in the same Postgres transaction.** If either operation fails, both must roll back. An Edge Function making two separate REST calls is not enough to guarantee this.

Use a narrowly scoped database operation that:
1. receives a validated source identifier and caller context;
2. checks ownership or the exact admin role inside the database operation;
3. reads the exact `image_urls` paths from the row;
4. validates bucket/path against fixed allowlists;
5. inserts cleanup tasks;
6. deletes the row;
7. commits both together.

Prefer invoker permissions with explicit RLS/grants. If a SECURITY DEFINER function is proven necessary, use an empty search_path, fully qualified object names, strict caller authorization inside the function, revoke default PUBLIC execution, and run Supabase advisors plus negative authorization tests.

For account deletion, queue every owned listing's image paths and remove the associated rows in one transaction before attempting Auth user deletion. The durable cleanup tasks must survive even if Auth deletion or later Storage cleanup fails. Confirm exact ownership and all affected table names before implementation.

## 3. Worker and retry rules

- Claim a small batch atomically with row locks / `SKIP LOCKED` and a short lease, so two workers do not process the same task simultaneously.
- Call Storage using only the saved bucket and exact validated object path.
- Treat “object already absent” as successful cleanup (idempotency).
- Mark completed only after Storage confirms deletion or confirms the object is absent.
- On transient errors, increment attempts and schedule bounded exponential backoff with jitter.
- After a configured attempt ceiling, move to `dead`, retain the task and sanitized error, and alert the administrator.
- Expired leases return to retry automatically.
- Limit batch size and execution time; do not let one bad object block the batch.
- Never delete an object from a bucket outside the allowlist. Never infer a path from a URL.
- Provide an admin-only read-only view of pending/retry/dead counts and task age; do not expose object paths publicly.

A scheduled worker can be invoked with the existing Supabase scheduling stack only after confirming secrets are stored safely. The current project has `pg_cron` and `pg_net`; this inspection did not find `pgmq` or Vault installed. Do not add extensions or schedules without approval. A simple outbox table plus a carefully authenticated scheduled Edge Function is sufficient for this project's expected low volume.

## 4. Approval image compensation

For approval:
1. Read and validate the pending object path.
2. Copy to the public bucket using a deterministic destination path.
3. Track whether this invocation actually created the destination; do not claim ownership of a pre-existing object.
4. Attempt the status update using the verified administrator JWT so the audit trigger can record `auth.uid()`.
5. If the status update definitively fails, enqueue cleanup for the newly created public copy before returning. Never enqueue a pre-existing public object and never delete the private pending original.
6. If enqueueing compensation fails, return a clear high-severity error and alert; do not claim cleanup is safely scheduled.
7. Add race/failure-injection tests for copy success + status failure, timeout after copy, concurrent approvals, and an already-existing destination.

## 5. Notification delivery outbox

Do not use a single “event exists” row as proof that an email was delivered. Replace the current dedupe-only semantics with explicit delivery state:
- pending / processing / sent / retry / dead;
- attempt count, lease, next attempt time, last sanitized error, created/sent timestamps;
- unique idempotency key for the logical notification.

Claim atomically, call Brevo, and mark sent only after a confirmed accepted response. Retry transient network/5xx/rate-limit failures with backoff. Treat permanent recipient/configuration errors separately and alert. Because an external email provider cannot participate in the database transaction, exactly-once delivery cannot be guaranteed; design for at-least-once attempts with a stable idempotency key where supported and duplicate-safe email content. Never mark sent before provider acceptance.

## 6. Required tests before any production rollout

### Storage cleanup
- Row delete and cleanup-task insert succeed or both roll back.
- Storage delete success.
- Object already missing.
- Storage timeout / 5xx followed by successful retry.
- Worker crash after claim; lease expiry permits retry.
- Two workers claim concurrently; no duplicate active claim.
- Invalid bucket, traversal path, URL instead of object key, and unsupported path are rejected.
- Max retries moves to dead and alerts without discarding the task.
- User A cannot enqueue/delete User B's listing; non-admin cannot run admin cleanup.
- Account deletion fails midway while queued cleanup tasks remain durable.
- Cleanup task for a pre-existing public object is never created by failed approval compensation.

### Notification delivery
- Brevo accepts; state becomes sent.
- Brevo timeout after request; state remains retryable.
- Brevo 429/5xx; bounded retry.
- Permanent 4xx/config error; dead/alert behavior.
- Two concurrent requests for the same logical notification create one task.
- Worker crash after provider acceptance but before state update; duplicate behavior is documented and safe.

## 7. Rollout sequence (approval required at each stage)

1. Build migration and tests locally/on a disposable staging project; no production writes.
2. Review schema, RLS, grants, function security, and advisor output.
3. Deploy schema only after explicit approval; verify table is inaccessible to anon/authenticated.
4. Deploy worker disabled or in dry-run mode; confirm it claims no production tasks unexpectedly.
5. Exercise synthetic test objects and test records in an isolated bucket/project.
6. Deploy one deletion path at a time, with monitoring and rollback plan.
7. Enable schedule only after worker and secrets are verified.
8. Migrate notification delivery separately; do not conflate email state with storage cleanup.
9. Reconcile existing orphan-like pending uploads manually; do not bulk-delete them.

## 8. Current project-specific constraints

- Existing pending-images objects that are not referenced by current listing rows are only “orphan-like”; they may be abandoned uploads or tests. Preserve them until each is identified.
- Keep all test listings unpublished and preserve all current test data.
- Do not deploy the current audit branch wholesale: it contains candidate snapshots and targeted fixes, not a verified one-to-one production bundle.
- Rotate the scheduled expiry verifier separately because its old literal appeared in public Git history; do not put a replacement value in source or commit history.
- The current PR remains draft and unmerged. No production migration, function deployment, Storage deletion, or secret rotation is authorized by this design note.
