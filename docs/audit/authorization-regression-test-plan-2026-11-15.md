# Authorization regression test plan — 2026-11-15

This plan follows the read-only database authorization audit. It is deliberately a test specification, not a production test runner. It must run only against a disposable Supabase project or isolated staging project with synthetic records and dedicated test identities.

## Safety prerequisites

- Never run these tests against the live Ahla Tounsa project.
- Never use real users, real phone numbers, real listings, or existing demo/test rows.
- Use synthetic accounts: anonymous, ordinary authenticated user, moderator, owner.
- Create only synthetic records in staging, label them with a unique test-run prefix, and clean up only those exact synthetic records after evidence is captured.
- Do not use service-role credentials in client-side test code.
- Do not log access tokens, phone numbers, email addresses, or full request headers.
- If staging is not available, stop at static checks; do not simulate by changing live JWT claims or live data.

## Test identities

| Identity | Expected capability |
|---|---|
| Anonymous | Read approved public listings through intended public RPCs; no admin operations; no private pending images |
| Authenticated ordinary user | Same public listing access; no admin operations |
| Moderator | Only explicitly delegated moderation operations; never owner-only user/role management |
| Owner | Owner-only admin functions |

## A. Public listing RPC tests

Run each RPC using anonymous and ordinary authenticated credentials:
- `public_job_posts()`
- `public_market_posts()`
- `public_real_estate_posts()`
- `public_service_requests()`

Seed staging-only rows in each corresponding current table:
1. approved + contact_public=false;
2. approved + contact_public=true;
3. pending;
4. rejected.

Assertions:
- approved rows are returned;
- pending and rejected rows are absent;
- phone is null when contact_public=false;
- phone is returned only for contact_public=true;
- no owner email, moderation metadata, private tokens, or unrelated columns are returned;
- pagination/order remains stable if the RPC contract later adds pagination.

Repeat with no rows and with malformed/empty data where schema permits. Verify that no legacy table rows appear through current public RPCs.

## B. Admin RPC authorization tests

For each RPC, call using anonymous, ordinary authenticated, moderator, and owner credentials:
- `admin_list_status_audit()`
- `admin_list_users()`
- `admin_set_moderator(uuid, boolean)`
- `get_site_visitor_stats()`

Expected:
- anonymous: execution denied by privilege or explicit authorization check;
- ordinary authenticated: authorization failure and no result rows;
- moderator: owner-only operations fail; visitor stats fail unless the role model explicitly intends otherwise;
- owner: expected operation succeeds in staging only.

Additional negative cases for `admin_set_moderator`:
- null target;
- self target;
- nonexistent user;
- owner target;
- repeated grant;
- repeated revoke;
- ordinary user attempting grant/revoke;
- moderator attempting grant/revoke.

Verify no role changes occur after every rejected call. Capture before/after role membership only in staging.

## C. Storage access matrix

Use synthetic objects only:
- one object in private `pending-images`;
- one object in public `listing-images`;
- one object in public `market-images`.

Assertions:
- anonymous GET of pending object fails;
- ordinary authenticated GET of pending object fails unless a specific owner-scoped policy is intentionally present;
- intended public GET of listing/market objects succeeds;
- anonymous upload, overwrite, move, and delete fail;
- ordinary user cannot read or delete another user's pending object;
- owner/admin actions succeed only through the intended server-side flow;
- URL guessing does not bypass private bucket access.

Do not test deletion using any production object URL.

## D. Legacy view and table isolation

Views:
- `jobs_public`
- `market_public`
- `realty_public`
- `services_public`
- `approved_market_posts`

Assertions:
- anonymous and ordinary authenticated SELECT on legacy views fails unless a deliberate base-table grant is introduced later;
- direct SELECT on legacy base tables fails for anon/authenticated;
- legacy rows do not leak through current public listing RPCs;
- no migration or policy is introduced merely to remove an advisor warning.

## E. Visitor tracking abuse tests

Test `record_site_visit()` only in staging:
- missing forwarding header;
- malformed address;
- multiple comma-separated addresses;
- repeated calls from one address;
- calls with changing addresses;
- calls with spoofed forwarding headers at a test proxy boundary;
- unexpected JSON/header formats.

Assertions:
- raw IP is never stored;
- only the keyed digest is persisted;
- no ability to read private visitor tables is granted;
- caller cannot pass an arbitrary visitor UUID through the overload (that overload must remain non-executable by anon/authenticated);
- rate/abuse limits are documented and enforced at an appropriate trusted layer.

Important: database function validation alone cannot prove the gateway's forwarding header is trustworthy. Verify the actual request path and proxy behavior in staging.

## F. Automated checks and evidence

Before enabling these tests in CI:
1. Provide staging URL and public anon key only through protected CI secrets.
2. Provide test-user credentials through protected secrets; never commit them.
3. Use short-lived test identities and rotate credentials after test runs.
4. Run tests against staging only; fail closed if the target project ref is not the approved staging ref.
5. Capture only status codes, assertion names, and synthetic row IDs.
6. Ensure cleanup is scoped to the unique test-run prefix and runs even after test failure.
7. Add a CI guard that rejects production project refs and service-role keys in browser/client test configuration.

Suggested CI suites:
- `public-rpc-privacy`
- `admin-rpc-negative-auth`
- `storage-access-matrix`
- `legacy-view-isolation`
- `visitor-tracking-abuse`

## Current verification status

- Static function definitions and grants inspected on the live project.
- No staging execution has been performed.
- No test users or synthetic records have been created.
- No production data, grants, policies, functions, buckets, or Auth settings were changed.
- Passing static inspection is not equivalent to passing these integration tests.

## Release gate

Do not mark database authorization as fully verified until all suites pass in staging, their logs contain no secrets or personal data, and an independent review confirms that the test target was not production.
