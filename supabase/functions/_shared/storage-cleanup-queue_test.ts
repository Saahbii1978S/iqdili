import { assertEquals, assertThrows } from "jsr:@std/assert";
import { buildStorageCleanupJobs, buildStorageObjectUrl, encodeStorageObjectPath, isValidStorageObjectPath, scheduleStorageCleanup } from "./storage-cleanup-queue.ts";

Deno.test("builds unique jobs for both public and pending buckets", () => {
  assertEquals(buildStorageCleanupJobs(
    ["listing-images", "pending-images"],
    ["services/a.jpg", "services/a.jpg"],
  ), [
    { bucket: "listing-images", object_path: "services/a.jpg" },
    { bucket: "pending-images", object_path: "services/a.jpg" },
  ]);
});

Deno.test("rejects unsupported buckets", () => {
  assertThrows(() => buildStorageCleanupJobs(["private"], ["services/a.jpg"]));
});

Deno.test("rejects traversal and malformed paths", () => {
  for (const path of ["../a.jpg", "services/../a.jpg", "services//a.jpg", "/services/a.jpg", "services/a.svg"]) {
    assertThrows(() => buildStorageCleanupJobs(["listing-images"], [path]));
  }
});

Deno.test("rejects dot segments even when the filename is otherwise valid", () => {
  for (const path of ["services/./a.jpg", "services/a/../b.jpg", "services/../a.jpg"]) {
    assertEquals(isValidStorageObjectPath(path), false);
  }
});

Deno.test("encodes object path segments without encoding folder separators", () => {
  assertEquals(encodeStorageObjectPath("services/photo-1.webp"), "services/photo-1.webp");
});

Deno.test("builds exact object endpoints without changing path separators", () => {
  assertEquals(
    buildStorageObjectUrl("https://example.supabase.co/", "listing-images", "services/photo-1.webp", "delete"),
    "https://example.supabase.co/storage/v1/object/listing-images/services/photo-1.webp",
  );
  assertEquals(
    buildStorageObjectUrl("https://example.supabase.co", "pending-images", "market/a.jpg", "info"),
    "https://example.supabase.co/storage/v1/object/info/pending-images/market/a.jpg",
  );
});

Deno.test("refuses invalid bucket, traversal, and non-HTTPS Storage endpoints", () => {
  assertThrows(() => buildStorageObjectUrl("https://example.supabase.co", "other", "a.jpg", "delete"));
  assertThrows(() => buildStorageObjectUrl("https://example.supabase.co", "listing-images", "../a.jpg", "delete"));
  assertThrows(() => buildStorageObjectUrl("http://example.supabase.co", "listing-images", "a.jpg", "delete"));
});


Deno.test("schedules orphan cleanup by enqueueing before activation", async () => {
  const originalFetch = globalThis.fetch;
  const calls: string[] = [];
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    calls.push(url);
    if (url.includes("/storage_cleanup_jobs?")) return new Response(null, { status: 201 });
    return new Response("1", { status: 200, headers: { "Content-Type": "application/json" } });
  };
  try {
    const jobs = buildStorageCleanupJobs(["pending-images"], ["services/orphan.jpg"]);
    assertEquals(await scheduleStorageCleanup("https://example.supabase.co", "service-key", jobs), {
      queued: true,
      activated: true,
    });
    assertEquals(calls.length, 2);
    assertEquals(calls[0].includes("/storage_cleanup_jobs?"), true);
    assertEquals(calls[1].endsWith("/rpc/activate_storage_cleanup_jobs"), true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("does not activate orphan cleanup when enqueue fails", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return new Response("unavailable", { status: 503 });
  };
  try {
    const jobs = buildStorageCleanupJobs(["pending-images"], ["services/orphan.jpg"]);
    assertEquals(await scheduleStorageCleanup("https://example.supabase.co", "service-key", jobs), {
      queued: false,
      activated: false,
    });
    assertEquals(calls, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("reports queued cleanup when activation fails so operators can detect staged jobs", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return calls === 1
      ? new Response(null, { status: 201 })
      : new Response("unavailable", { status: 503 });
  };
  try {
    const jobs = buildStorageCleanupJobs(["pending-images"], ["services/orphan.jpg"]);
    assertEquals(await scheduleStorageCleanup("https://example.supabase.co", "service-key", jobs), {
      queued: true,
      activated: false,
    });
    assertEquals(calls, 2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
