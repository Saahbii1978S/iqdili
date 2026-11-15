import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  claimStorageCleanupJobs,
  finishClaimedStorageCleanup,
  failClaimedStorageCleanup,
  buildStorageObjectUrl,
  isStorageCleanupObjectReferenced,
  deferClaimedStorageCleanup,
} from "../_shared/storage-cleanup-queue.ts";
import { processStorageCleanupJobs } from "../_shared/storage-cleanup-worker.ts";

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

  const result = await processStorageCleanupJobs(jobs, {
    isReferenced: (job) => isStorageCleanupObjectReferenced(url, serviceKey, job),
    inspect: (job) => fetch(buildStorageObjectUrl(url, job.bucket, job.object_path, "info"), {
      method: "HEAD",
      headers: { apikey: serviceKey, Authorization: "Bearer " + serviceKey },
      signal: AbortSignal.timeout(7000),
    }),
    remove: (job) => fetch(buildStorageObjectUrl(url, job.bucket, job.object_path, "delete"), {
      method: "DELETE",
      headers: { apikey: serviceKey, Authorization: "Bearer " + serviceKey },
      signal: AbortSignal.timeout(7000),
    }),
    finish: (job) => finishClaimedStorageCleanup(url, serviceKey, job),
    fail: (job, reason) => failClaimedStorageCleanup(url, serviceKey, job, reason),
    defer: (job) => deferClaimedStorageCleanup(url, serviceKey, job),
  });

  return reply({
    ok: true,
    claimed: jobs.length,
    completed: result.completed,
    retried: result.retried,
    dead_lettered: result.deadLettered,
    deferred: result.deferred,
  });
});
