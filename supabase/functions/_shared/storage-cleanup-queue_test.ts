import { assertEquals, assertThrows } from "jsr:@std/assert";
import { buildStorageCleanupJobs, encodeStorageObjectPath, isValidStorageObjectPath } from "./storage-cleanup-queue.ts";

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
