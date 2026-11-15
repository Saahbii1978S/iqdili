# Failure-injection test matrix: storage cleanup and notifications

**Status:** test specification only. No production migration, function deployment, Storage operation, schedule, or data mutation is authorized by this document.

**Target:** AHLA TOUNSA / Iqdili reliability work in the review branch.

## 1. Test environment and safety boundary

Run these tests only against a disposable local Supabase stack or a dedicated staging project containing synthetic users, synthetic listings, and synthetic Storage objects.

Never run destructive tests against production. Never use production listing IDs, real user accounts, real object paths, or existing demo/test records as fixtures. Do not copy production secrets into local fixtures. Use fake credentials and a mail sink.

Before each test run:
- Record the local/staging project identity and confirm it is not production.
- Create uniquely prefixed synthetic object paths, for example `it/<run-id>/...`.
- Keep a fixture manifest mapping each synthetic listing to its expected bucket and exact object paths.
- Ensure cleanup is scoped to that run ID and fixture manifest only.
- Capture task state transitions and sanitized errors; never log bearer tokens, service-role keys, email contents, or full provider responses.

## 2. Storage cleanup outbox: required invariants

The implementation is not ready until all of these invariants pass:

1. **Atomic enqueue + row deletion:** the listing row deletion and insertion of every corresponding cleanup task commit together or roll back together.
2. **No lost paths:** once a listing row is deleted, every eligible object path remains represented by a durable task until terminal completion.
3. **Allowlist enforcement:** only explicitly permitted bucket IDs and validated object keys can be processed.
4. **Idempotency:** deleting an already absent object is treated as success; repeated worker delivery cannot damage unrelated objects.
5. **Concurrency safety:** two workers cannot hold a valid lease for the same task at the same time.
6. **Lease recovery:** a worker crash does not strand a task permanently in processing.
7. **Bounded retries:** transient failures retry with bounded backoff; exhausted tasks remain visible in a dead-letter state and trigger an alert.
8. **No collateral deletion:** invalid paths, foreign buckets, pre-existing public objects, and objects outside the fixture manifest are never deleted.

## 3. Failure-injection matrix

| ID | Injected condition | Expected result | Evidence required |
|---|---|---|---|
| S01 | Force transaction failure before cleanup-task insert | Listing remains; no task is committed | Row and task counts unchanged |
| S02 | Force failure after task insert but before listing delete | Entire transaction rolls back | Listing remains; no partial tasks |
| S03 | Delete listing with 0 images | Listing deletion succeeds; no empty/invalid task | No task created |
| S04 | Delete listing with multiple valid image paths | Listing and all tasks commit atomically | One task per unique valid path |
| S05 | Include malformed URL or path traversal-like value | Reject/skip safely; never derive a key from URL | No task for invalid value; sanitized diagnostic |
| S06 | Supply a bucket outside the allowlist | Worker refuses task without touching Storage | Foreign object still exists |
| S07 | Storage returns transient 5xx/timeout | Task moves to retry with attempt count and future retry time | State transition and sanitized error |
| S08 | Storage confirms object is already missing | Task becomes completed (idempotent success) | Completed state; no repeated failure |
| S09 | Worker stops after claiming a task, before Storage call | Lease expires; task becomes claimable again | Second worker claims after expiry |
| S10 | Worker stops after Storage deletion, before marking completed | Retry sees missing object and marks completed | No collateral deletion; eventual completion |
| S11 | Two workers claim concurrently | Exactly one valid lease holder per task | Distinct task claims; no overlapping lease |
| S12 | One task permanently fails while later tasks are valid | Failed task reaches dead state; batch continues | Later tasks complete; dead task retained |
| S13 | Retry counter reaches configured ceiling | Task moves to dead and alert is emitted once or deduplicated | Dead state and alert record |
| S14 | Duplicate cleanup request for same object | Unique/idempotent behavior prevents uncontrolled duplicate work | Stable task identity or documented dedupe |
| S15 | Attempt to process task with expired/invalid lease token | State update is rejected | Task remains owned by valid lease holder |
| S16 | Batch contains one malformed task among valid tasks | Malformed task is isolated; valid tasks continue | Per-task outcomes recorded |
| S17 | Account deletion has multiple listings, then one DB operation fails | Transaction rolls back all row changes and enqueues | All fixture rows remain; no partial tasks |
| S18 | Account rows/tasks commit, then Auth deletion fails | Durable cleanup tasks remain available | Tasks persist and can complete independently |
| S19 | Approval creates a new public copy, then status update definitively fails | Only the copy created by this attempt is queued for compensation | Original pending object and pre-existing public object remain |
| S20 | Approval finds an already-existing public object, then status update fails | Compensation does not delete that pre-existing object | Existing object remains untouched |

