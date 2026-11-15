import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { hasRecentAuthentication } from "../_shared/recent-auth.ts";
import { readLimitedRequest } from "../_shared/request-size.ts";
import { buildStorageCleanupJobs, enqueueStorageCleanup, activateStorageCleanup, completeStorageCleanup, recordStorageCleanupFailure } from "../_shared/storage-cleanup-queue.ts";

const ORIGIN = "https://saahbii1978s.github.io";
const cors = {
  "Access-Control-Allow-Origin": ORIGIN,
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};
const reply = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });

const tables = [
  { name: "service_requests", folder: "services", bucket: "listing-images" },
  { name: "job_posts", folder: "jobs", bucket: "listing-images" },
  { name: "real_estate_posts", folder: "realty", bucket: "listing-images" },
  { name: "market_posts", folder: "market", bucket: "market-images" },
] as const;

function validPath(path: unknown, folder: string): path is string {
  return typeof path === "string" &&
    path.length <= 220 &&
    path.startsWith(folder + "/") &&
    /^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path) &&
    !path.includes("..") &&
    !path.includes("//");
}

async function api(
  url: string,
  key: string,
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  return await fetch(url + path, {
    ...init,
    headers: {
      "apikey": key,
      "Authorization": "Bearer " + key,
      ...(init.headers || {}),
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return reply({ error: "طريقة الطلب غير مدعومة." }, 405);
  if (req.headers.get("origin") !== ORIGIN) return reply({ error: "مصدر الطلب غير مسموح." }, 403);

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const authorization = req.headers.get("authorization") || "";
    if (!url || !serviceKey) return reply({ error: "خدمة الحسابات غير مهيّأة." }, 503);
    if (!authorization.startsWith("Bearer ") || authorization.length > 5000) {
      return reply({ error: "سجّل الدخول لحسابك من جديد." }, 401);
    }

    const userResponse = await fetch(url + "/auth/v1/user", {
      headers: { "apikey": serviceKey, "Authorization": authorization },
    });
    if (!userResponse.ok) return reply({ error: "جلسة الحساب غير صالحة. سجّل الدخول من جديد." }, 401);
    const user = await userResponse.json().catch(() => ({}));
    if (typeof user.id !== "string" || !/^[0-9a-f-]{36}$/i.test(user.id)) {
      return reply({ error: "تعذّر التثبت من الحساب." }, 401);
    }
    // The Auth endpoint validates the JWT signature; now require its auth_time claim to be fresh.
    if (!hasRecentAuthentication(authorization, user.id)) {
      return reply({ error: "لحماية حسابك، عاود تسجيل الدخول بكلمة المرور قبل طلب حذف الحساب." }, 401);
    }

    const boundedRequest = await readLimitedRequest(req, 1024);
    if (!boundedRequest) return reply({ error: "حجم الطلب أكبر من المسموح." }, 413);
    const body = await boundedRequest.json().catch(() => null);
    if (!body || body.confirm !== "DELETE") {
      return reply({ error: "تأكيد الحذف غير صحيح." }, 400);
    }

    // Keep administrator accounts intact so the platform cannot lose its only owner.
    for (const roleTable of ["admins", "staff_roles"]) {
      const roleCheck = await api(
        url,
        serviceKey,
        "/rest/v1/" + roleTable + "?user_id=eq." + encodeURIComponent(user.id) + "&select=user_id&limit=1",
      );
      if (!roleCheck.ok) {
        console.error("Account role check failed", roleTable, roleCheck.status);
        return reply({ error: "تعذّر التثبت من صلاحيات الحساب. لم يتم حذف أي بيانات." }, 503);
      }
      const roles = await roleCheck.json().catch(() => []);
      if (Array.isArray(roles) && roles.length) {
        return reply({
          error: "هذا الحساب عنده صلاحيات إدارة. يلزم نقل أو إنهاء الصلاحيات الإدارية قبل حذف الحساب.",
          code: "ADMIN_ACCOUNT",
        }, 403);
      }
    }

    const rowsByTable: Record<string, Array<{ id: number; image_urls?: string[]; title?: string; description?: string }>> = {};
    for (const table of tables) {
      const all: Array<{ id: number; image_urls?: string[]; title?: string; description?: string }> = [];
      let complete = false;
      for (let offset = 0; offset < 10000; offset += 1000) {
        const query = new URLSearchParams({
          select: "id,image_urls,title,description",
          user_id: "eq." + user.id,
          order: "id.asc",
          limit: "1000",
          offset: String(offset),
        });
        const response = await api(url, serviceKey, "/rest/v1/" + table.name + "?" + query.toString());
        if (!response.ok) {
          console.error("Account data lookup failed", table.name, response.status);
          return reply({ error: "تعذّر تجهيز بيانات الحذف. لم يتم حذف الحساب." }, 503);
        }
        const rows = await response.json().catch(() => null);
        if (!Array.isArray(rows)) return reply({ error: "تعذّر قراءة بيانات الحساب." }, 503);
        all.push(...rows);
        if (rows.length < 1000) {
          complete = true;
          break;
        }
      }
      if (!complete) {
        return reply({ error: "عدد الإعلانات المرتبطة بالحساب كبير بشكل غير متوقع. تواصل مع الإدارة لإتمام الحذف بأمان." }, 413);
      }
      rowsByTable[table.name] = all;
    }

    // Protect known demo IDs and any clearly labelled test/demo post before deleting anything.
    const protectedIds: Record<string, string[]> = {
      service_requests: ["13"],
      job_posts: ["7"],
      market_posts: ["2", "3", "7", "8", "9"],
      real_estate_posts: ["1", "2", "6"],
    };
    const demoPattern = /(تجريب|تجريبي|اختبار|test|demo|مثال)/i;
    for (const table of tables) {
      for (const row of rowsByTable[table.name] || []) {
        const demoText = (String(row.title || "") + " " + String(row.description || "")).toLowerCase();
        if ((protectedIds[table.name] || []).includes(String(row.id)) || demoPattern.test(demoText)) {
          return reply({
            error: "الحساب مرتبط بإعلان تجريبي محمي. لم نحذف أي إعلان أو صورة أو الحساب؛ تواصل مع الإدارة لمراجعته.",
            code: "PROTECTED_TEST_POST",
          }, 409);
        }
      }
    }

    // Validate and collect image paths first; do not touch Storage yet.
    const pathsByTable: Record<string, string[]> = {};
    for (const table of tables) {
      const paths: string[] = [];
      for (const row of rowsByTable[table.name] || []) {
        const images = Array.isArray(row.image_urls) ? row.image_urls : [];
        for (const path of images) {
          if (!validPath(path, table.folder)) {
            console.error("Unexpected user image path; aborting account deletion", table.name, row.id);
            return reply({ error: "وجدنا مسار صورة غير متوقع. أوقفنا الحذف لحماية ملفات المنصة." }, 409);
          }
          paths.push(path);
        }
      }
      pathsByTable[table.name] = [...new Set(paths)];
    }

    const cleanupJobs = tables.flatMap((table) =>
      buildStorageCleanupJobs(
        [table.bucket, "pending-images"],
        pathsByTable[table.name] || [],
      )
    );
    if (!await enqueueStorageCleanup(url, serviceKey, cleanupJobs)) {
      console.error("Could not enqueue account image cleanup", user.id);
      return reply({ error: "تعذّر تجهيز تنظيف الصور بأمان. لم يقع حذف أي إعلان أو الحساب." }, 503);
    }

    // Remove the user's four categories of posts. Retrying is safe if a later step fails.
    for (const table of tables) {
      const removeRows = await api(
        url,
        serviceKey,
        "/rest/v1/" + table.name + "?user_id=eq." + encodeURIComponent(user.id),
        { method: "DELETE", headers: { "Prefer": "return=minimal" } },
      );
      if (!removeRows.ok) {
        console.error("Account post cleanup failed", table.name, removeRows.status);
        return reply({ error: "تعذّر حذف كل الإعلانات المرتبطة بالحساب. الحساب مازال موجوداً؛ عاود المحاولة." }, 502);
      }
    }

    // Drain queued cleanup jobs before deleting the Auth user. Any failure leaves durable pending jobs.
    if (!await activateStorageCleanup(url, serviceKey, cleanupJobs)) {
      return reply({ error: "تم حذف الإعلانات، لكن تعذّر تفعيل مهام تنظيف الصور. الحساب مازال موجوداً." }, 502);
    }


    for (const job of cleanupJobs) {
      const encoded = job.object_path.split("/").map(encodeURIComponent).join("/");
      const head = await fetch(url + "/storage/v1/object/info/" + job.bucket + "/" + encoded, {
        method: "HEAD",
        headers: { apikey: serviceKey, Authorization: "Bearer " + serviceKey },
      });
      if (head.status === 404) {
        if (!await completeStorageCleanup(url, serviceKey, job)) {
          return reply({ error: "بقي تحديث سجل تنظيف الصور معلقاً؛ الحساب مازال موجوداً." }, 502);
        }
        continue;
      }
      if (!head.ok) {
        await recordStorageCleanupFailure(url, serviceKey, job, "Storage HEAD returned " + head.status);
        console.error("Account cleanup HEAD failed", job.bucket, head.status);
        return reply({ error: "تعذّر تنظيف بعض الصور. مهمة التنظيف محفوظة والحساب مازال موجوداً." }, 502);
      }
      const remove = await api(url, serviceKey, "/storage/v1/object/" + job.bucket, {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ prefixes: [job.object_path] }),
      });
      if (!remove.ok) {
        await recordStorageCleanupFailure(url, serviceKey, job, "Storage DELETE returned " + remove.status);
        console.error("Account image cleanup failed", job.bucket, remove.status);
        return reply({ error: "تعذّر تنظيف بعض الصور. مهمة التنظيف محفوظة والحساب مازال موجوداً." }, 502);
      }
      if (!await completeStorageCleanup(url, serviceKey, job)) {
        return reply({ error: "تم تنظيف الصور لكن بقي تحديث سجل التنظيف؛ الحساب مازال موجوداً." }, 502);
      }
    }

    const deleteUser = await fetch(url + "/auth/v1/admin/users/" + encodeURIComponent(user.id), {
      method: "DELETE",
      headers: { "apikey": serviceKey, "Authorization": "Bearer " + serviceKey },
    });
    if (!deleteUser.ok) {
      const detail = await deleteUser.text().catch(() => "");
      console.error("Auth user deletion failed", deleteUser.status, detail.slice(0, 300));
      return reply({ error: "تم تنظيف الإعلانات، لكن تعذّر إكمال حذف الحساب. عاود المحاولة أو تواصل مع الإدارة." }, 502);
    }

    return reply({ ok: true, message: "تم حذف الحساب والإعلانات والصور المرتبطة به." });
  } catch (error) {
    console.error("delete-account error", String(error));
    return reply({ error: "صار خطأ غير متوقع. لم نتمكن من تأكيد اكتمال حذف الحساب." }, 500);
  }
});
