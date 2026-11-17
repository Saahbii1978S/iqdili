# Visitor counter validation checklist

This checklist is for validating PR50 before merge. It does not authorize production changes.

## Scope
- The public page sends one heartbeat immediately, then every 120 seconds.
- The database considers a visitor online when `last_seen` is within the last 5 minutes.
- The admin panel refreshes visitor statistics every 30 seconds while the admin panel is visible.
- A new visit is counted after 30 minutes of inactivity for the same privacy-preserving visitor identifier.

## Safe test setup
Use a disposable staging environment with the same relevant function definitions and dashboard code. Do not use production visitor records as test fixtures, and do not change production settings or data.

## Manual scenarios
1. **First page load:** Open the public site in a fresh private browser session. Confirm one heartbeat request is sent and the online count updates within the expected refresh window.
2. **Page remains foregrounded:** Keep the page open for at least 6 minutes. Confirm subsequent heartbeat requests are approximately 120 seconds apart and the visitor remains online.
3. **Admin panel refresh:** Sign in with a staging admin account, open the admin panel, and confirm the displayed statistics refresh about every 30 seconds while the panel is visible.
4. **Panel hidden:** Hide/leave the admin panel. Confirm the dashboard polling callback does not request statistics while the panel is hidden.
5. **Page closed:** Close the public page. Confirm the visitor is no longer counted online after the 5-minute freshness window, allowing for the next admin refresh.
6. **Background/suspended tab:** Put the public tab in the background or suspend the browser. Record actual heartbeat timing; browser throttling may delay timers, so do not assume the 120-second interval is guaranteed.
7. **Admin exclusion:** Confirm a signed-in staging admin is excluded from public visitor tracking.
8. **Failure handling:** Simulate a failed RPC in staging and confirm the page remains usable and logs a warning rather than breaking navigation.

## Acceptance notes
- Do not merge based only on static inspection.
- Record observed timestamps and RPC outcomes for each scenario.
- If background throttling causes false offline periods, revisit the design (for example, visibility-aware heartbeat or a server-side presence strategy) before rollout.
- No live Supabase migration, function deployment, production data write, or production configuration change is part of this checklist.
