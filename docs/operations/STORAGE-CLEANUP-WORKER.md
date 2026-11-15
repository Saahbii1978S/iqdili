# Storage cleanup worker — controlled rollout

This worker is part of the review branch only. It is not deployed and the candidate migration is not applied to the live Supabase project.

## What it does

- Claims at most five pending jobs per invocation using a five-minute database lease and a unique per-claim token; stale workers cannot update a job reclaimed by a newer worker.
- Processes only the three allow-listed image buckets and validated image object keys.
- Checks whether the exact key is still referenced by a live listing before Storage access, then checks again immediately before deletion.
- Uses an exact object-info request; only HTTP 404 is treated as already absent. Other non-success responses are retried.
- Deletes one exact object key, never a folder or prefix.
- Completes a job only after Storage confirms deletion or confirms the object is absent.
- Records errors for retry; after eight attempts the job moves to `dead_letter`.
- Every completion, retry, or defer update must match both the job ID and its current lease token.
- Keeps jobs staged while another live listing references the same object.

## Required rollout order

1. Review and approve the candidate migration `supabase/migrations/20261115090000_storage_cleanup_jobs.sql`.
2. Apply the migration to a separate staging Supabase project first, then run `supabase/tests/storage-cleanup-queue.sql`.
3. Deploy the Edge Function `process-storage-cleanup` to staging with normal JWT verification enabled.
4. Invoke it only from a trusted server-side scheduler using the project's service-role JWT in both `apikey` and `Authorization: Bearer ...` headers. Never put the service-role key in browser code, Git, Actions logs, or a public URL.
5. Schedule a small cadence (for example every 5 minutes), monitor completed/retried/dead-letter counts, and verify retry recovery in staging.
6. Only after explicit owner approval, repeat the reviewed migration and function deployment in production.

## Important operational limits

- This worker does not self-schedule. A trusted scheduler must invoke it; no cron job or secret has been configured by this change.
- The worker is intentionally not callable with an ordinary signed-in user's access token.
- Never run the worker against production until the migration, function, and scheduler are all deployed and verified together.
- Do not manually delete queue rows to clear errors. Review the exact bucket, object key, and last error first.
- Uploads currently use random UUID object names with upsert disabled. Keep that invariant: never reuse an existing object key for a new upload.
