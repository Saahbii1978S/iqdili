import {
  CleanupContractHarness,
  isAllowedCleanupTarget,
  retryDelayMs,
  type StoragePort,
} from "./cleanup-contract.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
function assertThrows(fn: () => void, message: string) {
  let thrown = false;
  try { fn(); } catch { thrown = true; }
  assert(thrown, message);
}
async function assertRejects(fn: () => Promise<unknown>, message: string) {
  let rejected = false;
  try { await fn(); } catch { rejected = true; }
  assert(rejected, message);
}

Deno.test("cleanup target allowlist rejects foreign buckets and unsafe paths", () => {
  assert(isAllowedCleanupTarget("listing-images", "services/photo-1.jpg"), "valid service path");
  assert(isAllowedCleanupTarget("market-images", "market/item_2.webp"), "valid market path");
  assert(!isAllowedCleanupTarget("foreign-bucket", "services/photo.jpg"), "foreign bucket rejected");
  assert(!isAllowedCleanupTarget("listing-images", "jobs/photo.jpg"), "wrong folder rejected");
  assert(!isAllowedCleanupTarget("listing-images", "../services/photo.jpg"), "traversal rejected");
  assert(!isAllowedCleanupTarget("listing-images", "services//photo.jpg"), "double slash rejected");
  assert(!isAllowedCleanupTarget("listing-images", "services/photo.jpg?token=x"), "query string rejected");
  assert(isAllowedCleanupTarget("pending-images", "realty/pending.webp"), "pending bucket allows approved folder");
  assert(!isAllowedCleanupTarget("pending-images", "unexpected/pending.webp"), "pending bucket rejects unknown folder");
});

Deno.test("enqueue and row deletion roll back together on injected transaction failure", () => {
  const h = new CleanupContractHarness();
  h.listings.set("listing-a", { id: "listing-a", paths: ["services/a.jpg", "services/b.png"] });
  assertThrows(() => h.enqueueAndDelete("listing-a", true), "injected failure should throw");
  assert(h.listings.has("listing-a"), "listing row must remain after rollback");
  assert(h.tasks.size === 0, "no partial cleanup tasks may remain");
});

Deno.test("successful enqueue creates one task per unique path before listing disappears", () => {
  const h = new CleanupContractHarness();
  h.listings.set("listing-b", { id: "listing-b", paths: ["services/a.jpg", "services/a.jpg", "services/b.png"] });
  h.enqueueAndDelete("listing-b");
  assert(!h.listings.has("listing-b"), "listing row deleted");
  assert(h.tasks.size === 2, "duplicate paths deduplicated");
});

Deno.test("invalid path aborts transaction without deleting listing", () => {
  const h = new CleanupContractHarness();
  h.listings.set("listing-c", { id: "listing-c", paths: ["services/ok.jpg", "../services/no.jpg"] });
  assertThrows(() => h.enqueueAndDelete("listing-c"), "invalid path should abort");
  assert(h.listings.has("listing-c"), "listing preserved");
  assert(h.tasks.size === 0, "no partial task remains");
});

Deno.test("transient Storage failure schedules retry with bounded backoff", async () => {
  const h = new CleanupContractHarness();
  h.listings.set("listing-d", { id: "listing-d", paths: ["services/a.jpg"] });
  h.enqueueAndDelete("listing-d");
  const id = [...h.tasks.keys()][0];
  h.claim(id, 1000, 5000, "lease-1");
  const failingStorage: StoragePort = { remove: async () => { throw new Error("injected-503"); } };
  await h.process(id, "lease-1", 1001, failingStorage);
  const task = h.tasks.get(id)!;
  assert(task.status === "retry", "task enters retry");
  assert(task.attempts === 1, "attempt count increments");
  assert(task.nextAttemptAt === 2001, "first retry delay is 1 second");
});

Deno.test("missing Storage object is treated as idempotent success", async () => {
  const h = new CleanupContractHarness();
  h.listings.set("listing-e", { id: "listing-e", paths: ["services/a.jpg"] });
  h.enqueueAndDelete("listing-e");
  const id = [...h.tasks.keys()][0];
  h.claim(id, 0, 5000, "lease-2");
  const missingStorage: StoragePort = { remove: async () => "missing" };
  await h.process(id, "lease-2", 1, missingStorage);
  assert(h.tasks.get(id)?.status === "completed", "missing object completes task");
});

Deno.test("expired lease can be reclaimed, while a live lease cannot", () => {
  const h = new CleanupContractHarness();
  h.listings.set("listing-f", { id: "listing-f", paths: ["services/a.jpg"] });
  h.enqueueAndDelete("listing-f");
  const id = [...h.tasks.keys()][0];
  assert(h.claim(id, 100, 1000, "worker-a") !== null, "first worker claims");
  assert(h.claim(id, 500, 1000, "worker-b") === null, "second worker cannot steal live lease");
  assert(h.claim(id, 1200, 1000, "worker-b") !== null, "second worker reclaims expired lease");
});

Deno.test("stale lease token cannot complete task", async () => {
  const h = new CleanupContractHarness();
  h.listings.set("listing-g", { id: "listing-g", paths: ["services/a.jpg"] });
  h.enqueueAndDelete("listing-g");
  const id = [...h.tasks.keys()][0];
  h.claim(id, 0, 1000, "valid-token");
  const storage: StoragePort = { remove: async () => "removed" };
  await assertRejects(
    () => h.process(id, "stale-token", 1, storage),
    "stale token must be rejected",
  );
});

Deno.test("retry delay is capped and handles invalid attempt values safely", () => {
  assert(retryDelayMs(1) === 1000, "first delay");
  assert(retryDelayMs(2) === 2000, "second delay");
  assert(retryDelayMs(100) === 60 * 60 * 1000, "delay cap");
  assert(retryDelayMs(-4) === 1000, "minimum attempt");
});
