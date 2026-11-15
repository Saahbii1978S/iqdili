import { assertEquals } from "jsr:@std/assert";
import type { ClaimedStorageCleanupJob } from "./storage-cleanup-queue.ts";
import { processStorageCleanupJobs, type StorageCleanupWorkerDependencies } from "./storage-cleanup-worker.ts";

const job = (id: number, attempts = 1): ClaimedStorageCleanupJob => ({
  id,
  attempts,
  lease_token: "11111111-1111-4111-8111-111111111111",
  bucket: "listing-images",
  object_path: "services/test-image.jpg",
});

function deps(overrides: Partial<StorageCleanupWorkerDependencies> = {}) {
  const calls: string[] = [];
  const base: StorageCleanupWorkerDependencies = {
    isReferenced: async () => { calls.push("reference"); return false; },
    inspect: async () => { calls.push("head"); return new Response(null, { status: 200 }); },
    remove: async () => { calls.push("delete"); return new Response(null, { status: 200 }); },
    finish: async () => { calls.push("finish"); return true; },
    fail: async () => { calls.push("fail"); return true; },
    defer: async () => { calls.push("defer"); return true; },
  };
  return { calls, value: { ...base, ...overrides } };
}

Deno.test("defers an object already referenced without checking or deleting Storage", async () => {
  const d = deps({ isReferenced: async () => { d.calls.push("reference"); return true; } });
  const result = await processStorageCleanupJobs([job(1)], d.value);
  assertEquals(result, { completed: 0, retried: 0, deadLettered: 0, deferred: 1 });
  assertEquals(d.calls, ["reference", "defer"]);
});

Deno.test("rechecks references after HEAD and never deletes a newly referenced object", async () => {
  let checks = 0;
  const d = deps({
    isReferenced: async () => { d.calls.push("reference"); checks++; return checks === 2; },
  });
  const result = await processStorageCleanupJobs([job(2)], d.value);
  assertEquals(result, { completed: 0, retried: 0, deadLettered: 0, deferred: 1 });
  assertEquals(d.calls, ["reference", "head", "reference", "defer"]);
});

Deno.test("treats an already-missing object as completed without issuing DELETE", async () => {
  const d = deps({ inspect: async () => { d.calls.push("head"); return new Response(null, { status: 404 }); } });
  const result = await processStorageCleanupJobs([job(3)], d.value);
  assertEquals(result, { completed: 1, retried: 0, deadLettered: 0, deferred: 0 });
  assertEquals(d.calls, ["reference", "head", "finish"]);
});

Deno.test("records a retry for a transient Storage error", async () => {
  const d = deps({ inspect: async () => { d.calls.push("head"); return new Response(null, { status: 503 }); } });
  const result = await processStorageCleanupJobs([job(4)], d.value);
  assertEquals(result, { completed: 0, retried: 1, deadLettered: 0, deferred: 0 });
  assertEquals(d.calls, ["reference", "head", "fail"]);
});

Deno.test("dead-letters an exhausted job and continues processing the rest of the batch", async () => {
  const d = deps({
    inspect: async (item) => {
      d.calls.push("head-" + item.id);
      return item.id === 5 ? new Response(null, { status: 500 }) : new Response(null, { status: 404 });
    },
  });
  const result = await processStorageCleanupJobs([job(5, 8), job(6)], d.value);
  assertEquals(result, { completed: 1, retried: 0, deadLettered: 1, deferred: 0 });
  assertEquals(d.calls, ["reference", "head-5", "fail", "reference", "head-6", "finish"]);
});
