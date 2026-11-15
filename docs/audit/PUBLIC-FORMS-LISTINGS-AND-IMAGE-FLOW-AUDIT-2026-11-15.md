# Public forms, listing rendering and image-flow audit — 2026-11-15

Scope: static review of the audit-branch frontend `index.html` and the preserved Edge Function snapshots `submit-public-post`, `upload-pending-image`, `admin-post-image`, and `admin-approve-post`. No public form was submitted, no image was uploaded, no listing was approved or changed, and no live data was modified.

## Confirmed positive controls

- The four public listing forms map to a fixed allow-list of database tables; the server independently validates the table name.
- The server bounds request bodies (4 MB multipart, 20 KB JSON) and parses multipart data only after the bounded read.
- Turnstile is verified server-side, including success and the expected hostname.
- The server independently validates required text fields, lengths, phone digit count, category-specific fields, numeric fields, and image paths.
- Uploaded images are limited to JPEG/PNG/WebP, checked against file signatures, size-limited, and stored in the private `pending-images` bucket.
- Client-side image preparation rasterizes the selected image to WebP, caps dimensions, and attempts compression before upload. This also avoids forwarding original image metadata in the normal browser path.
- Public listing renderers HTML-escape database-controlled text before inserting it into HTML. Image paths are restricted to expected category folders and image extensions before URL construction.
- Public listing queries use the approved-only RPC functions; the frontend does not directly select all pending records for public display.
- Admin image previews are loaded through a server function which verifies an authenticated administrator and creates a short-lived signed URL, rather than exposing the private pending bucket.
- Search filters operate on rendered text and category/region fields; empty-result messages are created with `textContent`.

## Findings and verification items

### FORM1 — Text-only submission IP rate limiting not established by the reviewed handler (medium; verify database controls)

The reviewed `submit-public-post` handler invokes `consume_pending_image_rate_limit` in the image-upload branch. No separate IP-based submission rate-limit call was found in this handler for text-only submissions. The handler does validate phone number shape, but that alone is not proof of an effective abuse limit. There may be database triggers or constraints that add controls; their current behavior must be inspected before concluding the endpoint is unprotected.

Action: inspect all relevant table triggers/functions and any per-phone throttling implementation, then test repeated text-only submissions in staging. Do not add or change live rate limits until the current database behavior and user impact are understood.

### FORM2 — Frontend and server field limits are not identical (low)

The frontend applies a 100-character title limit and a 1,400-character service description limit, while the server accepts titles up to 120 and service descriptions up to 1,600. This is not a server bypass because the server remains the authority, but the mismatch can confuse users who submit through another client or an older cached frontend.

Action: define one documented limit per field and align UI counters, HTML maxlength values, and server validation. Check all form fields against server limits before changing production behavior.

### IMG1 — Upload-before-insert can still leave orphan pending images on exceptional paths (medium; reliability)

The handler uploads a file into `pending-images` before inserting the listing row. It attempts to delete that object if the database insert fails, but a process termination or network failure between successful upload and insert/compensation can leave an unreferenced object. The existing storage cleanup/outbox audit already identifies this general orphan-object problem.

Action: use a durable cleanup/outbox design with reconciliation for unreferenced pending objects; do not run broad bucket cleanup or delete existing objects as part of this audit.

### IMG2 — Admin image preview assumes image objects are in the private pending bucket (medium; compatibility check)

`admin-post-image` signs a URL from `pending-images` for every listing row. The current submission and approval flow supports that lifecycle: submissions write to the private bucket, and approval copies the image to its public destination while retaining the source. If older or manually migrated rows point only to a public bucket, their admin preview will fail even though the public image may exist.

Action: verify actual row-path conventions without exposing personal data, and if legacy public-only rows exist, support a strict table-to-bucket mapping in the preview function. Do not broaden bucket access or accept client-supplied bucket names.

### IMG3 — Client preview accepts any browser-reported image MIME before the server's stricter allow-list (low)

The local preview checks only that the browser-reported MIME starts with `image/`. The actual submission preparation and server validation narrow this to supported raster formats, so this is primarily a misleading preview/UX issue rather than a server-side trust issue.

Action: align preview validation with the supported JPEG/PNG/WebP formats and show a clear message before the user proceeds.

### SEARCH1 — Listing deep-link behavior depends on the listing being in the currently fetched result set (low; UX)

Shared listing links scroll to a card only after the relevant public listing RPC has loaded its returned rows. If an approved listing is outside the RPC's returned range or has since been removed/unpublished, the page displays the same unavailable message. This is safe but can make older shared links appear broken.

Action: consider a narrowly scoped approved-only lookup by section and ID, preserving the existing public visibility rules and never exposing pending/rejected rows.

## Additional observations

- Client-side submission uses an in-progress set per category to prevent duplicate taps during one request; this is useful UX but not a server-side idempotency guarantee.
- The browser preview creates object URLs and revokes the previous URL when the selected image changes. Confirm cleanup when the user navigates away or resets the form; no evidence of a persistent storage leak was established.
- The server checks a supplied pending-image path with Storage HEAD before accepting it, preventing arbitrary client-supplied paths from being attached to a listing.
- Origin checks and CORS are defense-in-depth for browsers, not substitutes for authentication, Turnstile, authorization, or rate limiting.

## Release boundary

Audit/documentation only. No source fixes, data changes, Storage cleanup, database migrations, Edge Function deployments, or GitHub Pages deployments were performed. The PR remains a draft and must receive review and explicit approval before merge or release.
