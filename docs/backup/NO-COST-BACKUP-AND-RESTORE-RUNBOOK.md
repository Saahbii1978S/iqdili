# No-cost backup and restore runbook — AHLA TOUNSA

**Status:** procedure prepared; no backup or restore has been executed.
**Target:** Supabase project `djzapiwxxuligpdbskfm` (production).
**Safety boundary:** this document does not authorize production changes, data deletion, migration replay, or restoration over production.

## 1. Current limitations

- The project is on the Free plan. Supabase's current documentation says Free projects do not receive automatic daily database backups or PITR; it recommends regular CLI exports and off-site copies.
- The repository's `.github/workflows/read-only-schema-dump.yml` is an optional schema-only workflow. It requires a private `SUPABASE_DB_URL` GitHub Actions secret and has not been run. Its artifact is not a complete backup.
- The owner has not supplied or confirmed a database connection string. Do not ask them to paste passwords, connection strings, access keys, service-role keys, or tokens into ChatGPT, issues, commits, or logs.
- The repository does not contain all 28 original production migration SQL files. The recovery manifest records names and versions only.
- The local Supabase smoke test proves that local services start; it does not prove that the local schema matches production.
- Supabase CLI database dumps exclude managed schemas such as `auth` and `storage`, plus extension-managed schemas. Storage object files are separate from their database metadata. Auth recovery coverage must therefore be verified separately; do not assume that a normal application schema/data dump is a complete Auth backup.

## 2. Backup components that must be kept separate

A usable recovery set needs all of the following, each timestamped and stored outside the production project:

1. **Application database roles, schema and data** — export separately. The data export may contain sensitive personal information; keep it encrypted and private.
2. **Auth recovery** — confirm which Auth records and settings are included in the chosen supported recovery procedure. A standard CLI dump excludes the managed `auth` schema, so do not mark Auth as backed up based only on `schema.sql` and `data.sql`.
3. **Storage metadata and actual files** — database metadata alone is insufficient. Export each bucket's objects separately, including private `pending-images`.
4. **Project configuration** — Edge Function source, secrets inventory (names only; never secret values), redirect/auth settings, scheduled-job definitions and required extensions. Re-enter secrets securely during recovery; never export their values into Git.
5. **Verification evidence** — record timestamp, CLI version, file sizes, SHA-256 checksums, object counts and byte totals. Keep the inventory private because it can reveal internal object paths.

## 3. CLI v3 database export (project owner only)

Supabase CLI v3 runs database commands against the local stack by default. A remote database target must be explicit. First inspect the installed CLI version and current command help:

```sh
supabase --version
supabase db dump --help
```

After the owner has obtained the database connection string privately from the Supabase Dashboard, they can enter it in their own terminal session without sending it to anyone:

```sh
read -rsp "Database connection string: " SUPABASE_DB_URL
export SUPABASE_DB_URL
printf '\n'
```

Create a protected local directory and export roles, schema and application data as separate files:

```sh
umask 077
BACKUP_DIR="$HOME/ahla-tounsa-backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP_DIR"

supabase db dump --remote="$SUPABASE_DB_URL" --role-only -f "$BACKUP_DIR/roles.sql"
supabase db dump --remote="$SUPABASE_DB_URL" -f "$BACKUP_DIR/schema.sql"
supabase db dump --remote="$SUPABASE_DB_URL" --data-only --use-copy \
  -x "storage.buckets_vectors" -x "storage.vector_indexes" \
  -f "$BACKUP_DIR/data.sql"

sha256sum "$BACKUP_DIR"/*.sql > "$BACKUP_DIR/SHA256SUMS"
ls -lh "$BACKUP_DIR"
```

Important:

- The CLI prints a `Target:` line. Stop if it does not identify the intended production project/database.
- The role, schema and data dumps are still not a complete project backup. Managed Auth/Storage schemas and extension-managed schemas are excluded by the CLI's Supabase-specific filtering.
- The exclusions for `storage.buckets_vectors` and `storage.vector_indexes` follow Supabase's current platform backup/restore guide; review current CLI help before use.
- A data dump may contain personal information. Encrypt it before moving it off the device, restrict access, and never commit it to GitHub or upload it as an ordinary Actions artifact.
- A dump is a read/export operation, but it accesses production data. Run it only with the owner's authorization and from a trusted device/network.
- Do not run `db push`, `db reset --remote`, `migration repair`, or any restore command against production as part of a backup.

When finished, remove the connection string from the current shell:

```sh
unset SUPABASE_DB_URL
```

## 4. Storage object export (project owner only)

