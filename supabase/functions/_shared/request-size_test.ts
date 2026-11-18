import { readLimitedRequest } from "./request-size.ts";

Deno.test("accepts a request at the configured byte limit", async () => {
  const request = new Request("https://example.test/upload", {
    method: "POST",
    body: "12345",
  });
  const limited = await readLimitedRequest(request, 5);
  if (!limited) throw new Error("request at the limit should be accepted");
  if (await limited.text() !== "12345") throw new Error("request body must be preserved");
});

Deno.test("rejects a request above the configured byte limit", async () => {
  const request = new Request("https://example.test/upload", {
    method: "POST",
    body: "123456",
  });
  const limited = await readLimitedRequest(request, 5);
  if (limited !== null) throw new Error("oversized request should be rejected");
});

Deno.test("preserves request headers while removing stale length metadata", async () => {
  const request = new Request("https://example.test/upload", {
    method: "POST",
    headers: { "content-type": "application/json", "content-length": "1", "x-check": "ok" },
    body: "{}",
  });
  const limited = await readLimitedRequest(request, 10);
  if (!limited) throw new Error("small request should be accepted");
  if (limited.headers.get("content-type") !== "application/json") throw new Error("content-type must be preserved");
  if (limited.headers.get("x-check") !== "ok") throw new Error("custom headers must be preserved");
  if (limited.headers.has("content-length")) throw new Error("stale content-length must be removed");
});

Deno.test("rejects an oversized streamed body when Content-Length is absent", async () => {
  const request = new Request("https://example.test/upload", {
    method: "POST",
    body: "123456",
  });
  if (request.headers.has("content-length")) {
    throw new Error("test request should not rely on Content-Length");
  }
  const limited = await readLimitedRequest(request, 5);
  if (limited !== null) throw new Error("oversized body without Content-Length should be rejected");
});

Deno.test("accepts an empty request body", async () => {
  const request = new Request("https://example.test/upload", { method: "POST" });
  const limited = await readLimitedRequest(request, 0);
  if (!limited) throw new Error("bodyless request should be accepted");
  if (limited.body !== null) throw new Error("bodyless request must remain bodyless");
});
