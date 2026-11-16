import { hasRecentAuthentication } from "./recent-auth.ts";

function token(payload: Record<string, unknown>): string {
  const encoded = btoa(JSON.stringify(payload)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  return "header." + encoded + ".signature";
}

Deno.test("accepts a valid session authenticated within ten minutes", () => {
  const now = 1_800_000_000;
  if (!hasRecentAuthentication("Bearer " + token({ sub: "user-1", auth_time: now - 120, exp: now + 3600 }), "user-1", now * 1000)) {
    throw new Error("recent authentication should pass");
  }
});

Deno.test("rejects old, future, expired, or mismatched sessions", () => {
  const now = 1_800_000_000;
  const cases = [
    { sub: "user-1", auth_time: now - 601, exp: now + 3600 },
    { sub: "user-1", auth_time: now + 61, exp: now + 3600 },
    { sub: "user-1", auth_time: now - 10, exp: now - 1 },
    { sub: "user-2", auth_time: now - 10, exp: now + 3600 },
  ];
  for (const payload of cases) {
    if (hasRecentAuthentication("Bearer " + token(payload), "user-1", now * 1000)) {
      throw new Error("invalid freshness case should fail");
    }
  }
});

Deno.test("rejects malformed authorization and malformed JWT", () => {
  if (hasRecentAuthentication("Basic abc", "user-1")) throw new Error("non-bearer auth must fail");
  if (hasRecentAuthentication("Bearer not-a-jwt", "user-1")) throw new Error("malformed JWT must fail");
});