Supabase CLI v3 Storage commands target the local stack by default too. For Storage, use the project reference (not the database URL), and include the currently documented `--experimental` flag. First inspect help:

```sh
supabase storage ls --help
supabase storage cp --help
```

The export inventory must include all three existing buckets:

- `pending-images` (private)
- `listing-images` (public)
- `market-images` (public)

Example read/copy commands, to be run only after the owner has authenticated the CLI and confirmed the project reference:

```sh
PROJECT_REF="djzapiwxxuligpdbskfm"
umask 077
STORAGE_DIR="$HOME/ahla-tounsa-storage-backup"
mkdir -p "$STORAGE_DIR"

# List each bucket recursively; keep output private because paths are sensitive.
supabase storage ls "ss:///pending-images" --remote="$PROJECT_REF" --experimental --recursive
supabase storage ls "ss:///listing-images" --remote="$PROJECT_REF" --experimental --recursive
supabase storage ls "ss:///market-images" --remote="$PROJECT_REF" --experimental --recursive

# Copy each bucket to a separate local directory. These are copy operations, not moves.
supabase storage cp -r "ss:///pending-images" "$STORAGE_DIR/pending-images" --remote="$PROJECT_REF" --experimental
supabase storage cp -r "ss:///listing-images" "$STORAGE_DIR/listing-images" --remote="$PROJECT_REF" --experimental
supabase storage cp -r "ss:///market-images" "$STORAGE_DIR/market-images" --remote="$PROJECT_REF" --experimental

find "$STORAGE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum > "$STORAGE_DIR/SHA256SUMS"
```

Before relying on these commands, check the installed CLI's help and test the exact source/destination syntax against a harmless local fixture. Do not use `storage mv` or `storage rm`. Do not change bucket visibility, overwrite remote objects, or delete/move/rename production objects during backup. Keep the five already-known pending objects untouched. Verify local file counts and total byte sizes against a fresh read-only metadata inventory; do not publish object paths or private file contents.

If using the Dashboard instead, it supports individual object downloads. S3-compatible bulk download is another documented option, but it requires enabling S3 protocol and creating access credentials; do not enable or generate those credentials as part of this task without explicit owner approval.

## 5. Restore drill — isolated environment only

Do not create a paid Supabase project or branch for this task. A restore drill remains blocked until a suitable isolated, no-cost target and its limitations are confirmed.

Before any restore:

1. Confirm the target is isolated and contains no production users or data.
2. Verify the backup files are non-empty, checksums pass, and sensitive files are encrypted.
3. Read the current Supabase restore guide. Inspect target default privileges before importing; Supabase warns that default privileges on the target can affect restored table permissions.
4. Confirm required extensions and project settings on the target.
5. Restore roles and schema first, then approved application data, using the current official restore procedure.
6. Recover Auth and Storage separately using supported procedures; do not treat an SQL import as proof that Auth or object files were recovered.
7. Recreate project configuration and Edge Functions without copying secret values into source control.
8. Compare tables/columns, constraints, indexes, functions, triggers, RLS policies, grants, bucket settings, object counts and representative file retrieval.
9. Run application tests only against the isolated target. Never point the live site at the test database.

A successful SQL import alone is not proof of a successful restore. Record what was and was not recovered, the restore duration, and any missing components. Never restore over production as part of a drill.

## 6. Current completion checklist

- [x] Read-only production metadata audit completed.
- [x] Migration version/name recovery manifest preserved.
- [x] CLI v3 target behavior and database/Storage export scope checked against current Supabase documentation.
- [x] No-cost runbook documented in the integration branch.
- [ ] Owner-authorized database roles/schema export.
- [ ] Owner-approved application data export, encrypted and stored off-project.
- [ ] Auth recovery export/backup and verification.
- [ ] Storage objects export for all three buckets.
- [ ] Checksums and private export inventory recorded.
- [ ] Isolated restore target approved and available without additional cost.
- [ ] Restore drill and application verification completed.

**Release statement:** until the unchecked items are completed and a restore drill passes, AHLA TOUNSA must be described as having a documented backup plan, not a verified backup or disaster-recovery capability.

## Official references

- Supabase database backups: https://supabase.com/docs/guides/platform/backups
- Supabase CLI v3 migration guide: https://supabase.com/docs/guides/local-development/cli/migrating-to-v3
- Supabase CLI database dump reference: https://supabase.com/docs/reference/cli/supabase-db-dump
- Supabase backup and restore using CLI: https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore
- Supabase Storage download objects: https://supabase.com/docs/guides/storage/management/download-objects
- Supabase CLI Storage copy reference: https://supabase.com/docs/reference/cli/supabase-storage-cp
