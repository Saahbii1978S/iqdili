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

