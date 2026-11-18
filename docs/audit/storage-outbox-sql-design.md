# Storage cleanup outbox — SQL design notes (NON-EXECUTABLE)

**Status:** review material only. This is deliberately a Markdown document, not a Supabase migration.
**Do not paste this into production SQL Editor.** Exact source-table column definitions and ownership rules must be verified before writing the transactional deletion RPC.

## 1. Design decisions still requiring verification

Before implementing source deletion RPCs, inspect the live definitions of:
- `service_requests`
- `job_posts`
- `real_estate_posts`
- `market_posts`
- legacy `services` and `jobs` (do not migrate or delete their rows as part of this work)

For each table, verify primary-key type, owner column, image field format, status field, and whether image paths are stored as object keys or URLs. The live legacy row titled “نجار” is unidentified and must be preserved. Existing pending Storage objects must also be preserved.

## 2. Proposed private task table

The following is a schema sketch, not a migration:

```sql
create schema if not exists private;

create table private.storage_cleanup_outbox (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  bucket_id text not null,
  object_path text not null,
  source_table text not null,
  source_record_id text not null,
  reason text not null check (
    reason in ('listing_delete', 'account_delete', 'approval_compensation')
  ),
  status text not null default 'pending' check (
    status in ('pending', 'processing', 'retry', 'completed', 'dead')
  ),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  lock_token uuid,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint storage_cleanup_bucket_allowlist check (
    bucket_id in ('listing-images', 'market-images', 'pending-images')
  ),
  constraint storage_cleanup_path_shape check (
    object_path <> ''
    and object_path !~ '(^/|//|\\\\|(^|/)\\.\\.?(/|$)|[?#])'
  )
);
```

The path-shape check above is only a coarse database guard. The authoritative validator must also enforce the bucket-specific first path segment and supported image extensions. Do not treat this sketch as a complete path-security implementation.

## 3. Indexes and row security

Proposed index shapes:

```sql
create index storage_cleanup_due_idx
  on private.storage_cleanup_outbox (next_attempt_at, created_at)
  where status in ('pending', 'retry');

create index storage_cleanup_expired_lease_idx
  on private.storage_cleanup_outbox (locked_until)
  where status = 'processing';
```

Security requirements to validate against the actual Supabase role model:

- Keep `private` outside exposed API schemas.
- Enable RLS on the table.
- Revoke table privileges from PUBLIC, anon, and authenticated.
- Do not create frontend policies.
- Grant only the minimum required access to a dedicated server-side worker/database operation.
- Verify effective privileges, schema usage, function EXECUTE grants, and Supabase advisors after implementation.

Do not assume that placing a table in a schema named `private` alone makes it secure.

## 4. Transaction boundary

A deletion RPC must perform all of the following in one PostgreSQL transaction:

1. Resolve and verify the authenticated owner or administrator.
2. Select the exact source row with a row lock.
3. Extract and validate all eligible object keys.
4. Insert one durable cleanup task per distinct object key.
5. Delete the source row.
6. Return only after the transaction commits.

If any step fails, the transaction must roll back. Do not implement this as separate Edge Function REST calls.

Do not write a generic RPC that accepts arbitrary table names. Use separate, narrowly scoped operations or a carefully reviewed internal helper with fixed allowlisted table mappings. Do not use user-supplied bucket names or object paths.

## 5. Claim operation shape

A worker claim operation should use a short transaction and `FOR UPDATE SKIP LOCKED`. Conceptual query only:

```sql
with candidates as (
  select id
  from private.storage_cleanup_outbox
  where (
    status in ('pending', 'retry')
    and next_attempt_at <= now()
  ) or (
    status = 'processing'
    and locked_until < now()
  )
  order by next_attempt_at, created_at
  for update skip locked
  limit 25
)
update private.storage_cleanup_outbox as task
set status = 'processing',
    lock_token = gen_random_uuid(),
    locked_until = now() + interval '2 minutes',
    updated_at = now()
from candidates
where task.id = candidates.id
returning task.id, task.bucket_id, task.object_path,
          task.attempt_count, task.lock_token;
```

Production implementation must also:
- return only the fields needed by the worker;
- bind each transition to the exact lock token;
- enforce a maximum batch and lease duration;
- prevent unauthorized callers from invoking the claim operation;
- decide how to handle tasks whose previous lease expired;
- use a monotonic attempt policy and bounded retry schedule.

## 6. Completion and retry transitions

Every update must match both task ID and current lock token. A stale worker must update zero rows.

- Success / confirmed object-not-found: completed, set completed_at, clear lease and token.
- Transient error: retry, increment attempt_count, set next_attempt_at, clear lease and token, save a sanitized error category.
- Permanent invalid target / exhausted attempts: dead, clear lease and token, retain task and alert an administrator.

Never store credentials, signed URLs, raw provider payloads, or unsanitized exception text in last_error_code.

## 7. Idempotency key decision

Do not use only `bucket_id + object_path` as a permanent unique key without considering object recreation. A future listing may legitimately reuse the same object key. Prefer a deterministic key scoped to a source operation instance (for example source table + source record + deletion event UUID + object key digest). Keep completed task history. Confirm whether the source schema has a stable deletion-event identifier before finalizing this.

## 8. Explicit non-goals

This document does not:
- create or apply a migration;
- change any live table, function, policy, role, extension, schedule, or secret;
- delete, copy, or reconcile Storage objects;
- modify listing status or publish test data;
- authorize deployment of the existing audit branch.
