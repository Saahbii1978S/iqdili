# User-data relationship inventory — 2026-11-15

Scope: read-only inspection of the linked Supabase project's public table metadata and PostgreSQL foreign-key definitions. No rows were read from legacy content tables, and no schema/data/auth/storage changes were made.

## Executive summary

The four current listing tables all reference `auth.users(id)` with `ON DELETE SET NULL`, not CASCADE. The account-deletion Edge Function explicitly deletes these rows before deleting the Auth user. This means the explicit application cleanup is essential: deleting only the Auth user would leave listing rows in place with `user_id = NULL`.

The legacy tables `jobs`, `services`, `market`, `realty`, and `properties` have no `user_id` column and no FK to `auth.users` in the inspected schema. Their records cannot currently be reliably attributed to an account through relational ownership. This inventory did not read their row contents.

## Public-schema inventory

### Current user-linked content

| Table | User FK | ON DELETE | Account deletion behavior |
|---|---|---|---|
| service_requests | user_id → auth.users.id | SET NULL | Explicit row deletion required |
| job_posts | user_id → auth.users.id | SET NULL | Explicit row deletion required |
| real_estate_posts | user_id → auth.users.id | SET NULL | Explicit row deletion required |
| market_posts | user_id → auth.users.id | SET NULL | Explicit row deletion required |
| admins | user_id → auth.users.id | CASCADE | Protected by endpoint before deletion |
| staff_roles | user_id → auth.users.id | CASCADE | Protected by endpoint before deletion |
| staff_roles | granted_by → auth.users.id | SET NULL | Granting actor reference retained as null |
| admin_role_events | actor_id → auth.users.id | SET NULL | Event retained; actor reference becomes null |
| admin_role_events | target_user_id → auth.users.id | SET NULL | Event retained; target reference becomes null |
| admin_status_audit | actor_id → auth.users.id | SET NULL | Event retained; actor reference becomes null |

### Tables without account ownership relation

The following legacy tables were present without a `user_id` column or FK to `auth.users`: `jobs`, `services`, `market`, `realty`, `properties`. Their records should not be automatically deleted as part of account deletion because ownership cannot be established from the inspected schema. Their existing contents were not inspected or changed.

### Notification events

`admin_notification_events` contains `user_id` and `event_type` columns but the inspected schema reports no FK from `user_id` to `auth.users`. Its rows can therefore outlive a deleted Auth user unless explicitly cleaned or retained under a documented audit/retention policy. The table currently has a small number of rows; row contents were not read.

### Supabase Auth-owned relations

The inspected Auth schema shows user-owned identities, MFA factors/recovery data, sessions, OAuth authorizations/consents, one-time tokens, and WebAuthn credentials linked to `auth.users` with `ON DELETE CASCADE`. These are managed by Supabase Auth and should not be manually deleted by the application function.

## Consequences and required decisions

1. Keep explicit deletion of the four current listing tables; do not rely on FK cascade.
2. Define whether `admin_notification_events` should be deleted on account erasure or retained in minimized form for operational deduplication. If retained, document retention and avoid storing unnecessary identifiers.
3. Preserve admin audit events while allowing actor/target references to become null, if this matches the platform's audit policy.
4. Do not delete legacy rows without a trustworthy ownership mapping. If legacy ownership is ever needed, design a migration and verified mapping separately.
5. Ensure any durable account-deletion outbox is independent of the Auth user's lifecycle, so retries continue after the Auth user is deleted.
6. Verify token/session revocation behavior for sensitive operations; deleting Auth rows cascades sessions, but already-issued JWTs may remain cryptographically valid until expiry unless the application checks session state.

## Verification boundary

The metadata came from read-only table and catalog inspection. Current content row counts were observed only where returned by the table metadata listing. Legacy row contents, admin identities, user emails, and event payloads were not queried. No SQL mutation, migration, deployment, or Storage operation was performed.
