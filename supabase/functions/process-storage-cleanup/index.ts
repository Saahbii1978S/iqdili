import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  claimStorageCleanupJobs,
  finishClaimedStorageCleanup,
  failClaimedStorageCleanup,
  encodeStorageObjectPath,
  isStorageCleanupObjectReferenced,
  deferClaimedStorageCleanup,
} from "../_shared/storage-cleanup-queue.ts";

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply({ error: "Worker is not configured" }, 503);

  // The scheduled caller must authenticate with the project's service-role key.
  // Never expose this endpoint key in the browser or public app.
  if (
    req.headers.get("apikey") !== serviceKey ||
    req.headers.get("authorization") !== "Bearer " + serviceKey
  ) return reply({ error: "Unauthorized" }, 401);

  const jobs = await claimStorageCleanupJobs(url, serviceKey, 5);
  if (jobs === null) {
    console.error("Could not claim storage cleanup jobs");
    return reply({ error: "Could not claim cleanup jobs" }, 502);
  }

  let completed = 0;
  let retried = 0;
  let deadLettered = 0;
  let deferred = 0;

  for (const job of jobs) {
    try {
      const referenced = await isStorageCleanupObjectReferenced(url, serviceKey, job);
      if (referenced === null) throw new Error("Could not verify whether the image is still referenced");
      if (referenced) {
        if (!await deferClaimedStorageCleanup(url, serviceKey, job)) {
          throw new Error("Image is referenced, but its cleanup job could not be safely deferred");
        }
        deferred++;
        continue;
      }

      const objectUrl = url + "/storage/v1/object/info/" + job.bucket + "/" + encodeStorageObjectPath(job.object_path);
      const head = await fetch(objectUrl, {
        method: "HEAD",
        headers: { apikey: serviceKey, Authorization: "Bearer " + serviceKey },
        signal: AbortSignal.timeout(7000),
      });

      if (head.status !== 404) {
        if (!head.ok) throw new Error("Storage HEAD returned " + head.status);
        const remove = await fetch(
          url + "/storage/v1/object/" + job.bucket + "/" + encodeStorageObjectPath(job.object_path),
          {
            method: "DELETE",
            headers: { apikey: serviceKey, Authorization: "Bearer " + serviceKey },
            signal: AbortSignal.timeout(7000),
          },
        );
        if (!remove.ok) throw new Error("Storage DELETE returned " + remove.status);
      }

      if (!await finishClaimedStorageCleanup(url, serviceKey, job)) {
        throw new Error("Could not mark cleanup job completed");
      }
      completed++;
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      const saved = await failClaimedStorageCleanup(url, serviceKey, job, reason);
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

  return reply({
    ok: true,
    claimed: jobs.length,
    completed,
    retried,
    dead_lettered: deadLettered,
    deferred,
  });
});
