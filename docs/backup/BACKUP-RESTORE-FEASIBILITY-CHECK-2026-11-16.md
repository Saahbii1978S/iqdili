# Backup and Restore Feasibility Check — 2026-11-16

## Scope and safety
Read-only inspection of the existing Supabase project and repository branch
`integration/release-candidate-2026-11-15`. No database writes, exports, storage
downloads, account changes, deployments, or production configuration changes were
performed.

## Project facts verified
- Supabase project: `iqdili` (`djzapiwxxuligpdbskfm`), region `eu-west-1`.
- Project status reported by Supabase: `ACTIVE_HEALTHY`.
- PostgreSQL engine: 17 (reported version `17.11.0.011`).
- Supabase migration history contains 28 applied migration records, from
  `20261102161723` through `20261114202111`.
- The repository recovery manifest records migration versions/names, but does
  not contain the complete original SQL for those 28 production migrations.
- The repository's local Supabase config intentionally disables automatic
  migration and seed application. Therefore local startup is not proof of a
  production-equivalent restore.
- Supabase catalog inspection confirmed Auth tables exist; `auth.users` had
  five rows at inspection time. No user row contents were read or copied.
- The project has installed extensions including `pgcrypto`, `pg_net`,
  `pg_cron`, `uuid-ossp`, `pg_stat_statements`, and `vault`. A restore
  target must account for the extensions actually used by the schema.

## Edge Function inventory (read-only, 2026-11-16)
Supabase currently reports 12 deployed Edge Functions, all with status ACTIVE:

| Function | Deployed version | JWT verification |
| --- | ---: | --- |
| ask-iqdili | 49 | off |
| submit-public-post | 8 | off |
| upload-pending-image | 6 | off |
| admin-post-image | 5 | off |
| admin-approve-post | 11 | off |
| admin-delete-post | 10 | off |
| expire-posts | 5 | off |
| my-posts | 4 | off |
| admin-update-post-status | 2 | off |
| delete-account | 4 | on |
| delete-my-post | 6 | on |
| notify-admin-new-user | 1 | on |

The integration branch contains source directories for these 12 functions, plus
`process-storage-cleanup`. That extra worker directory is not present in the
current deployed ACTIVE function inventory; do not mistake source presence for
production deployment. The worker has intentionally not been deployed.
Supabase's deployed function metadata includes source SHA-256 values; a future
recovery check should compare deployed source with repository source and preserve
the exact deployed versions. Secret values were neither requested nor inspected.

## Storage inventory (read-only aggregate, 2026-11-16)
A read-only aggregate over `storage.buckets` and `storage.objects` returned:

| Bucket | Visibility | Objects | Total bytes | Max file size | Allowed types |
| --- | --- | ---: | ---: | ---: | --- |
| listing-images | Public | 0 | 0 | 3 MiB | JPEG, PNG, WebP |
| market-images | Public | 0 | 0 | 3 MiB | JPEG, PNG, WebP |
| pending-images | Private | 5 | 1,587,920 | 3 MiB | JPEG, PNG, WebP |

Only aggregate counts and sizes were queried; object names, paths, and file
contents were not accessed. Counts can change as the app is used, so this is a
point-in-time inventory, not a completed file backup. The five private pending
objects must remain private and untouched; a future export must preserve their
paths and verify checksums without exposing the inventory publicly.

## Backup/restore implications
- Supabase's platform-to-self-hosted guide describes separate role, schema, and
  data exports using `supabase db dump`.
- Supabase CLI's Supabase-specific dump filtering excludes managed schemas,
  including Auth and Storage. Do not assume a normal application schema/data
  dump contains all Auth records or Storage metadata/files. The Auth recovery
  path must be explicitly confirmed using the supported current procedure.
- Storage object bytes are not included in a database dump and must be
  transferred separately. Storage metadata rows alone are not a copy of files.
- Edge Function source, deployed versions, and project-level Auth/provider,
  SMTP, JWT/API-key, redirect, and domain settings require separate handling.
- Existing platform-issued tokens are not portable to a different JWT secret;
  users may need to authenticate again in a restored environment.

References:
- https://supabase.com/docs/guides/self-hosting/restore-from-platform
- https://supabase.com/docs/reference/cli/supabase-db-dump
- https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore

## Current readiness
| Area | Status |
| --- | --- |
| Production migration history inventoried | Verified (28 records) |
| Complete original migration SQL in repository | Missing |
| Local schema reconstruction from migrations | Not ready |
| Actual database roles/schema/data dump | Not performed |
| Auth recovery export and restore verification | Not performed; separate supported path required |
| Storage object files copied and checksummed | Not performed |
| Deployed Edge Functions inventoried | Verified (12 ACTIVE functions) |
| Deployed function source compared/exported for recovery | Not completed |
| Restore drill in an isolated target | Not performed |
| End-to-end recovery proof | Not achieved |

## Safe next actions
1. The project owner obtains authorized database access privately through the
   Supabase Dashboard/approved secret manager. Never paste credentials into
   chat, source files, commits, or workflow logs.
2. From a trusted local environment, create separate roles, schema, and
   application-data dumps with the current Supabase CLI documentation, storing
   outputs outside the public repository and encrypting them at rest.
3. Confirm and execute the supported Auth recovery procedure separately; do
   not mark Auth backed up based only on the ordinary CLI dump.
4. Separately inventory and copy Storage objects from each bucket, preserving
   bucket configuration and object paths; verify counts, byte sizes, and
   SHA-256 checksums. Treat private pending images as private.
5. Export/compare the exact deployed Edge Function source and versions; keep
   secret values out of source control.
6. Restore only into an isolated local/test environment, then compare table,
   function, trigger, policy, extension, Auth, Storage, and row-count
   inventories.
7. Do not declare recovery ready until the isolated restore and file checks
   pass. Do not alter production or publish a new release as part of this work.

## Explicit non-actions
No production migration was applied. No test or production ad was changed.
No storage object was read, deleted, or moved. No credential or password was
requested or accessed. No release, Pages deployment, or PR merge was performed.
