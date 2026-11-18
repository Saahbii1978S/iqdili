# Storage cleanup worker — implementation and test contract

**Status:** implementation specification only; no Edge Function is deployed by this document.

## Runtime responsibilities

The worker is a server-side scheduled Edge Function. It must never be callable by ordinary public clients.

### Request authentication
- Require a dedicated high-entropy worker secret from Supabase function secrets.
- Compare the presented credential safely and reject missing/invalid credentials before database access.
- Never place the secret in source, SQL, GitHub Actions YAML, logs, browser code, or documentation examples.
- Do not reuse the scheduled expiry verifier without a separate security review and explicit rotation plan.

### Processing loop
1. Claim a bounded batch from the private outbox through a narrowly scoped database operation.
2. For each task, revalidate bucket and path against the same fixed allowlist used at enqueue time.
3. Delete the exact object key from the exact bucket using server-side Storage credentials.
4. Treat confirmed object-not-found as success.
5. Complete, retry, or dead-letter the task using its lock token.
6. Continue after an individual task failure; one bad object must not stop the batch.
7. Return aggregate counts only. Do not return object paths or sensitive provider messages to the caller.

### Retry policy
- Retry network timeouts, rate limits, and transient server failures.
- Use bounded exponential backoff with jitter and a maximum delay.
- Treat malformed paths and disallowed buckets as permanent failures.
- After the configured attempt ceiling, retain the task as dead and alert the administrator.
- Ensure an expired lease can be reclaimed after worker crash.
- A stale worker whose lease has been replaced must not be able to complete or reschedule the task.

### Observability
Record aggregate counts, duration, and sanitized error categories. Do not log:
- service-role keys or worker secrets;
- authorization headers;
- signed URLs;
- raw Storage responses;
- full private object paths;
- personal data from listing rows.

Provide an admin-only way to inspect pending/retry/dead counts and oldest task age. Do not expose task contents in public endpoints.

## Failure-injection matrix

| Scenario | Expected result |
|---|---|
| Worker called without secret | Reject before claiming tasks |
| Wrong secret | Reject; no database changes |
| Empty queue | Successful no-op |
| Storage delete succeeds | Task becomes completed |
| Object already absent | Task becomes completed (idempotent) |
| Storage timeout | Task becomes retry with backoff |
| Storage 429 / 5xx | Task becomes retry with backoff |
| Invalid bucket or path | Task becomes dead; alert |
| Worker crashes after claim | Lease expires; another worker can reclaim |
| Old worker returns after lease replaced | Lock-token update affects zero rows |
| One task fails in a batch | Remaining tasks continue |
| Attempt ceiling reached | Task remains in dead state; alert |
| Database unavailable during state update | Do not claim completion; lease recovery handles retry |

## Integration test requirements

Tests must run against a disposable local or staging Supabase project with synthetic rows and objects:
- Two concurrent workers claiming overlapping batches.
- Crash simulation after claim and before Storage delete.
- Crash simulation after Storage delete and before completion update.
- Retry after transient Storage failure.
- Idempotent handling of an already absent object.
- Lock-token fencing against stale worker.
- RLS and EXECUTE privilege checks for anon/authenticated and non-admin users.
- Exact allowlist checks for all supported buckets and prefixes.
- Batch size, timeout, and maximum retry enforcement.
- No access to production listings or production Storage buckets during tests.

## Rollout gate

Do not schedule or deploy the worker until:
1. The transactional enqueue-and-delete RPC is implemented and independently reviewed.
2. Integration tests pass in a disposable environment.
3. RLS, grants, function privileges, and Supabase advisors are reviewed.
4. Synthetic Storage objects prove retry and crash recovery.
5. Monitoring and rollback procedures are documented.
6. The user separately approves the production migration, function deployment, secret setup, and schedule activation.
