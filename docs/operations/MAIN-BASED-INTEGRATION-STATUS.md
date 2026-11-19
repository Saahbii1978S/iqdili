# Main-based Storage cleanup integration status

Date: 2026-11-19

## Base and scope
This integration branch starts from the current `main` head. It carries the Storage cleanup infrastructure, helper modules and tests, candidate worker/expiry functions, five re-versioned candidate migrations, SQL/concurrency regression assets, runbooks, and CI workflows.

The five candidate migrations, ordered after production baseline `20261119093408`, are:
1. `20261120090000_storage_cleanup_jobs.sql`
2. `20261120090500_storage_cleanup_attachment_lock.sql`
3. `20261120091000_storage_cleanup_detachment_lock.sql`
4. `20261120091500_storage_cleanup_atomic_defer.sql`
5. `20261120092000_account_deletion_limits.sql`

## Runtime reconciliation on current main
The seven overlapping Edge Function sources requiring substantive integration have been reconciled on top of current `main`:
- `admin-approve-post`: bounded input, admin authorization, path validation, staged cleanup, unique public image copies, and atomic reviewed-row approval.
- `admin-update-post-status`: admin authorization, bounded input, protected-demo checks, staged cleanup, and atomic status transition.
- `admin-delete-post` and `delete-my-post`: authorization/ownership and protected-demo checks, bounded input, durable cleanup queue, and atomic deletion against the reviewed row snapshot.
- `delete-account`: recent-authentication and rate-limit checks, protected-demo checks, bounded listing count, persistent deletion lock, durable cleanup, and atomic listing deletion before Auth deletion.
- `submit-public-post`: if insert outcome is uncertain after image upload, schedule reference-aware cleanup rather than directly deleting a potentially committed listing image.
- `notify-admin-new-user`: release the deduplication event when notification delivery fails or throws so a retry can occur.

Other overlapping paths were reconciled without replacing newer current-main behavior: `ask-iqdili` and `upload-pending-image` match the imported source; `admin-post-image` and `my-posts` differ only in formatting; `privacy.html` remains the newer current-main version. PR60's Android activity and download page match current main; its older index page was not copied.

## CI evidence
For code-bearing PR commit `995e2d03052bd6c845bb96ae4ee2b8255e82db65` (the three later commits changed only these two operations documents; no application, Edge Function, migration, or test source changed):
- [Edge Function source contract checks, run #48](https://github.com/ahla-tounsa-project/iqdili/actions/runs/44520501405): TypeScript integration type-check and source-contract checks passed.
- [Supabase reliability regression tests, run #82](https://github.com/ahla-tounsa-project/iqdili/actions/runs/44520501395): shared helper tests, PostgreSQL queue/permissions/Storage policy tests, and concurrent attachment/cleanup race tests passed.

The immediately preceding migration test failure exposed a duplicated SQL tail and invalid syntax in the candidate migration. The duplicate tail was removed on this PR branch; the current head above passed both workflows.

## Review findings and remaining validation
- The candidate source and SQL were reviewed for the intended authorization, ownership, protected-demo, queue leasing, object-path validation, attachment/detachment locking, and retry invariants.
- This was a source-level review, not an independent external security review. PR currently has no independent review submissions or inline review threads.
- CI uses disposable PostgreSQL and mocked/injected worker dependencies. It does not prove end-to-end behavior against a live Supabase Storage service, real scheduler, network failures, or alert delivery.
- Isolated staging validation and independent review remain required. Verify all migration behavior, worker authentication, live Storage HEAD/DELETE behavior, retry recovery, and alerting with disposable staging-only objects and accounts.

## Safety gates
- Draft only; not release-ready.
- No migration was applied to production or staging.
- No Edge Function was deployed.
- No Storage object, listing, account, or production setting was changed.
- Do not deploy `process-storage-cleanup` or apply candidate migrations until independent review, isolated staging validation, an approved rollout/rollback plan, and separate explicit owner approval are complete.
