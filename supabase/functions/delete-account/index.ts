import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { hasRecentAuthentication } from "../_shared/recent-auth.ts";
import { readLimitedRequest } from "../_shared/request-size.ts";
import { buildStorageCleanupJobs, enqueueStorageCleanup } from "../_shared/storage-cleanup-queue.ts";
import { isProtectedDemoPost } from "../_shared/protected-demo.ts";

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

    // Three attempts per verified account per hour. Existing deletion locks remain retryable.
    const rateLimit = await api(
      url,
      serviceKey,
      "/rest/v1/rpc/consume_account_deletion_rate_limit",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ p_user_id: user.id }),
      },
    );
    if (!rateLimit.ok) {
      console.error("Account deletion rate limit check failed", rateLimit.status);
      return reply({ error: "حماية حذف الحساب غير متوفرة حالياً. عاود بعد شوية." }, 503);
    }
    if (await rateLimit.json().catch(() => false) !== true) {
      return reply({ error: "وصلت للحدّ المسموح لمحاولات حذف الحساب. عاود بعد ساعة." }, 429);
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

    const countCheck = await api(
      url,
      serviceKey,
      "/rest/v1/rpc/account_post_count_within_limit",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ p_user_id: user.id }),
      },
    );
    if (!countCheck.ok) {
      console.error("Account listing count check failed", countCheck.status);
      return reply({ error: "تعذّر التثبت من عدد إعلانات الحساب. لم يتم حذف أي بيانات." }, 503);
    }
    if (await countCheck.json().catch(() => false) !== true) {
      return reply({ error: "عدد الإعلانات المرتبطة بالحساب بلغ الحدّ الأقصى (10,000). تواصل مع الإدارة لإتمام الحذف بأمان." }, 413);
    }

    const rowsByTable: Record<string, Array<Record<string, unknown>>> = {};
    for (const table of tables) {
      const all: Array<Record<string, unknown>> = [];
      let complete = false;
      for (let offset = 0; offset < 10000; offset += 1000) {
        const query = new URLSearchParams({
          select: "*",
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

    // Use the same protected-demo policy as every post deletion/status endpoint.
    for (const table of tables) {
      for (const row of rowsByTable[table.name] || []) {
        if (isProtectedDemoPost(table.name, row.id as string | number, row.title, row.description)) {
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
    if (cleanupJobs.length > 500) {
      return reply({ error: "عدد الصور المرتبطة بالحساب كبير. يلزم مراجعة الإدارة قبل الحذف الآمن." }, 413);
    }
    if (!await enqueueStorageCleanup(url, serviceKey, cleanupJobs)) {
      console.error("Could not enqueue account image cleanup", user.id);
      return reply({ error: "تعذّر تجهيز تنظيف الصور بأمان. لم يقع حذف أي إعلان أو الحساب." }, 503);
    }

    // Delete all four listing categories and activate their exact image jobs in one database transaction.
    const deletion = await api(
      url,
      serviceKey,
      "/rest/v1/rpc/delete_account_posts_and_activate_cleanup",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          p_user_id: user.id,
          p_jobs: cleanupJobs,
          p_expected_rows: {
            service_requests: rowsByTable.service_requests || [],
            job_posts: rowsByTable.job_posts || [],
            real_estate_posts: rowsByTable.real_estate_posts || [],
            market_posts: rowsByTable.market_posts || [],
          },
        }),
      },
    );
    if (!deletion.ok) {
      const detail = await deletion.text().catch(() => "");
      console.error("Atomic account post cleanup failed", deletion.status, detail.slice(0, 500));
      return reply({ error: "تغيّرت إعلانات الحساب أثناء العملية أو تعذّر تجهيز تنظيف الصور. لم يقع حذف الحساب؛ عاود المحاولة." }, 409);
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

    return reply({ ok: true, cleanupPending: cleanupJobs.length > 0, message: cleanupJobs.length ? "تم حذف الحساب والإعلانات. تنظيف الصور المرتبطة بها جارٍ في الخلفية." : "تم حذف الحساب والإعلانات." });
  } catch (error) {
    console.error("delete-account error", String(error));
    return reply({ error: "صار خطأ غير متوقع. لم نتمكن من تأكيد اكتمال حذف الحساب." }, 500);
  }
});
