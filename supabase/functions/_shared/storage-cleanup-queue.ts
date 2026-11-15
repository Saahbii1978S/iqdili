export type StorageCleanupJob = { bucket: "listing-images" | "market-images" | "pending-images"; object_path: string };

const ALLOWED_BUCKETS = new Set(["listing-images", "market-images", "pending-images"]);

export function buildStorageCleanupJobs(
  buckets: readonly string[],
  paths: readonly string[],
): StorageCleanupJob[] {
  const jobs: StorageCleanupJob[] = [];
  const seen = new Set<string>();
  for (const bucket of buckets) {
    if (!ALLOWED_BUCKETS.has(bucket)) throw new Error("Unsupported storage bucket");
    for (const path of paths) {
      if (
        typeof path !== "string" ||
        path.length < 1 ||
        path.length > 220 ||
        path.startsWith("/") ||
        path.includes("..") ||
        path.includes("//") ||
        !/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)
      ) throw new Error("Invalid storage object path");
      const key = bucket + "\0" + path;
      if (seen.has(key)) continue;
      seen.add(key);
      jobs.push({ bucket: bucket as StorageCleanupJob["bucket"], object_path: path });
    }
  }
  return jobs;
}

export async function enqueueStorageCleanup(
  url: string,
  serviceKey: string,
  jobs: readonly StorageCleanupJob[],
): Promise<boolean> {
  if (!jobs.length) return true;
  const response = await fetch(url + "/rest/v1/storage_cleanup_jobs?on_conflict=bucket,object_path", {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
      "Content-Type": "application/json",
      Prefer: "resolution=ignore-duplicates,return=minimal",
    },
    body: JSON.stringify(jobs.map((job) => ({ ...job, status: "staged", attempts: 0, last_error: null, completed_at: null }))),
  });
  return response.ok;
}

export async function activateStorageCleanup(
  url: string,
  serviceKey: string,
  jobs: readonly StorageCleanupJob[],
): Promise<boolean> {
  if (!jobs.length) return true;
  const alternatives = jobs.map((job) =>
    "and(bucket.eq." + job.bucket + ",object_path.eq." + job.object_path + ")"
  );
  const query = new URLSearchParams({
    status: "eq.staged",
    or: "(" + alternatives.join(",") + ")",
  });
  const response = await fetch(url + "/rest/v1/storage_cleanup_jobs?" + query.toString(), {
    method: "PATCH",
    headers: {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ status: "pending" }),
  });
  return response.ok;
}

export async function completeStorageCleanup(
  url: string,
  serviceKey: string,
  job: StorageCleanupJob,
): Promise<boolean> {
  const query = new URLSearchParams({ bucket: "eq." + job.bucket, object_path: "eq." + job.object_path });
  const response = await fetch(url + "/rest/v1/storage_cleanup_jobs?" + query.toString(), {
    method: "PATCH",
    headers: {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ status: "completed", completed_at: new Date().toISOString(), lease_until: null, last_error: null }),
  });
  return response.ok;
}

export async function recordStorageCleanupFailure(
  url: string,
  serviceKey: string,
  job: StorageCleanupJob,
  reason: string,
): Promise<boolean> {
  const query = new URLSearchParams({ bucket: "eq." + job.bucket, object_path: "eq." + job.object_path });
  const response = await fetch(url + "/rest/v1/storage_cleanup_jobs?" + query.toString(), {
    method: "PATCH",
    headers: {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ last_error: reason.slice(0, 300), status: "pending", lease_until: null, completed_at: null }),
  });
  return response.ok;
}

export type ClaimedStorageCleanupJob = StorageCleanupJob & { id: number; attempts: number };

export async function claimStorageCleanupJobs(
  url: string,
  serviceKey: string,
  limit = 5,
): Promise<ClaimedStorageCleanupJob[] | null> {
  const response = await fetch(url + "/rest/v1/rpc/claim_storage_cleanup_jobs", {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_limit: Math.min(Math.max(limit, 1), 5) }),
  });
  if (!response.ok) return null;
  const rows = await response.json().catch(() => null);
  if (!Array.isArray(rows)) return null;
  return rows.filter((row) =>
    Number.isSafeInteger(row.id) &&
    Number.isInteger(row.attempts) &&
    ALLOWED_BUCKETS.has(row.bucket) &&
    typeof row.object_path === "string"
  ) as ClaimedStorageCleanupJob[];
}

export async function finishClaimedStorageCleanup(
  url: string,
  serviceKey: string,
  job: ClaimedStorageCleanupJob,
): Promise<boolean> {
  const query = new URLSearchParams({ id: "eq." + job.id, status: "eq.processing" });
  const response = await fetch(url + "/rest/v1/storage_cleanup_jobs?" + query.toString(), {
    method: "PATCH",
    headers: {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({ status: "completed", completed_at: new Date().toISOString(), lease_until: null, last_error: null }),
  });
  return response.ok;
}

export async function failClaimedStorageCleanup(
  url: string,
  serviceKey: string,
  job: ClaimedStorageCleanupJob,
  reason: string,
): Promise<boolean> {
  const query = new URLSearchParams({ id: "eq." + job.id, status: "eq.processing" });
  const response = await fetch(url + "/rest/v1/storage_cleanup_jobs?" + query.toString(), {
    method: "PATCH",
    headers: {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({
      status: job.attempts >= 8 ? "dead_letter" : "pending",
      lease_until: null,
      last_error: reason.slice(0, 300),
    }),
  });
  return response.ok;
}
