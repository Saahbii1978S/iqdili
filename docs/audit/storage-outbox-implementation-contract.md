# Storage cleanup outbox — implementation contract (draft)

**State:** design/specification only. This file is not SQL to run and is not a deployment approval.
**Target:** AHLA TOUNSA / Iqdili.
**Branch:** audit/safe-fixes-2026-11-15.

## Non-negotiable invariants

1. A listing row must not be deleted until its exact eligible Storage object paths have been durably recorded.
2. Recording cleanup work and deleting the source row must commit or roll back together in one PostgreSQL transaction.
3. Storage deletion happens asynchronously, after commit, and is idempotent.
4. A worker may only delete from explicitly allowed buckets and validated object-key prefixes.
5. A retryable failure must leave a durable task; a terminal failure must leave a visible dead-letter task.
6. Public users cannot read, insert, update, claim, or delete outbox tasks.
7. Existing test listings and unidentified Storage objects must be preserved.
8. Storage cleanup and email delivery use separate queues and separate state machines.

## Proposed database boundary

Use an unexposed schema (provisionally `private`). Do not create this schema in production as part of this PR.

### Table contract

`private.storage_cleanup_outbox` should contain:

- `id uuid primary key`
- `bucket_id text not null`
- `object_path text not null`
- `source_table text not null`
- `source_record_id text not null`
- `reason text not null`
- `status text not null` constrained to pending, processing, retry, completed, dead
- `attempt_count integer not null default 0`
- `next_attempt_at timestamptz not null default now()`
- `locked_until timestamptz`
- `lock_token uuid`
- `last_error_code text` (sanitized category only)
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`
- `completed_at timestamptz`

Use a unique key on (bucket_id, object_path, reason) or a separately designed idempotency key. Decide whether a completed object can ever legitimately be re-enqueued before finalizing the uniqueness rule; do not accidentally suppress a future cleanup after an object is recreated at the same key. Add partial indexes for due tasks and expired leases.

Enable RLS as defense in depth. Keep the schema out of exposed API schemas. Revoke all privileges from PUBLIC, anon, and authenticated. Do not add broad grants merely to make the table convenient for the frontend.

### Atomic source operations

Expose only narrowly scoped database operations, with explicit authorization and fixed source-table handling. Do not accept arbitrary table names, bucket names, paths, or Storage URLs from clients.

For each source operation:

1. Resolve caller identity from the verified request context.
2. Verify owner/admin authorization in the database operation (not from user-editable metadata).
3. Lock and read the target row.
4. Read its image path fields and parse only supported project-owned object keys.
5. Reject malformed, external, traversal, or out-of-scope paths; do not guess a path from a URL.
6. Insert outbox rows with a stable idempotency key.
7. Delete the source row.
8. Return a compact result only after the transaction commits.

Any exception before commit must roll back both the source-row deletion and all task inserts. Account deletion must enumerate only the known owned listing tables and enqueue all paths in the same transaction as the row deletes. Auth-user deletion is a later step; if it fails, already committed cleanup tasks remain available.

Avoid a generic SECURITY DEFINER function unless a documented permission analysis proves it necessary. If needed, set an empty search_path, fully qualify every object, verify auth.uid()/admin role inside the function, revoke PUBLIC execution, and test unauthorized callers explicitly.

## Worker contract

A worker should claim a bounded batch in one short transaction using row locking and SKIP LOCKED. Each claimed row receives a random lock token and lease expiry. The Storage request occurs outside the database transaction.

- Claim only pending/retry tasks whose next_attempt_at is due, plus processing tasks whose lease expired.
- Verify lock token on every state transition so a stale worker cannot overwrite a newer claim.
- Delete exactly the stored bucket and object path.
- Treat confirmed “not found” as completed (idempotent).
- On success, mark completed and set completed_at.
- On transient failure, increment attempts, clear lease, store a sanitized error code, and schedule bounded exponential backoff with jitter.
- On permanent invalid-target errors, move to dead and alert; never broaden the allowlist to make the task pass.
- On attempt ceiling, move to dead while retaining the task and diagnostic category.
- Do not log access tokens, service-role keys, signed URLs, full provider responses, or private object paths in public logs.

The worker must use a server-side secret held only in the platform secret store. Do not embed a bearer token or verifier in GitHub source, workflow YAML, SQL, or documentation examples.

## Approval compensation contract

A failed approval must not remove the private pending original. The approval handler must distinguish:
- destination already existed before this invocation;
- destination was created by this invocation;
- copy result is ambiguous due to timeout;
- status update succeeded or failed.

Only a destination proven to have been created by this invocation may be enqueued for compensation. An ambiguous copy result requires a safe existence/ownership reconciliation; do not blindly delete. The status update must use the verified admin identity so audit attribution remains correct. If compensation cannot be durably enqueued, return a clear failure and trigger an admin alert; never claim the object was cleaned up.

## Required automated tests

### Database transaction tests
- Success: outbox rows and source-row delete both commit.
- Inject failure after first outbox insert: no source row deleted and no partial task rows remain.
- Inject failure immediately before source-row delete: all inserts roll back.
- Duplicate request: idempotency behavior is deterministic and does not erase task history.
- User A cannot delete or enqueue cleanup for User B's row.
- Non-admin cannot invoke admin deletion.
- Arbitrary table names, bucket IDs, URLs, traversal paths, unsupported prefixes, and malformed keys are rejected.
- Account deletion across all supported listing tables is atomic.

### Worker tests
- Concurrent claimers do not own the same live lease.
- Worker A's stale lock token cannot complete or reschedule a task claimed by Worker B.
- Worker crash after claim is recovered after lease expiry.
- Storage success and already-missing object both become completed.
- Timeout, 429, and 5xx schedule retry with bounded delay.
- Invalid target and max attempts become dead and alert.
- A failure on one task does not block the rest of the batch.
- Batch and runtime limits are enforced.

### Approval tests
- Copy succeeds, status update succeeds: no compensation task.
- Copy created by this invocation, status update fails: one compensation task.
- Destination existed before invocation: no compensation task and no delete.
- Copy times out ambiguously: no blind deletion.
- Pending original remains untouched in every failure case.

## Test environment and exit criteria

Before any live migration:
- Run migrations and integration tests against a disposable local/staging database, not the production project.
- Use synthetic rows and synthetic objects in a dedicated test bucket.
- Verify RLS, grants, function execute privileges, and Supabase security/performance advisors.
- Verify crash recovery, concurrency, retry, and dead-letter behavior.
- Produce a rollback/recovery procedure and prove it on the disposable environment.
- Obtain separate explicit approval before any production schema change, function deployment, schedule activation, secret rotation, or data cleanup.

## Current execution status

- This contract is documentation only.
- No migration has been created or applied.
- No Edge Function has been deployed.
- No production row, Storage object, secret, schedule, or setting has been changed.
- The existing PR must remain draft and unmerged until integration tests and review are complete.


## Submission-upload compensation contract

The public submission flow uploads a pending image before inserting the listing row. If the database insert fails, the current candidate makes a best-effort Storage DELETE and ignores a failed cleanup response. A timeout or Storage failure can therefore leave an unreferenced private object without a durable retry record.

Before production rollout, choose and test one of these safe designs:

1. Prefer a database-first reservation: create a pending submission/reservation record with a server-generated identifier, then upload to a path bound to that reservation, and transition the reservation only after upload validation; or
2. If upload-before-insert must remain, add a durable compensation record before returning from any failed insert path. The record must identify only the exact server-generated `pending-images` key, be inaccessible to public roles, and be retryable by the same bounded worker/lease mechanism.

Do not enqueue arbitrary client-supplied paths. Do not delete an object if the listing insert may have committed despite a lost/ambiguous response; reconcile by the server-generated submission identity first. Tests must cover DB rejection, DB timeout after commit, Storage DELETE timeout, worker retry, and preservation of unrelated pending objects. This compensation path is distinct from post-deletion cleanup but may share a carefully scoped worker implementation.



## Listing lifecycle audit — 2026-11-15

This section records source-level findings from the review of the candidate branch and the currently deployed functions. It is not authorization to deploy, migrate, rotate secrets, or delete data.

### Expiry path

The candidate `expire-posts` improves on the deployed v5 implementation by:
- loading the verifier from `EXPIRE_POSTS_TOKEN_HASH` and failing closed when it is absent;
- paginating approved expired rows in batches of 100;
- skipping protected demo rows;
- validating every image key against the section-specific folder before deleting the database row;
- reporting scan, row-delete, invalid-path, and Storage-cleanup failures separately.

Remaining race to close before production: the conditional database DELETE matches the row ID, approved status, expiry timestamp, title, and description, but does not match the `image_urls` snapshot that was read. If an image list changes between the read and DELETE, the function could delete the updated row while only knowing the old paths. Prefer a transactional database operation that enqueues the exact current paths and deletes the row atomically. As an interim measure, add an exact `image_urls` snapshot predicate and test null, empty, and populated arrays; verify PostgREST JSONB filter encoding against staging before relying on it.

### Reject / unpublish path

The candidate `admin-update-post-status` changes status using the verified administrator JWT and a conditional status predicate. It then checks public image objects and treats only HTTP 404 as proof of absence; other HEAD errors fail closed. This is safer than interpreting every non-2xx response as a missing object.

Open policy decision: the function cleans the public bucket only. A rejected pending post may still have its private `pending-images` original. Do not automatically delete that original until the product policy is decided: rejection may need to preserve the private upload for the owner to correct and resubmit, while an explicit permanent removal may require cleanup. Document the intended retention period and make the action visible to the owner/admin.

Remaining race: the status PATCH currently matches only ID and prior status, not the title, description, or `image_urls` snapshot used for demo protection and cleanup. A concurrent edit can invalidate those checks. Close this with an atomic database operation or snapshot predicates covering all fields that determine protected-demo classification and image cleanup. Do not blindly delete a path after a stale read.

### Delete paths

The candidate `admin-delete-post`, `delete-my-post`, and `expire-posts` all remove the database row before deleting Storage objects. This avoids leaving a visible listing with missing images, but it creates a recoverability gap: if the Storage call fails or times out, the listing is already gone and there is no durable retry record. Email alerts and response flags are best-effort, not a cleanup queue. The user-delete path can report cleanup pending, but that does not guarantee an administrator ticket or eventual retry.

The required production design remains the transaction/outbox contract above: atomically enqueue exact object keys with the source-row deletion, then let a bounded worker retry Storage deletion. Never use a generic prefix deletion or client-provided path. Until that exists, do not describe cleanup as guaranteed.

### Required lifecycle regression tests

- Expiry: more than 100 rows, UUID keyset pagination, protected demos mixed into a full page, malformed image paths, scan failure, row-delete failure, and cleanup timeout.
- Expiry concurrency: mutate `image_urls`, title, description, status, or expiry between SELECT and DELETE; confirm the stale snapshot cannot delete a changed row.
- Reject/unpublish: pending vs approved state, protected demo by ID and text, concurrent image edit, public image already absent, Storage HEAD 403/429/5xx, DELETE timeout, and decision-specific retention of the private pending original.
- User delete: owner vs non-owner, protected demo, concurrent edit, row-delete conflict, public and pending objects independently missing/failing.
- Admin delete: owner-role authorization, demo-only override, rejection of ordinary posts when `delete_test` is set, malformed paths, and partial Storage failure.
- All delete paths: database timeout with ambiguous commit, Storage timeout after row deletion, duplicate retry, and durable outbox recovery.

### Deployment-sensitive finding

The deployed `expire-posts` v5 source still contains a fixed verifier hash, while the candidate reads `EXPIRE_POSTS_TOKEN_HASH` from the runtime environment. Treat the deployed verifier as exposed. Rotation must include the runtime secret and the scheduled request header together, be coordinated to avoid breaking the daily job, and happen only after separate explicit approval. No rotation or schedule change was performed during this audit.

### Current scope

- Source and deployment snapshots were reviewed read-only.
- This audit section is documentation only.
- No production data, Storage objects, migrations, secrets, cron schedules, function deployments, or site publishing were changed.


## Approval image-copy recovery (candidate revision)
- Approval stages cleanup records for every unique destination image path and every private source path before any Storage copy.
- Each public destination path is unique to the approval attempt, preventing an unrelated/pre-existing public object from being mistaken for this attempt's copy.
- All images are copied, not only the first image.
- The final database transition uses `approve_post_if_unchanged`, an administrator-authorized atomic compare-and-set over status, title, description, and the complete original image path array. It updates status, expiry, and public image paths in one statement.
- Staged cleanup jobs older than ten minutes are eligible for worker reconciliation. The worker checks references twice before deletion. Approved listings protect only their public bucket objects; pending listings protect only their private pending-images objects. Unpublished/rejected rows do not keep public image jobs stuck. Orphaned copies from failed/ambiguous approval are removed, while the original private source is removed after approval changes the row to public image paths.
- This is candidate source only. The migration must be applied and the worker safely scheduled before this path can operate in production. No live function or database was changed by this commit.
