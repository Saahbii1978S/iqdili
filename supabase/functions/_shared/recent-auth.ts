export function hasRecentAuthentication(
  authorization: string,
  userId: string,
  nowMs = Date.now(),
  maxAgeSeconds = 10 * 60,
): boolean {
  const match = /^Bearer\s+([^\s]+)$/i.exec(authorization);
  if (!match) return false;
  const parts = match[1].split(".");
  if (parts.length !== 3) return false;

  try {
    const encoded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, "=")));
    const nowSeconds = Math.floor(nowMs / 1000);
    return payload?.sub === userId &&
      Number.isFinite(payload?.auth_time) &&
      Number.isFinite(payload?.exp) &&
      payload.auth_time <= nowSeconds + 60 &&
      nowSeconds - payload.auth_time <= maxAgeSeconds &&
      payload.exp > nowSeconds;
  } catch {
    return false;
  }
}