## 4. Notification outbox: required invariants

Treat email delivery as **at-least-once**, not exactly-once. A provider timeout can occur after the provider accepted a message but before the caller received confirmation. Use a stable event identity and deduplication strategy, and make duplicate delivery behavior explicit.

| ID | Injected condition | Expected result | Evidence required |
|---|---|---|---|
| N01 | Database transaction fails before event enqueue | No event is committed and no send is attempted | No outbox row |
| N02 | Provider returns a clear non-2xx rejection | Event becomes retryable or dead according to policy | Sanitized provider category; no false sent state |
| N03 | Provider times out before acceptance | Event remains retryable | Attempt count and next retry recorded |
| N04 | Provider accepts email but response is lost | Event is handled as ambiguous; retry policy documents possible duplicate | No claim of exactly-once delivery |
| N05 | Worker crashes after claiming event | Lease expiry makes event claimable again | Event recovered after lease |
| N06 | Worker crashes after provider acceptance, before marking sent | Retry follows at-least-once policy and records ambiguity | State history and duplicate-risk behavior |
| N07 | Same logical event is enqueued twice | Stable idempotency key/dedupe rule prevents unintended duplicate event creation | One logical event |
| N08 | Invalid recipient or permanent provider rejection | Event reaches dead state and is visible to admin | Dead state and sanitized reason |
| N09 | Temporary provider outage affects one event | Other independent events continue | Batch-level isolation |
| N10 | Logs are inspected after all failures | No API keys, bearer tokens, full email bodies, or sensitive user data appear | Redacted log review |

## 5. Authorization and abuse tests

Run negative authorization tests for every database operation and worker entry point:

- Anonymous caller cannot enqueue deletion for any listing.
- Authenticated non-owner cannot delete another user's listing or enqueue its paths.
- Moderator/admin permissions are checked using trusted server-side role data, not user-editable metadata.
- A forged source table, bucket, path, record ID, or reason is rejected.
- A caller cannot mark another worker's leased task completed.
- Public/anonymous roles cannot read or mutate outbox rows or invoke privileged worker functions.
- A malformed or replayed request cannot bypass ownership checks.
- A worker secret is never accepted from query parameters or logged.

Record the expected SQLSTATE/HTTP class without exposing sensitive details.

## 6. Deterministic test design

Prefer dependency injection around Storage and email-provider calls so tests can simulate:
- success;
- object absent;
- transient failure;
- permanent failure;
- timeout before provider acceptance;
- ambiguous timeout after provider acceptance;
- process interruption at each state boundary.

Use a controllable clock for lease expiry and retry scheduling. Avoid tests that depend on real waiting or real email delivery.

Each test should:
1. Create isolated synthetic fixtures.
2. Assert initial database and Storage state.
3. Trigger exactly one injected failure.
4. Assert database transaction outcome and task state.
5. Retry or recover the worker where appropriate.
6. Assert final state and absence of collateral changes.
7. Remove only fixtures created by that test run.

## 7. Exit criteria before any production proposal

Do not propose production rollout until:
- Every applicable matrix case passes in disposable local/staging.
- Transaction rollback is demonstrated, not inferred from application logs.
- Concurrent-worker and lease-expiry tests pass repeatedly.
- Authorization tests pass for anonymous, non-owner, owner, and admin contexts.
- Storage path validation has positive and negative test coverage.
- Notification ambiguity and duplicate-delivery behavior is documented.
- Dead-letter visibility and alerting are verified.
- Supabase security advisors and a human review of grants, RLS, function privileges, and search_path are complete.
- A rollback plan and a narrowly scoped rollout sequence are reviewed separately.

## 8. Explicit non-goals

This document does not authorize:
- Applying a migration to the connected production database.
- Creating or enabling extensions, cron schedules, Vault secrets, or worker credentials.
- Deploying or changing any Edge Function.
- Deleting or modifying any existing listing, user, Storage object, or test record.
- Sending real email.
- Merging the review pull request or deploying the branch to GitHub Pages.

The current review branch remains a review artifact, not a production deployment bundle.
