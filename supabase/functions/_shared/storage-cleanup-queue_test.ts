import { assertEquals, assertThrows } from "jsr:@std/assert";
import { buildStorageCleanupJobs } from "./storage-cleanup-queue.ts";

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
