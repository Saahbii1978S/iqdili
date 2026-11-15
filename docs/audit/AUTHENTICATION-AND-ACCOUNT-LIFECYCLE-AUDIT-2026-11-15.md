# Authentication and account lifecycle UI audit — 2026-11-15

Scope: static source review of the audit branch `index.html` and `delete-account.html`, plus the account deletion Edge Function. No live authentication requests, password resets, account changes, or deployments were performed.

## Executive summary

The public account UI implements email/password signup, password login, password-reset email, password update after recovery, and sign-out. Signup requires a minimum of eight password characters in the UI and requests an email confirmation flow when Supabase does not immediately return a session. Password-reset responses are deliberately generic, reducing account-enumeration disclosure.

The account-deletion page does more than a visual confirmation: it calls `signInWithPassword` immediately before invoking the deletion function. This is a useful fresh-credential check in the intended UI flow. However, the Edge Function itself only validates that the bearer token identifies a valid user; it does not enforce a recent `auth_time` or another server-verifiable reauthentication proof. Since Origin is not an authentication boundary, direct callers with a valid session can bypass the UI's password prompt and submit the fixed confirmation value.

## Findings

### AUTH1 — Fresh password check exists in UI but is not enforced by the deletion endpoint (high)

`delete-account.html` reauthenticates with `signInWithPassword({email:user.email,password})` before calling `delete-account`. The Edge Function only calls `/auth/v1/user` to validate the bearer token and accepts `{confirm:"DELETE"}`. A caller can invoke the endpoint directly with a valid access token and the fixed confirmation value without performing the UI password step. The Origin header check does not prevent non-browser callers from supplying that header.

Required remediation: enforce recent authentication at the server boundary, e.g. validate a trusted JWT `auth_time` claim within a short window or require a server-verifiable, short-lived reauthentication proof. Keep the UI password prompt as usability, not the security boundary. Test direct endpoint invocation with an old valid token.

### AUTH2 — No explicit resend-confirmation path was found in the member UI (low/medium)

The signup flow tells users to confirm their email, but the reviewed member controls expose signup, sign-in, and password reset; no resend-signup-confirmation action was found in the inspected source excerpts. Users who lose or expire the confirmation email may need a clearer recovery path.

Required remediation: confirm the project's Supabase email-confirmation settings and add a resend confirmation action if supported and desired. Keep responses generic and rate-limited.

### AUTH3 — Recovery flow relies on Supabase redirect/hash session behavior (medium verification item)

The app routes users to the password-reset UI when the query contains `recovery=1` or the URL hash contains `type=recovery`, then calls `auth.updateUser({password})`. This is a conventional Supabase flow, but it must be tested with actual confirmation and recovery links on the deployed GitHub Pages origin, including expired, reused, and malformed links. Static inspection cannot establish the live redirect allow-list or email template correctness.

### AUTH4 — Password policy is only visibly enforced as eight characters in the UI (medium verification item)

The signup and password-reset forms enforce a minimum of eight characters in client-side JavaScript. The actual server-side Supabase Auth password policy may be stricter or may differ. Confirm the Auth configuration and ensure error handling remains understandable without exposing sensitive provider details.

## Positive controls confirmed

- Signup uses `auth.signUp` and supplies an explicit redirect URL based on the current site.
- Login uses `auth.signInWithPassword`.
- Password-reset request uses `resetPasswordForEmail` and a recovery redirect marker.
- Password update requires matching entries and at least eight characters in the UI, then attempts to sign out.
- Password-reset request displays a generic success-style message whether or not an account exists.
- The deletion page verifies the session with `getUser`, not only the locally cached `getSession` result.
- The deletion UI asks for the current password immediately before invoking the deletion function.
- The deletion Edge Function independently resolves the bearer token to a user and blocks admin/staff accounts.

## Required tests

1. Directly invoke deletion with an old but unexpired access token and `confirm:"DELETE"`; it must fail recent-auth enforcement.
2. Invoke with a freshly reauthenticated token; verify intended behavior without deleting any real account in staging.
3. Test expired/revoked sessions, invalid JWTs, malformed authorization headers, and cross-user attempts.
4. Test signup confirmation, expired confirmation links, resend behavior if enabled, duplicate email, and redirect allow-list.
5. Test password recovery on the actual GitHub Pages origin: valid, expired, reused, malformed, and mismatched password cases.
6. Verify server-side password policy and generic reset responses.
7. Verify logout and session invalidation behavior, including already-issued access tokens.

## Release boundary

Static audit only. No live Auth settings, users, passwords, email templates, redirect URLs, secrets, functions, or deployments were changed. The deletion reauthentication finding is a server-boundary issue; the existing UI password prompt is acknowledged and should be retained.
