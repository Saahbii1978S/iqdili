# Main-based Storage cleanup integration status

Date: 2026-11-19

## Base and scope
This integration branch starts from the current `main` head, not the older PR48 base. It carries the non-conflicting Storage cleanup infrastructure from PR48:
- shared cleanup queue, worker, request-size, recent-authentication, protected-demo, and Storage HEAD helpers with unit tests;
- the candidate cleanup worker Edge Function and the expiry-cleanup candidate;
- five re-versioned migrations ordered after the production baseline `20261119093408`;
- SQL regression, Storage policy, and concurrency test assets;
- staging/runbook/audit documentation and CI workflows.

The five candidate migrations are:
1. `20261120090000_storage_cleanup_jobs.sql`
2. `20261120090500_storage_cleanup_attachment_lock.sql`
3. `20261120091000_storage_cleanup_detachment_lock.sql`
4. `20261120091500_storage_cleanup_atomic_defer.sql`
5. `20261120092000_account_deletion_limits.sql`

## Deliberately not ported yet
Current `main` has changes on 12 paths also changed by PR48: `privacy.html` and 11 Edge Function source files. Those files were intentionally left at current-main versions in this branch. PR48 contains additional queue integration, bounded request parsing, recent-authentication, protected-demo, and signup-notification retry behavior in several of these functions. Those changes must be reconciled function by function against current-main sources before they are considered integrated.

PR60's unique Android activity and download page already match current `main` exactly; its `index.html` is older than current `main` and was not copied.

## Safety gates
- This branch is a review/integration candidate only.
- No migration was applied to production or staging.
- No Edge Function was deployed.
- No Storage object, listing, account, or production setting was changed.
- Do not deploy `process-storage-cleanup` or apply candidate migrations until the function integrations are complete, CI passes on this branch, an isolated staging validation succeeds, and separate explicit approval is given.

## Current status
Infrastructure and tests are staged on the current-main base. Runtime integration into the existing public/admin/delete/signup Edge Functions remains incomplete. This branch must remain Draft and must not be treated as release-ready.
