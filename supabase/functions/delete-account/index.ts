import "jsr:@supabase/functions-js/edge-runtime.d.ts";

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

    const body = await req.json().catch(() => null);
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

    const rowsByTable: Record<string, Array<{ id: number; image_urls?: string[] }>> = {};
    for (const table of tables) {
      const all: Array<{ id: number; image_urls?: string[] }> = [];
      let complete = false;
      for (let offset = 0; offset < 10000; offset += 1000) {
        const query = new URLSearchParams({
          select: "id,image_urls",
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

    // Storage cleanup starts only after all database row deletions succeeded.
    // A database failure above therefore cannot leave a live post without its image.
    for (const table of tables) {
      const paths = pathsByTable[table.name] || [];
      for (let i = 0; i < paths.length; i += 100) {
        const batch = paths.slice(i, i + 100);
        for (const bucket of [table.bucket, "pending-images"]) {
          const remove = await api(url, serviceKey, "/storage/v1/object/" + bucket, {
            method: "DELETE",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ prefixes: batch }),
          });
          if (!remove.ok) {
            console.error("Account image cleanup failed after database deletion", bucket, remove.status);
            return reply({ error: "تم حذف الإعلانات، لكن تعذّر تنظيف بعض الصور. الحساب مازال موجوداً؛ تواصل مع الإدارة لإتمام التنظيف." }, 502);
          }
        }
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
