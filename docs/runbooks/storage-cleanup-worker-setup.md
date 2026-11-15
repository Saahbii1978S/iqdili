# Storage cleanup worker — deployment and verification runbook

Status: candidate implementation on `audit/safe-fixes-2026-11-15`. Nothing in this document has been applied to the live Supabase project.

## Components

- `public.storage_cleanup_jobs`: durable queue. Rows begin as `staged`, become `pending` only after the corresponding listing rows are deleted, and then move through `processing` to `completed` or `dead_letter`.
- `public.claim_storage_cleanup_jobs(integer)`: atomically claims a small batch using row locks and `SKIP LOCKED`; expired leases can be retried.
- `process-storage-cleanup`: server-only Edge Function. It checks object existence, removes only the exact queued object path, and records completion or a retry.
- Post, user-post, and account deletion functions enqueue image paths before deleting listing rows. They activate the jobs after the database deletion succeeds.

## Required deployment order

1. Apply the candidate migration to a disposable/staging Supabase project first. Do not apply it to production until the owner approves.
2. Confirm the `public` schema's Data API configuration permits the new queue table and claim RPC. New public tables are not automatically exposed to the Data API on current Supabase projects; keep access restricted to `service_role`.
3. Deploy `process-storage-cleanup` and the updated deletion Edge Functions together.
4. Confirm the function runtime has `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` configured. Never put the service-role key in browser code, repository files, or client-visible settings.
5. In the staging project's Vault, store:
   - `project_url`: the staging project URL
   - `storage_cleanup_service_key`: the staging project's service-role JWT
6. Enable `pg_cron` and `pg_net` in staging if they are not already enabled, then schedule the worker:

```sql
select cron.schedule(
  'ahla-tounsa-storage-cleanup',
  '* * * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
      || '/functions/v1/process-storage-cleanup',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'storage_cleanup_service_key'),
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'storage_cleanup_service_key')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 90000
  );
  $$
);
```

The service-role JWT is a privileged secret. Vault/pg_net scheduling must be configured only by the project owner; pg_net may temporarily retain the decrypted request headers while a request is queued. Review the current Supabase scheduling guidance before enabling this.

## Staging acceptance tests

- A successful test deletion creates one queue entry per unique bucket/object path and the queue entry becomes completed.
- A deliberately unavailable object is treated as already cleaned only when Storage returns 404; other HEAD errors must be retried.
- A simulated Storage DELETE failure returns the job to pending and records the error.
- Two simultaneous worker calls do not claim the same live lease.
- An expired processing lease can be reclaimed.
- After eight failed claims, the job moves to dead_letter and remains visible for manual review.
- No job for a still-existing listing may leave staged status.
- Confirm the queue has no access for anon/authenticated roles and that service_role can call the claim RPC.

## Monitoring and recovery

Inspect `storage_cleanup_jobs` for `pending`, `processing`, and `dead_letter` rows. Review errors before manually retrying a dead-letter job. Do not delete queue rows as a cleanup shortcut.

## Important limits

The worker is not scheduled by this repository change. Adding the function and migration to GitHub does not deploy them, expose the Data API table, create Vault secrets, or create a Cron job. All of those steps require staging verification and explicit owner approval before production.
