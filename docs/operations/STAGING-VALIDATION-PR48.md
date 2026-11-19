# Storage Cleanup Staging Validation Runbook — PR #69

## Purpose and safety boundary

This runbook defines the pre-production validation required for the storage-cleanup outbox and worker integrated by the main-based candidate.

**This document does not authorize or perform any deployment.** Do not merge PR #69, create a staging Supabase project, apply migrations, deploy Edge Functions, configure a scheduler, create secrets, or modify production resources without explicit owner approval.

All destructive tests must use a separate disposable staging project and objects created solely for this test. Never point a test worker at production Storage. Never use real user uploads or production listing rows.

## Entry criteria

Before starting:

- [ ] Owner explicitly approves creation/use of a separate staging Supabase project.
- [ ] Staging project is confirmed to be isolated from production (project URL, project ref, Storage buckets, database).
- [ ] A disposable bucket and uniquely prefixed test object paths are designated.
- [ ] A dedicated staging service-role secret is available only to the trusted operator/scheduler environment; it is not placed in browser code, GitHub source, logs, chat, or client-visible settings.
- [ ] An operator can inspect Edge Function logs, Postgres rows, Storage object state, and scheduler results.
- [ ] An external alert destination and responsible responder are identified. The worker does not currently send admin alerts itself.

If any item is missing, stop. Do not substitute production for staging.

## Migration-history check

A read-only check of the connected production project's migration history on 2026-11-19 found the latest applied version is `20261119093408` (`cleanup_stale_site_presence`). The five candidate migrations in this PR are now versioned with unique timestamps later than that baseline, in the order listed below. They are not present in production. Confirm the same baseline and migration ordering in the isolated staging project before applying them. Do not apply any candidate migration to production as part of this validation. No production migration was applied during the audit.

## Candidate migration order

Apply only to the disposable staging project, in this exact order, after owner approval:

1. `20261120090000_storage_cleanup_jobs.sql`
2. `20261120090500_storage_cleanup_attachment_lock.sql`
3. `20261120091000_storage_cleanup_detachment_lock.sql`
4. `20261120091500_storage_cleanup_atomic_defer.sql`
5. `20261120092000_account_deletion_limits.sql`

Record the migration result and resulting schema version after each step. Stop on the first error; do not skip or reorder migrations.

## Deployment order in staging

1. Deploy the candidate Edge Function sources from the main-based candidate head, including `process-storage-cleanup` and all functions changed by the integrated candidate.
2. Set the staging service-role secret only in the protected Edge Function/scheduler secret store. Never print its value.
3. Configure a trusted staging-only scheduler with a conservative cadence and a small batch. The worker currently claims up to five jobs per invocation.
4. Verify the scheduler targets only the staging function URL and sends the service-role JWT in both `apikey` and `Authorization: Bearer` headers.
5. Confirm that no public/browser route can invoke the worker with elevated credentials.

## Required test cases

Use newly created disposable test objects and listing rows for every case. Capture timestamps, job IDs, expected state, observed state, and relevant log excerpts with secrets and personal data redacted.

### A. Worker authentication

- [ ] POST without either required header is rejected.
- [ ] POST with an invalid API key is rejected.
- [ ] POST with a valid API key but invalid bearer token is rejected.
- [ ] A valid staging scheduler request succeeds.
- [ ] GET and other unsupported methods are rejected.
- [ ] No response or log includes the service-role secret.

### B. Happy path and idempotency

- [ ] Create a disposable object and a cleanup job for its exact bucket/path.
- [ ] Invoke the worker and confirm the object is removed and the job reaches its terminal completed state.
- [ ] Repeat the same cleanup request and confirm it is safe/idempotent.
- [ ] Confirm a Storage 404 for an already absent object is treated as successful cleanup.
- [ ] Reinsert/reuse the same bucket/path in a controlled staging fixture, reactivate the completed job, and verify attempts reset and the job becomes pending.

### C. Attachment and detachment races

Run the actual-migration concurrency tests in CI first, then verify the same invariants using staging fixtures:

- [ ] Worker claim wins first: a concurrent attempt to attach the object is rejected while cleanup owns the lock.
- [ ] Attachment wins first: worker claim detects the live reference and does not delete the object.
- [ ] Final detachment commits first: defer logic sees no remaining references and requeues eligible cleanup.
- [ ] Defer sees a reference first: the job is staged; a later final detach reactivates it.
- [ ] After each test, verify both listing references and Storage object state. No live reference may point to a deleted object.

### D. Transient failures and retry recovery

Use a controllable staging-only failure mechanism or a disposable test endpoint; do not induce failures against production.

- [ ] Simulate Storage HEAD 5xx and confirm the job is deferred/retried, not marked completed.
- [ ] Simulate Storage DELETE 5xx and confirm retry state and error metadata are correct.
- [ ] Simulate network timeout for HEAD and DELETE and confirm the worker exits safely without falsely completing the job.
- [ ] Restore the dependency and confirm a later invocation succeeds.
- [ ] Verify the documented backoff sequence: 2, 4, 8, 16, 32, then 60 minutes maximum (scheduler cadence can extend observed wall-clock delay).
- [ ] Verify that after eight failed claims/attempts the job enters `dead_letter`.
- [ ] Verify that a deliberate later reactivation of the same key returns the job to pending and resets attempts as designed.

### E. Database permissions and deletion controls

- [ ] Confirm `storage_cleanup_jobs` has RLS enabled and is not directly accessible to anon/authenticated roles.
- [ ] Confirm only the intended service-role path can operate the queue.
- [ ] Confirm account deletion rate limiting allows no more than three attempts per hour unless the persistent deletion lock is already active.
- [ ] Confirm the post-count limit counts all four listing categories.
- [ ] Confirm the deletion lock prevents new listing writes during the deletion workflow.
- [ ] Use disposable test accounts only; never test deletion controls with a real account.

### F. Monitoring and operational readiness

The current worker returns aggregate counters, including `dead_lettered`, but does not itself send admin alerts or persist full duration/error-category telemetry.

Before any production rollout:

- [ ] Add external monitoring for invocation failures, repeated transient failures, and any nonzero `dead_lettered` count.
- [ ] Alert on stale pending/staged jobs and queue growth, not only function invocation failures.
- [ ] Define an owner, response time, and documented recovery procedure for each alert.
- [ ] Verify an alert end-to-end using a disposable staging event.
- [ ] Ensure logs redact credentials, user identifiers, and private object paths where appropriate.
- [ ] Confirm retention and access controls for logs and monitoring data.

## Evidence package

Keep a staging validation record containing:

- PR head SHA tested.
- Staging project reference (not secrets), migration outcomes, and deployment versions.
- CI run URL and passing job summaries.
- Test-case results with timestamps and disposable fixture IDs.
- Redacted worker/scheduler logs and before/after queue states.
- Proof that no live object reference was broken.
- Alert delivery evidence and named operational owner.
- Any deviations, failures, and remediation commits.

## Exit criteria

Staging is accepted only when every required case passes, the evidence package is complete, the external alert path is proven, and an independent reviewer signs off.

Passing CI alone is not production approval. The current CI concurrency harness tests the actual candidate migration functions/triggers in disposable PostgreSQL, but it does not exercise the live Supabase Storage service, scheduler, real network failure injection, or end-to-end alert delivery.

## Production release gate

Production rollout requires a separate explicit approval after staging sign-off. The rollout plan must include a reviewed migration window, backup/rollback strategy, scheduler activation procedure, monitoring coverage, and a post-deployment verification window. Until then, keep the integration pull request as a draft and leave production unchanged.
