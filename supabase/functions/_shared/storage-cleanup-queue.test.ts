import {
  buildStorageCleanupJobs,
  buildStorageObjectUrl,
  encodeStorageObjectPath,
  isValidStorageObjectPath,
} from "./storage-cleanup-queue.ts";
import { assertEquals, assertThrows } from "jsr:@std/assert";

Deno.test("accepts supported image paths", () => {
  for (const path of [
    "services/photo.jpg",
    "jobs/offer_01.PNG",
    "realty/folder/image.webp",
    "market/item-2.jpeg",
  ]) assertEquals(isValidStorageObjectPath(path), true, path);
});

Deno.test("rejects unsafe, malformed, and unsupported paths", () => {
  for (const path of [
    "", "/services/photo.jpg", "../photo.jpg", "services/../photo.jpg",
    "services//photo.jpg", "services/./photo.jpg", "services/photo.svg",
    "services/photo.jpg?download=1", "services/photo name.jpg",
    "services\\photo.jpg", null, 42,
  ]) assertEquals(isValidStorageObjectPath(path), false, String(path));
});

Deno.test("rejects paths longer than 220 characters", () => {
  assertEquals(isValidStorageObjectPath("a".repeat(217) + ".jpg"), false);
});

Deno.test("encodes each path segment without encoding separators", () => {
  assertEquals(encodeStorageObjectPath("services/folder/photo-1.webp"), "services/folder/photo-1.webp");
  assertThrows(() => encodeStorageObjectPath("../photo.jpg"));
});

Deno.test("builds info and delete URLs for allowed buckets", () => {
  assertEquals(
    buildStorageObjectUrl("https://example.supabase.co", "listing-images", "services/photo.jpg", "info"),
    "https://example.supabase.co/storage/v1/object/info/listing-images/services/photo.jpg",
  );
  assertEquals(
    buildStorageObjectUrl("https://example.supabase.co", "market-images", "market/photo.jpg", "delete"),
    "https://example.supabase.co/storage/v1/object/market-images/market/photo.jpg",
  );
  assertEquals(
    buildStorageObjectUrl("http://localhost:54321", "pending-images", "services/photo.jpg", "info"),
    "http://localhost:54321/storage/v1/object/info/pending-images/services/photo.jpg",
  );
});

Deno.test("rejects unsupported buckets and insecure non-local endpoints", () => {
  assertThrows(() => buildStorageObjectUrl("https://example.supabase.co", "private-bucket", "services/photo.jpg", "info"));
  assertThrows(() => buildStorageObjectUrl("http://example.supabase.co", "listing-images", "services/photo.jpg", "info"));
  assertThrows(() => buildStorageObjectUrl("https://example.supabase.co", "listing-images", "../photo.jpg", "delete"));
});

Deno.test("builds deterministic cleanup jobs and removes duplicate pairs", () => {
  assertEquals(
    buildStorageCleanupJobs(
      ["listing-images", "market-images", "listing-images"],
      ["services/a.jpg", "services/a.jpg", "market/b.webp"],
    ),
    [
      { bucket: "listing-images", object_path: "services/a.jpg" },
      { bucket: "listing-images", object_path: "market/b.webp" },
      { bucket: "market-images", object_path: "services/a.jpg" },
      { bucket: "market-images", object_path: "market/b.webp" },
    ],
  );
});

Deno.test("returns no jobs when there are no paths", () => {
  assertEquals(buildStorageCleanupJobs(["listing-images"], []), []);
});

Deno.test("rejects unknown buckets and invalid paths when building jobs", () => {
  assertThrows(() => buildStorageCleanupJobs(["unknown"], ["services/a.jpg"]));
  assertThrows(() => buildStorageCleanupJobs(["listing-images"], ["../a.jpg"]));
});
