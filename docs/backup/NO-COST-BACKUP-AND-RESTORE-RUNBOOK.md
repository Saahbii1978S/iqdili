# No-cost backup and restore runbook — AHLA TOUNSA

**Status:** procedure prepared; no backup or restore has been executed.
**Target:** Supabase project `djzapiwxxuligpdbskfm` (production).
**Safety boundary:** this document does not authorize production changes, data deletion, migration replay, or restoration over production.

## 1. Current limitations

- The project is on the Free plan. Supabase documents that Free projects should export data regularly with the CLI; automatic daily backups and Point-in-Time Recovery are not included on this plan.
- The repository's `.github/workflows/read-only-schema-dump.yml` is an optional schema-only workflow. It requires a private `SUPABASE_DB_URL` GitHub Actions secret and has not been run. Its artifact is not a complete backup.
- The owner has not supplied or confirmed a database connection string. Do not ask them to paste passwords, connection strings, access keys, service-role keys, or tokens into ChatGPT, issues, commits, or logs.
- The repository does not contain all 28 original production migration SQL files. The recovery manifest records names and versions only.
- The local Supabase smoke test proves that local services start; it does not prove that the local schema matches production.
- Database dumps do not include Supabase-managed Auth and Storage schemas. Storage object files are separate from their database metadata.

## 2. Backup components that must be kept separate

A usable recovery set needs all of the following, each timestamped and stored outside the production project:

1. **Application database schema** — tables, views, functions, triggers, indexes, constraints, RLS policies, grants and relevant configuration.
2. **Application database data** — only after the owner chooses and approves the scope. Treat this as sensitive personal data; do not place it in a public repository or ordinary CI artifact.
3. **Auth recovery material** — use the supported Supabase export/backup procedure for the project's Auth data. A normal `supabase db dump` excludes the managed `auth` schema, so it is not an Auth backup.
4. **Storage metadata and actual files** — database metadata alone is insufficient. Export each bucket's objects separately, including private `pending-images`. Keep bucket names, visibility and MIME/size configuration documented.
5. **Project configuration** — Edge Function source, secrets inventory (names only; never secret values), redirect/auth settings, scheduled-job definitions and required extensions. Re-enter secrets securely during recovery; never export their values into Git.

## 3. CLI v3 command reference (run only by the project owner)

Supabase CLI v3 targets the local stack by default. Use the explicit remote target for production exports. First inspect the installed CLI version and command help:

```sh
supabase --version
supabase db dump --help
```

After the owner has obtained the database connection string privately from the Supabase Dashboard, they can set it in their own terminal session without sending it to anyone:

```sh
read -rsp "Database connection string: " SUPABASE_DB_URL
export SUPABASE_DB_URL
printf '\\n'
```

Create a protected local directory and export schema and application data as separate files:

```sh
umask 077
mkdir -p "$HOME/ahla-tounsa-backups"
supabase db dump --remote="$SUPABASE_DB_URL" -f "$HOME/ahla-tounsa-backups/schema.sql"
supabase db dump --remote="$SUPABASE_DB_URL" --data-only --use-copy -f "$HOME/ahla-tounsa-backups/data.sql"
```

Important:
- Review the CLI's current help and Supabase's current backup guide before running; CLI flags can change.
- The schema dump excludes Supabase-managed schemas such as Auth and Storage, plus extension-managed schemas.
- The data dump is not a substitute for Auth export or Storage object export.
- The data file may contain personal information. Encrypt it before moving it off the device, restrict access, and never commit it to GitHub or upload it as an ordinary Actions artifact.
- A dump command is a read/export operation, but it still accesses production data. Run it only with the owner's authorization and from a trusted device/network.
- Do not run `db push`, `db reset --remote`, `migration repair`, or any restore command against production as part of a backup.

When finished, remove the connection string from the current shell:

```sh
unset SUPABASE_DB_URL
```

## 4. Storage object export

Supabase documents Dashboard downloads for individual objects, Supabase CLI Storage copy commands, and S3-compatible clients for bulk downloads. The S3 protocol must be enabled in Storage configuration and its access key/secret are shown only once.

For this project, the export inventory must include all three existing buckets:
- `pending-images` (private)
- `listing-images` (public)
- `market-images` (public)

Do not change bucket visibility or delete, move, rename, or overwrite objects during backup. Keep the five already-known pending objects untouched. Verify exported file counts and total byte sizes against a fresh metadata inventory, without publishing object paths or private file contents.

## 5. Restore drill — isolated environment only

Do not create a paid Supabase project or branch for this task. A restore drill remains blocked until a suitable isolated, no-cost target and its limitations are confirmed.

Before any restore:
1. Confirm the target is isolated and contains no production users or data.
2. Verify the backup files are non-empty, encrypted where appropriate, and accompanied by checksums.
3. Read the current Supabase restore guide and inspect the target's default privileges before importing. Supabase warns that default privileges on the target can affect restored table permissions.
4. Restore schema first, then approved application data, then separately restore the required Auth and Storage components using supported procedures.
5. Recreate required project configuration and Edge Functions without copying secret values into source control.
6. Compare tables/columns, constraints, indexes, functions, triggers, RLS policies, grants, bucket settings, object counts and representative file retrieval.
7. Run application tests only against the isolated target. Never point the live site at the test database.

A successful SQL import alone is not proof of a successful restore. Record what was and was not recovered, the restore duration, and any missing components.

## 6. Current completion checklist

- [x] Read-only production metadata audit completed.
- [x] Migration version/name recovery manifest preserved.
- [x] CLI v3 behavior and backup scope checked against current Supabase documentation.
- [x] No-cost runbook documented in the integration branch.
- [ ] Owner-authorized database schema export.
- [ ] Owner-approved application data export, encrypted and stored off-project.
- [ ] Auth export/backup.
- [ ] Storage objects export for all three buckets.
- [ ] Checksums and export inventory recorded.
- [ ] Isolated restore target approved and available without additional cost.
- [ ] Restore drill and application verification completed.

**Release statement:** until the unchecked items are completed and a restore drill passes, AHLA TOUNSA must be described as having a documented backup plan, not a verified backup or disaster-recovery capability.

## Official references

- Supabase database backups: https://supabase.com/docs/guides/platform/backups
- Supabase CLI v3 migration guide: https://supabase.com/docs/guides/local-development/cli/migrating-to-v3
- Supabase CLI reference: https://supabase.com/docs/reference/cli/introduction
- Download Storage objects: https://supabase.com/docs/guides/storage/management/download-objects
- Supabase Storage S3 compatibility: https://supabase.com/docs/guides/storage/s3/compatibility
