import type { ClaimedStorageCleanupJob } from "./storage-cleanup-queue.ts";

export type StorageCleanupWorkerDependencies = {
  isReferenced(job: ClaimedStorageCleanupJob): Promise<boolean | null>;
  inspect(job: ClaimedStorageCleanupJob): Promise<Response>;
  remove(job: ClaimedStorageCleanupJob): Promise<Response>;
  finish(job: ClaimedStorageCleanupJob): Promise<boolean>;
  fail(job: ClaimedStorageCleanupJob, reason: string): Promise<boolean>;
  defer(job: ClaimedStorageCleanupJob): Promise<boolean>;
};

export type StorageCleanupBatchResult = {
  completed: number;
  retried: number;
  deadLettered: number;
  deferred: number;
};

/**
 * Process already-claimed jobs. All external effects are injected so the
 * worker's safety ordering and failure paths can be tested without live Storage.
 */
export async function processStorageCleanupJobs(
  jobs: readonly ClaimedStorageCleanupJob[],
  deps: StorageCleanupWorkerDependencies,
): Promise<StorageCleanupBatchResult> {
  let completed = 0;
  let retried = 0;
  let deadLettered = 0;
  let deferred = 0;

  for (const job of jobs) {
    try {
      const referenced = await deps.isReferenced(job);
      if (referenced === null) throw new Error("Could not verify whether the image is still referenced");
      if (referenced) {
        if (!await deps.defer(job)) {
          throw new Error("Image is referenced, but its cleanup job could not be safely deferred");
        }
        deferred++;
        continue;
      }

      const head = await deps.inspect(job);
      if (head.status !== 404) {
        if (!head.ok) throw new Error("Storage HEAD returned " + head.status);

        // Re-check after HEAD and immediately before DELETE. This narrows, but
        // does not eliminate, the race with a concurrent listing reference.
        const referencedAgain = await deps.isReferenced(job);
        if (referencedAgain === null) {
          throw new Error("Could not re-verify image references immediately before deletion");
        }
        if (referencedAgain) {
          if (!await deps.defer(job)) {
            throw new Error("Image became referenced during cleanup; could not defer safely");
          }
          deferred++;
          continue;
        }

        const remove = await deps.remove(job);
        if (!remove.ok) throw new Error("Storage DELETE returned " + remove.status);
      }

      if (!await deps.finish(job)) {
        throw new Error("Could not mark cleanup job completed");
      }
      completed++;
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      let saved = false;
      try {
        saved = await deps.fail(job, reason);
      } catch (saveError) {
        console.error("Could not persist cleanup failure", job.id, String(saveError));
      }
      if (!saved) {
        console.error("Could not persist cleanup failure", job.id, reason);
      } else if (job.attempts >= 8) {
        deadLettered++;
      } else {
        retried++;
      }
      console.error("Storage cleanup job failed", job.id, reason);
    }
  }

  return { completed, retried, deadLettered, deferred };
}
