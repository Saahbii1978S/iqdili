from pathlib import Path

ROOT = Path("supabase/functions")
FUNCTIONS = [
    "ask-iqdili", "submit-public-post", "upload-pending-image",
    "admin-approve-post", "admin-update-post-status", "admin-post-image",
    "delete-my-post", "delete-account", "my-posts", "admin-delete-post",
    "notify-admin-new-user",
]
NEW_HOST = "ahla-tounsa-project.github.io"
OLD_HOST = "saahbii1978s.github.io"

sources = {}
for name in FUNCTIONS:
    path = ROOT / name / "index.ts"
    assert path.is_file(), f"Missing Edge Function source: {path}"
    source = path.read_text(encoding="utf-8")
    sources[name] = source
    assert NEW_HOST in source, f"{name}: new Pages hostname is missing"
    assert OLD_HOST not in source, f"{name}: stale Pages hostname remains"

# Administrative writes must retain server-side authorization checks.
for name in ("admin-approve-post", "admin-update-post-status", "admin-post-image"):
    source = sources[name]
    assert "/auth/v1/user" in source, f"{name}: authenticated user lookup missing"
    assert "is_admin" in source, f"{name}: admin authorization RPC missing"

assert "/auth/v1/user" in sources["admin-delete-post"]
assert "is_owner" in sources["admin-delete-post"], "admin-delete-post: owner authorization missing"

# User-scoped reads/deletes must remain constrained to the authenticated user's ID.
assert '"user_id":"eq."+user.id' in sources["delete-my-post"] or '"user_id":"eq." + user.id' in sources["delete-my-post"]
assert 'user_id:"eq."+user.id' in sources["my-posts"] or 'user_id: "eq." + user.id' in sources["my-posts"]

# Account deletion must retain the explicit confirmation and admin-account protection.
account = sources["delete-account"]
assert 'body.confirm !== "DELETE"' in account, "delete-account: explicit confirmation guard missing"
assert '["admins", "staff_roles"]' in account, "delete-account: admin/staff protection check missing"

# Public submission and image upload must still enforce Turnstile verification.
for name in ("submit-public-post", "upload-pending-image"):
    source = sources[name]
    assert "verification.success !== true" in source, f"{name}: Turnstile success check missing"
    assert "verification.hostname !== NEW_HOST" in source, f"{name}: Turnstile hostname check missing"

print(f"PASS: {len(FUNCTIONS)} Edge Function source files exist and use the new hostname.")
print("PASS: admin authorization, user ownership, account deletion safeguards, and Turnstile checks remain present.")
print("NOTE: static source-contract checks only; these do not execute functions or contact production services.")
