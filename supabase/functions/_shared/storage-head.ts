export type StorageHeadState = "exists" | "missing" | "error";

/**
 * Treat only 404 as proof that an object is absent.
 * Auth, permission, rate-limit, and server errors must fail closed.
 */
export function classifyStorageHeadStatus(status: number): StorageHeadState {
  if (status >= 200 && status < 300) return "exists";
  if (status === 404) return "missing";
  return "error";
}
