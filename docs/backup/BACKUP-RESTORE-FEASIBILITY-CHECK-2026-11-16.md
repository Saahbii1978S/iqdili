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

## Backup/restore implications from current Supabase documentation
- Supabase's platform-to-self-hosted restore guide documents separate dumps
  for roles, schema, and data using `supabase db dump`.
- The guide states the database dump includes schema, data, roles, RLS
  policies, functions, triggers, and `auth.users` plus related database data.
- Storage object bytes are not included in the database dump and must be
  transferred separately. Storage metadata rows alone are not a copy of files.
- Edge Functions and project-level Auth/provider, SMTP, JWT/API-key, redirect,
  and domain settings require separate handling/configuration.
- Existing platform-issued tokens are not portable to a different JWT secret;
  users may need to authenticate again in a restored environment.

Reference: https://supabase.com/docs/guides/self-hosting/restore-from-platform

## Current readiness
| Area | Status |
| --- | --- |
| Production migration history inventoried | Verified (28 records) |
| Complete original migration SQL in repository | Missing |
| Local schema reconstruction from migrations | Not ready |
| Actual database roles/schema/data dump | Not performed |
| Auth database data included in documented DB dump process | Documented; not exported or restore-tested |
| Storage object files copied and checksummed | Not performed |
| Edge Functions inventory/export/restore validation | Not completed in this check |
| Restore drill in an isolated target | Not performed |
| End-to-end recovery proof | Not achieved |

## Safe next actions
1. Obtain an authorized database connection through the project owner's
   Supabase Dashboard/approved secret manager; never paste credentials into
   chat, source files, or workflow logs.
2. From a trusted local environment, create separate roles, schema, and data
   dumps with the current Supabase CLI documentation, storing outputs outside
   the public repository and encrypting them at rest.
3. Separately inventory and copy Storage objects from each bucket, preserving
   bucket configuration and object paths; verify counts, byte sizes, and
   SHA-256 checksums. Treat private pending images as private.
4. Inventory Edge Functions and project-level Auth/SMTP settings without
   exposing secrets.
5. Restore only into an isolated local/test environment, then compare table,
   function, trigger, policy, extension, and row-count inventories.
6. Do not declare recovery ready until the isolated restore and file checks
   pass. Do not alter production or publish a new release as part of this work.

## Explicit non-actions
No production migration was applied. No test or production ad was changed.
No storage object was read, deleted, or moved. No credential or password was
requested or accessed. No release, Pages deployment, or PR merge was performed.
