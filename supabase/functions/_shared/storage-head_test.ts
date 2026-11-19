import { classifyStorageHeadStatus } from "./storage-head.ts";

Deno.test("classifies successful Storage HEAD responses as existing", () => {
  for (const status of [200, 201, 204]) {
    if (classifyStorageHeadStatus(status) !== "exists") {
      throw new Error(`expected ${status} to mean object exists`);
    }
  }
});

Deno.test("treats only 404 as proof that a Storage object is absent", () => {
  if (classifyStorageHeadStatus(404) !== "missing") {
    throw new Error("404 should mean object missing");
  }
});

Deno.test("fails closed for authorization, throttling, and server errors", () => {
  for (const status of [400, 401, 403, 408, 429, 500, 502, 503]) {
    if (classifyStorageHeadStatus(status) !== "error") {
      throw new Error(`expected ${status} to be an error, not missing`);
    }
  }
});
