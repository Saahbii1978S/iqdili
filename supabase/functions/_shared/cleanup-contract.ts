/**
 * In-memory contract harness for storage-cleanup reliability tests.
 *
 * IMPORTANT: this is deliberately a test model, not the production cleanup
 * implementation and not a substitute for local/staging Supabase integration
 * tests. It lets the repository test the intended state-machine contract while
 * the production flow is still REST-call based and has no durable outbox.
 */
export type TaskStatus = "pending" | "processing" | "retry" | "completed" | "dead";

export interface CleanupTask {
  id: string;
  bucket: string;
  path: string;
  status: TaskStatus;
  attempts: number;
  leaseUntil: number | null;
  leaseToken: string | null;
  nextAttemptAt: number;
}

export interface Listing {
  id: string;
  paths: string[];
}

export interface StoragePort {
  remove(bucket: string, path: string): Promise<"removed" | "missing">;
}

const ALLOWED: Record<string, string> = {
  "listing-images": "services/",
  "market-images": "market/",
  "pending-images": "",
};

export function isAllowedCleanupTarget(bucket: string, path: string): boolean {
  if (!Object.hasOwn(ALLOWED, bucket) || typeof path !== "string") return false;
  if (path.length < 1 || path.length > 220 || path.startsWith("/") ||
      path.includes("..") || path.includes("//") || path.includes("\\") ||
      path.includes("?") || path.includes("#")) return false;
  if (!/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)) return false;
  const folder = ALLOWED[bucket];
  return folder === "" || path.startsWith(folder);
}

export function retryDelayMs(attempt: number): number {
  const safeAttempt = Math.max(1, Math.min(10, Math.floor(attempt)));
  return Math.min(60 * 60 * 1000, 1000 * 2 ** (safeAttempt - 1));
}

/** Test-only in-memory model; transaction rollback is represented by copy/commit. */
export class CleanupContractHarness {
  readonly listings = new Map<string, Listing>();
  readonly tasks = new Map<string, CleanupTask>();
  private nextId = 1;

  enqueueAndDelete(listingId: string, failAfterEnqueue = false): void {
    const listing = this.listings.get(listingId);
    if (!listing) throw new Error("listing-not-found");

    const taskSnapshot = new Map([...this.tasks].map(([k, v]) => [k, { ...v }]));
    const listingSnapshot = { ...listing, paths: [...listing.paths] };
    try {
      for (const path of new Set(listing.paths)) {
        if (!isAllowedCleanupTarget("listing-images", path)) {
          throw new Error("invalid-cleanup-path");
        }
        const id = "task-" + this.nextId++;
        this.tasks.set(id, {
          id, bucket: "listing-images", path, status: "pending",
          attempts: 0, leaseUntil: null, leaseToken: null, nextAttemptAt: 0,
        });
      }
      if (failAfterEnqueue) throw new Error("injected-transaction-failure");
      this.listings.delete(listingId);
    } catch (error) {
      this.tasks.clear();
      for (const [k, v] of taskSnapshot) this.tasks.set(k, v);
      this.listings.set(listingId, listingSnapshot);
      throw error;
    }
  }

  claim(taskId: string, now: number, leaseMs: number, token: string): CleanupTask | null {
    const task = this.tasks.get(taskId);
    if (!task || task.status === "completed" || task.status === "dead") return null;
    if (task.status === "processing" && (task.leaseUntil ?? 0) > now) return null;
    if (task.nextAttemptAt > now) return null;
    task.status = "processing";
    task.leaseUntil = now + leaseMs;
    task.leaseToken = token;
    return { ...task };
  }

  async process(taskId: string, token: string, now: number, storage: StoragePort, maxAttempts = 4): Promise<void> {
    const task = this.tasks.get(taskId);
    if (!task || task.status !== "processing" || task.leaseToken !== token ||
        (task.leaseUntil ?? 0) <= now) throw new Error("invalid-or-expired-lease");

    if (!isAllowedCleanupTarget(task.bucket, task.path)) {
      task.status = "dead";
      task.leaseToken = null;
      task.leaseUntil = null;
      return;
    }

    try {
      await storage.remove(task.bucket, task.path);
      task.status = "completed"; // "missing" is an idempotent success too.
      task.leaseToken = null;
      task.leaseUntil = null;
    } catch {
      task.attempts += 1;
      task.leaseToken = null;
      task.leaseUntil = null;
      if (task.attempts >= maxAttempts) {
        task.status = "dead";
      } else {
        task.status = "retry";
        task.nextAttemptAt = now + retryDelayMs(task.attempts);
      }
    }
  }
}
