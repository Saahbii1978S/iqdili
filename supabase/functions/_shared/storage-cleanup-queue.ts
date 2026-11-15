export type StorageCleanupJob = { bucket: "listing-images" | "market-images" | "pending-images"; object_path: string };

const ALLOWED_BUCKETS = new Set(["listing-images", "market-images", "pending-images"]);

export function isValidStorageObjectPath(path: unknown): path is string {
  if (
    typeof path !== "string" ||
    path.length < 1 ||
    path.length > 220 ||
    path.startsWith("/") ||
    path.includes("//") ||
    !/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)
  ) return false;
  return path.split("/").every((segment) => segment !== "" && segment !== "." && segment !== "..");
}

export function encodeStorageObjectPath(path: string): string {
  return path.split("/").map(encodeURIComponent).join("/");
}

export function buildStorageCleanupJobs(
  buckets: readonly string[],
  paths: readonly string[],
): StorageCleanupJob[] {
  const jobs: StorageCleanupJob[] = [];
  const seen = new Set<string>();
  for (const bucket of buckets) {
    if (!ALLOWED_BUCKETS.has(bucket)) throw new Error("Unsupported storage bucket");
    for (const path of paths) {
      if (!isValidStorageObjectPath(path)) throw new Error("Invalid storage object path");
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
  if (jobs.length > 500) return false;
  const response = await fetch(url + "/rest/v1/rpc/activate_storage_cleanup_jobs", {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_jobs: jobs }),
  });
  if (!response.ok) return false;
  const count = await response.json().catch(() => null);
  return count === jobs.length;
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
    isValidStorageObjectPath(row.object_path)
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
      Prefer: "return=representation",
    },
    body: JSON.stringify({ status: "completed", completed_at: new Date().toISOString(), lease_until: null, last_error: null }),
  });
  if (!response.ok) return false;
  const rows = await response.json().catch(() => null);
  return Array.isArray(rows) && rows.length === 1;
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
      Prefer: "return=representation",
    },
    body: JSON.stringify({
      status: job.attempts >= 8 ? "dead_letter" : "pending",
      lease_until: null,
      last_error: reason.slice(0, 300),
    }),
  });
  if (!response.ok) return false;
  const rows = await response.json().catch(() => null);
  return Array.isArray(rows) && rows.length === 1;
}

export async function isStorageCleanupObjectReferenced(
  url: string,
  serviceKey: string,
  job: StorageCleanupJob,
): Promise<boolean | null> {
  const response = await fetch(url + "/rest/v1/rpc/is_storage_cleanup_object_referenced", {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_bucket: job.bucket, p_object_path: job.object_path }),
  });
  if (!response.ok) return null;
  const result = await response.json().catch(() => null);
  return typeof result === "boolean" ? result : null;
}
