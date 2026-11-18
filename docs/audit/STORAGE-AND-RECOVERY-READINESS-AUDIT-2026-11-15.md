# Storage, image lifecycle and recovery-readiness audit — 2026-11-15

Scope: read-only inspection of live Supabase project metadata for `djzapiwxxuligpdbskfm`, including project health, migration history, Storage bucket configuration, object counts/sizes, Storage RLS policies, and existing recovery documentation in this branch. No object names or user listing content were read. No Storage objects, database rows, buckets, policies, backups, or project settings were modified.

## Current verified state

### Project and migration history
- Supabase project reports `ACTIVE_HEALTHY`, region `eu-west-1`, PostgreSQL 17.11.
- The migration history endpoint returned 28 applied migrations, latest version `20261114202111` (`respect_service_contact_privacy`).
- Health advisor returned no lints at inspection time.
- This confirms project health status and migration records, but not backup availability or restoreability.

### Storage buckets
Three buckets exist:
- `pending-images`: private, maximum 3 MiB, allowed MIME types JPEG/PNG/WebP.
- `listing-images`: public, maximum 3 MiB, allowed MIME types JPEG/PNG/WebP.
- `market-images`: public, maximum 3 MiB, allowed MIME types JPEG/PNG/WebP.

Object metadata counts (no object names or paths queried):
- `pending-images`: 5 objects, 1,587,920 bytes total; oldest created 2026-11-08 08:01 UTC and newest 2026-11-08 08:27 UTC.
- No object rows were returned for either public bucket at inspection time.

IMPORTANT: the five private pending objects were intentionally left untouched. Prior audit notes identify them as unreferenced candidates, but they may be test or recovery-relevant material. Do not delete without a separate, reviewed inventory and explicit approval.

### Storage policies
The only Storage object policies returned by catalog inspection are public SELECT policies scoped to:
- `listing-images`
- `market-images`

No public SELECT policy was present for `pending-images`, consistent with its private-bucket purpose. No public INSERT/UPDATE/DELETE policies were found in the returned policy set. Upload and lifecycle actions are expected to run through trusted server-side Edge Functions using privileged credentials; continue to keep service-role credentials out of browser code.

## Findings

### STO1 — Public buckets are intentionally public (informational / verify content suitability)
The `listing-images` and `market-images` buckets allow public reads. This is expected for approved listing photos, but it means an object URL is publicly retrievable regardless of whether a corresponding listing row is later hidden or deleted. The application must therefore ensure that only approved/sanitized images are copied into these buckets and that deletion cleanup is reliable.

Recommendation: preserve the existing private-pending → validation/moderation → public-copy flow. Never upload unapproved user images directly to a public bucket. Add staging tests for failed approval, failed DB status update after public copy, deletion, and retry.

### STO2 — Pending objects exist without current listing references (known, do not clean up)
The bucket contains five objects totalling approximately 1.59 MB. Earlier audit work identified these as not referenced by current listing image paths. This can represent abandoned uploads, but it may also include test/recovery artifacts.

Recommendation: keep them unchanged. Build a durable, auditable cleanup inventory with object path, age, reference check, reason, and approval status before any deletion. A cleanup worker must use bounded batches, retry state, and a safe grace period.

### STO3 — Storage/database lifecycle is not atomic (high reliability risk)
Existing Edge Function review found DB-first deletion followed by best-effort Storage removal in `admin-delete-post` and `delete-my-post`. If Storage removal fails after the row is deleted, a retry may no longer know the image paths. Account deletion has a related failure mode. Approval can also leave a public copy if copying succeeds but the database status update fails.

Recommendation: implement a transactional outbox pattern before relying on automated cleanup:
1. Record the intended Storage operation in the same database transaction as the listing state change.
2. Use a bounded worker with leases, attempt counters, backoff, and dead-letter visibility.
3. Make operations idempotent and reconcile Storage HEAD state before retry.
4. Keep a grace period and never delete by broad bucket prefix.
5. Test partial failures and process restarts in staging.

The branch already contains the outbox design contracts and failure-injection test matrix; they remain design documentation, not deployed functionality.

### STO4 — Backup and point-in-time recovery status not independently verified (high assurance gap)
The project metadata endpoint did not expose backup schedule, retention, PITR entitlement, last successful backup, or restore-test status. The migration history is not a database backup. A healthy project status does not prove recoverability. No backup was created and no restore was attempted.

Recommendation for owner verification in Supabase Dashboard:
- Check the project's Backup settings and confirm the exact backup schedule and retention available on its current plan.
- Confirm whether Point-in-Time Recovery is enabled and its retention window, if available.
- Confirm database backups do not imply Storage object backups; verify a separate Storage export/backup strategy for image files.
- Keep an encrypted off-project copy of critical migration files, schema/type snapshots, and recovery runbook.
- Perform a controlled restore into a separate test project and verify schema, auth-dependent flows, and image-object references before claiming disaster recovery is tested.
- Record backup timestamps, retention, restore duration, and verification results without exposing credentials.

## Recovery-readiness checklist

- [ ] Confirm database backup schedule and retention in the dashboard.
- [ ] Confirm PITR availability and retention, if enabled.
- [ ] Define an independent backup/export plan for Storage objects.
- [ ] Keep migration files and recovery manifest in version control and a separate protected copy.
- [ ] Perform a restore drill into an isolated project.
- [ ] Verify restored listing rows and image references against restored Storage objects.
- [ ] Document recovery time objective (RTO) and recovery point objective (RPO).
- [ ] Rehearse rollback and recovery without touching production data.

## Release boundary

This was a read-only inspection. No backups, restores, Storage object changes, bucket changes, SQL writes, migrations, policy edits, or production deployments were performed. The five pending-image objects remain untouched. Backup/PITR status remains unverified until checked in the Supabase Dashboard or confirmed through an authoritative project backup interface.
