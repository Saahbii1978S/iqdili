# Admin and moderator authorization audit — 2026-11-15

Scope: read-only inspection of live Supabase function definitions, database function definitions/ACLs, RLS policies/table grants, triggers, and the current `index.html` admin UI. No production data, users, roles, grants, policies, functions, or settings were changed.

## Executive summary

The core role separation is present and is enforced server-side, not only by hiding UI elements:

- `is_owner()` is true only for a user in `public.admins`.
- `is_admin()` is true for an owner or a user with `staff_roles.role = 'moderator'`.
- Owner-only role management and audit-list RPCs call `is_owner()` internally.
- Moderator-facing listing/review endpoints call `is_admin()`.
- Permanent post deletion calls `is_owner()`.
- The owner cannot grant/revoke their own moderator role through `admin_set_moderator`, and accounts in `admins` are protected from moderator assignment.

No direct authenticated UPDATE grant was found on the four current listing tables; authenticated users have SELECT, while service_role has the write privileges. Thus the RLS UPDATE policies do not, by themselves, let a moderator directly update rows through PostgREST without the required table grant.

## Confirmed role model

### Database functions

- `is_admin()`: SECURITY DEFINER, empty search_path; checks `admins.user_id = auth.uid()` OR `staff_roles.user_id = auth.uid()` with role `moderator`.
- `is_owner()`: SECURITY DEFINER, empty search_path; checks only `admins.user_id = auth.uid()`.
- Both are executable by authenticated and not anon.

### Owner-only management RPCs

- `admin_set_moderator(uuid, boolean)`: calls `is_owner()`; rejects null target, self-target, nonexistent users, and any user already in `admins`. Grant/revoke plus the corresponding `admin_role_events` insert occur in one database function transaction. The role table primary key enforces one role row per user; its CHECK constraint permits only `moderator`.
- `admin_list_users()`: calls `is_owner()`; returns registered user IDs, emails, creation/last-sign-in timestamps and moderator status.
- `admin_list_status_audit()`: calls `is_owner()`; returns the latest 100 listing-status audit rows, including actor email.
- All three are SECURITY DEFINER with empty search_path, executable by authenticated but guarded in their function bodies; anon execution is false.

### Edge Function access matrix

| Operation | Server-side authorization |
|---|---|
| Review / approve listing | `is_admin()` |
| Reject / unpublish listing | `is_admin()` |
| View private pending-image preview | `is_admin()` |
| Permanently delete listing | `is_owner()` |
| Manage moderator roles | `is_owner()` |
| List registered users / view status audit | `is_owner()` |

The frontend also hides user/role management from moderators and does not render permanent-delete controls for them. These UI checks are supplementary; the database/Edge Function checks are the actual security boundary.

## RLS and grants observed

- `admins`, `staff_roles`, `admin_role_events`, and `admin_status_audit` have RLS enabled and no policies.
- No anon/authenticated table-level SELECT/INSERT/UPDATE/DELETE grants were found for those role/audit tables. Service-role access is present.
- `admin_role_events` and `admin_status_audit` are not directly readable by anon/authenticated.
- On the four current listing tables, authenticated has SELECT and no UPDATE grant; service_role has write privileges. SELECT policies use `is_admin()`.
- The four listing tables each have a status-audit trigger invoking `log_admin_status_change()`.

## Findings and hardening opportunities

### M1 — Moderator can read full listing rows, including contact fields (privacy / least privilege)

The SELECT policy on each current listing table is `is_admin()`, which includes moderators. The admin dashboard queries `select("*")` and renders the listing phone number. Therefore any appointed moderator can read the full listing row, including phone/contact fields and any other columns in the row, not merely the fields needed for a moderation decision.

This may be an intentional operational choice, but it should be explicitly approved. If moderators do not need contact details, use a restricted moderation view/RPC or column-level grants and avoid `select("*")`. Test that the owner retains the required contact access while moderators see only approved moderation fields.

### M2 — Moderator-role audit exists but has no owner-facing history reader

`admin_set_moderator` writes grant/revoke events to `admin_role_events`, but no owner-only RPC or UI reader for that table was found. The role changes are recorded but not conveniently reviewable from the dashboard. Add an owner-only, bounded audit reader before relying on this table as an operational audit trail. Do not expose it directly to authenticated users.

### M3 — User list is unpaginated

`admin_list_users()` returns every row from `auth.users` in one call. It is owner-only, but can become slow or large as registrations grow. Add bounded pagination/search and return only fields the owner actually needs. Avoid exposing last-sign-in metadata if it is not operationally necessary.

### M4 — Status audit only records changes with a user JWT

`log_admin_status_change()` inserts an audit row only when `auth.uid()` is not null. Current browser-driven admin status changes pass the user access token and should be attributable. Any future service-role-only status mutation without a user JWT will not be represented in this audit table. Keep this limitation documented or provide an explicit trusted actor field for system actions.

## Additional checks required in staging

1. Anonymous and ordinary user cannot execute any owner/admin RPC successfully.
2. Moderator can review/approve/reject/unpublish only; direct PostgREST INSERT/UPDATE/DELETE against all four listing tables fails.
3. Moderator cannot grant/revoke roles, list registered users, inspect owner audit, or delete listings.
4. Owner can grant/revoke a moderator; failed operations leave both `staff_roles` and `admin_role_events` unchanged.
5. Owner cannot alter own role; moderator cannot alter owner role; deleted/nonexistent target is rejected.
6. Role grant/revoke event and role change are atomic under a forced audit insert failure.
7. Verify exact moderator visibility of contact fields and agree on the privacy policy before production use.
8. Verify status audit records the correct actor for each browser-driven moderation endpoint.
9. Test large user-list behavior and pagination before account volume grows.

## Release boundary

This is a documentation-only audit. No live change was made. No role was assigned or revoked, no user email or account details were copied into this report, and no production data was modified. Do not change grants, policies, functions, or roles without a separate review and explicit approval.
