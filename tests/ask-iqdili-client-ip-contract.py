from pathlib import Path

source = Path("supabase/functions/ask-iqdili/index.ts").read_text(encoding="utf-8")

assert 'req.headers.get("cf-connecting-ip")?.trim() || ""' in source, (
    "ask-iqdili must use the Cloudflare client-IP header"
)
assert 'req.headers.get("x-forwarded-for")' not in source, (
    "ask-iqdili must not trust the caller-controlled first X-Forwarded-For value"
)
assert 'if (!supabaseUrl || !serviceRoleKey || !clientIp)' in source, (
    "ask-iqdili must fail closed when the trusted client-IP header is unavailable"
)
assert 'consume_ask_rate_limit' in source, "Existing server-side rate limiter must remain enabled"
assert '15 سؤال في الساعة' in source, "User-facing rate-limit message must remain intact"

print("PASS: ask-iqdili uses cf-connecting-ip only for rate-limit fingerprinting.")
print("PASS: missing client IP fails closed; the existing database rate limit remains active.")
print("NOTE: static source checks do not prove the hosted gateway overwrites spoofed headers.")
