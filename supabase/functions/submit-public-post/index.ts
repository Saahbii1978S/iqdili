// READ-ONLY RECOVERY SNAPSHOT
// Exported from active Supabase Edge Function "submit-public-post" on 2026-11-15.
// Deployed version at export: 8.
// This file is preserved for audit/recovery only; do not deploy without separate review and approval.
// Runtime secrets remain environment variables and are not included in this snapshot.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { readLimitedRequest } from "../_shared/request-size.ts";

const ALLOWED_ORIGIN = "https://saahbii1978s.github.io";
const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Vary": "Origin",
};
const reply = (payload: unknown, status = 200) =>
  new Response(JSON.stringify(payload), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);

function textField(value: unknown, max: number, required = false): string | null {
  if (typeof value !== "string") return required ? null : "";
  const result = value.trim();
  if (result.length > max || (required && !result)) return null;
  return result;
}
function optionalNumber(value: unknown, integer = false): number | null | undefined {
  if (value === null || value === undefined || value === "") return null;
  const number = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(number) || number < 0) return undefined;
  if (integer && !Number.isInteger(number)) return undefined;
  return number;
}
function imagePaths(value: unknown, folder: string): string[] | null {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.length > 1) return null;
  if (value.length === 0) return [];
  const path = value[0];
  if (typeof path !== "string" || path.length > 220) return null;
  if (!path.startsWith(folder + "/") || !/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)) return null;
  if (path.includes("..") || path.includes("//")) return null;
  return [path];
}
function validImageSignature(bytes: Uint8Array, mime: string): boolean {
  if (mime === "image/jpeg") return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (mime === "image/png") return bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a;
  if (mime === "image/webp") return bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" && String.fromCharCode(...bytes.slice(8, 12)) === "WEBP";
  return false;
}
async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}


async function sendAdminAlert(subject: string, textContent: string): Promise<void> {
  const apiKey = Deno.env.get("BREVO_API_KEY");
  const recipient = Deno.env.get("ADMIN_ALERT_EMAIL");
  const sender = Deno.env.get("BREVO_SENDER_EMAIL");
  if (!apiKey || !recipient || !sender) {
    console.warn("Admin email alerts are not fully configured");
    return;
  }
  try {
    const response = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: {
        "accept": "application/json",
        "api-key": apiKey,
        "content-type": "application/json"
      },
      body: JSON.stringify({
        sender: { name: "أحلى توانسة", email: sender },
        to: [{ email: recipient }],
        subject,
        textContent
      }),
      signal: AbortSignal.timeout(7000)
    });
    if (!response.ok) {
      console.error("Admin email alert failed", response.status);
    }
  } catch (error) {
    console.error("Admin email alert exception", String(error));
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "طريقة الطلب غير مدعومة." }, 405);
  if (req.headers.get("origin") !== ALLOWED_ORIGIN) return reply({ error: "مصدر الطلب غير مسموح." }, 403);

  try {
    const contentType = req.headers.get("content-type") || "";
    const isMultipart = contentType.toLowerCase().includes("multipart/form-data");
    const boundedRequest = await readLimitedRequest(req, isMultipart ? 4000000 : 20000);
    if (!boundedRequest) return reply({ error: "حجم الطلب كبير أكثر من اللازم." }, 413);

    let table: unknown;
    let data: unknown;
    let token = "";
    let file: File | null = null;
    if (isMultipart) {
      const form = await boundedRequest.formData();
      table = form.get("table");
      token = typeof form.get("turnstileToken") === "string" ? String(form.get("turnstileToken")) : "";
      const rawData = form.get("data");
      if (typeof rawData !== "string" || rawData.length > 18000) return reply({ error: "المعلومات المرسلة غير صحيحة." }, 400);
      try { data = JSON.parse(rawData); } catch { return reply({ error: "المعلومات المرسلة غير صحيحة." }, 400); }
      const uploaded = form.get("file");
      if (uploaded !== null) {
        if (!(uploaded instanceof File)) return reply({ error: "ما وصلتناش صورة صالحة." }, 400);
        file = uploaded;
      }
    } else {
      const body = await boundedRequest.json();
      if (!isRecord(body)) return reply({ error: "المعلومات المرسلة غير صحيحة." }, 400);
      table = body.table;
      data = body.data;
      token = typeof body.turnstileToken === "string" ? body.turnstileToken : "";
    }
    if (!isRecord(data)) return reply({ error: "المعلومات المرسلة غير صحيحة." }, 400);

    const turnstileSecret = Deno.env.get("TURNSTILE_SECRET_KEY");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!turnstileSecret || !supabaseUrl || !serviceRoleKey) {
      console.error("Submission environment is incomplete");
      return reply({ error: "خدمة الحماية والحفظ غير مهيّأة حالياً." }, 503);
    }
    let memberUserId: string | null = null;
    const authorization = req.headers.get("authorization") || "";
    if (authorization) {
      if (!authorization.startsWith("Bearer ") || authorization.length > 5000) {
        return reply({ error: "جلسة الحساب غير صالحة. عاود تسجيل الدخول." }, 401);
      }
      const memberResponse = await fetch(supabaseUrl + "/auth/v1/user", {
        headers: { "apikey": serviceRoleKey, "Authorization": authorization },
      });
      if (!memberResponse.ok) return reply({ error: "جلسة الحساب انتهت. عاود تسجيل الدخول." }, 401);
      const member = await memberResponse.json().catch(() => ({}));
      if (typeof member.id !== "string") return reply({ error: "تعذّر التثبت من الحساب." }, 401);
      memberUserId = member.id;
    }
    if (!token || token.length > 2048) return reply({ error: "كمّل التحقق من الحماية قبل إرسال الإعلان." }, 400);
    const verificationResponse = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ secret: turnstileSecret, response: token }),
    });
    const verification = await verificationResponse.json().catch(() => ({}));
    if (!verificationResponse.ok || verification.success !== true || verification.hostname !== "saahbii1978s.github.io") {
      console.warn("Turnstile verification rejected", verification["error-codes"] || []);
      return reply({ error: "التحقق ما نجحش. عاود التحقق من Cloudflare." }, 403);
    }

    const allowedTables = ["service_requests", "job_posts", "real_estate_posts", "market_posts"];
    if (typeof table !== "string" || !allowedTables.includes(table)) return reply({ error: "نوع الإعلان غير مدعوم." }, 400);
    const folderByTable: Record<string, string> = {
      service_requests: "services", job_posts: "jobs", real_estate_posts: "realty", market_posts: "market",
    };

    const title = textField(data.title, 120, true);
    const description = textField(data.description, table === "service_requests" ? 1600 : 1500);
    const city = textField(data.city, 100, true);
    const phone = textField(data.phone, 20, true);
    if (title === null || description === null || city === null || phone === null) {
      return reply({ error: "راجع العنوان والوصف والمنطقة ورقم الهاتف." }, 400);
    }
    const digits = phone.replace(/\D/g, "");
    if (digits.length < 8 || digits.length > 15) return reply({ error: "رقم الهاتف يلزمو بين 8 و15 رقم." }, 400);

    const row: Record<string, unknown> = {
      title, description, city, phone, contact_public: data.contact_public === true, image_urls: [], status: "pending",
    };
    if (memberUserId) row.user_id = memberUserId;
    if (table === "job_posts") {
      const jobType = textField(data.job_type, 60);
      const workNature = textField(data.work_nature, 60);
      if (jobType === null || workNature === null) return reply({ error: "راجع نوع إعلان العمل." }, 400);
      row.job_type = jobType; row.work_nature = workNature;
    }
    if (table === "real_estate_posts") {
      const propertyType = textField(data.property_type, 60);
      const listingType = textField(data.listing_type, 60);
      const price = optionalNumber(data.price);
      const size = optionalNumber(data.size);
      const rooms = optionalNumber(data.rooms, true);
      if (propertyType === null || listingType === null || price === undefined || size === undefined || rooms === undefined) {
        return reply({ error: "راجع نوع العقار والسعر والمساحة وعدد الغرف." }, 400);
      }
      row.property_type = propertyType; row.listing_type = listingType; row.price = price; row.size = size; row.rooms = rooms;
    }
    if (table === "market_posts") {
      const category = textField(data.category, 60);
      const listingType = textField(data.listing_type, 60);
      const price = optionalNumber(data.price);
      if (category === null || listingType === null || price === undefined) return reply({ error: "راجع صنف المنتج ونوع الإعلان والسعر." }, 400);
      row.category = category; row.listing_type = listingType; row.price = price;
    }

    let uploadedPath = "";
    if (file) {
      if (file.size < 1 || file.size > 3145728) return reply({ error: "حجم الصورة لازم ما يفوتش 3 ميغابايت." }, 413);
      if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) return reply({ error: "الصورة لازم تكون JPG أو PNG أو WebP." }, 415);

      const bytes = new Uint8Array(await file.arrayBuffer());
      if (!validImageSignature(bytes, file.type)) return reply({ error: "محتوى الملف ما يطابقش نوع الصورة المعلن." }, 415);

      const clientIp = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip") || "";
      if (!clientIp) return reply({ error: "تعذّر التثبت من الاتصال. عاود المحاولة." }, 503);
      const fingerprint = await sha256(clientIp + ":" + serviceRoleKey);
      const limitResponse = await fetch(supabaseUrl + "/rest/v1/rpc/consume_pending_image_rate_limit", {
        method: "POST",
        headers: { "apikey": serviceRoleKey, "Authorization": "Bearer " + serviceRoleKey, "Content-Type": "application/json" },
        body: JSON.stringify({ p_fingerprint: fingerprint }),
      });
      if (!limitResponse.ok) {
        console.error("Pending image rate limit check failed", limitResponse.status);
        return reply({ error: "الحماية غير متوفرة حالياً. عاود بعد شوية." }, 503);
      }
      if (await limitResponse.json().catch(() => false) !== true) return reply({ error: "وصلت للحدّ المسموح لرفع الصور. عاود بعد ساعة." }, 429);
      const extension = file.type === "image/jpeg" ? "jpg" : file.type === "image/png" ? "png" : "webp";
      uploadedPath = folderByTable[table] + "/" + crypto.randomUUID() + "." + extension;
      const uploadResponse = await fetch(supabaseUrl + "/storage/v1/object/pending-images/" + uploadedPath.split("/").map(encodeURIComponent).join("/"), {
        method: "POST",
        headers: { "apikey": serviceRoleKey, "Authorization": "Bearer " + serviceRoleKey, "Content-Type": file.type, "Cache-Control": "3600", "x-upsert": "false" },
        body: bytes,
      });
      if (!uploadResponse.ok) {
        const detail = await uploadResponse.text().catch(() => "");
        console.error("Private image upload failed", uploadResponse.status, detail.slice(0, 300));
        return reply({ error: "ما نجّمش نخزّن الصورة بأمان. عاود المحاولة." }, 502);
      }
      row.image_urls = [uploadedPath];
    } else {
      const images = imagePaths(data.image_urls, folderByTable[table]);
      if (images === null) return reply({ error: "مسار الصورة غير صحيح." }, 400);
      row.image_urls = images;
      if (images.length) {
        const imagePath = images[0].split("/").map(encodeURIComponent).join("/");
        const pendingImage = await fetch(supabaseUrl + "/storage/v1/object/info/pending-images/" + imagePath, {
          method: "HEAD", headers: { "apikey": serviceRoleKey, "Authorization": "Bearer " + serviceRoleKey },
        });
        if (!pendingImage.ok) return reply({ error: "الصورة ما ترفعتش عبر خدمة الرفع الآمنة. عاود رفعها قبل إرسال الإعلان." }, 400);
      }
    }

    const insertResponse = await fetch(supabaseUrl + "/rest/v1/" + table, {
      method: "POST",
      headers: { "apikey": serviceRoleKey, "Authorization": "Bearer " + serviceRoleKey, "Content-Type": "application/json", "Prefer": "return=minimal" },
      body: JSON.stringify(row),
    });
    if (!insertResponse.ok) {
      const dbError = await insertResponse.json().catch(() => ({}));
      const message = typeof dbError.message === "string" ? dbError.message : "";
      console.error("Protected post insert failed", table, insertResponse.status, message);
      if (uploadedPath) {
        await fetch(supabaseUrl + "/storage/v1/object/pending-images/" + uploadedPath.split("/").map(encodeURIComponent).join("/"), {
          method: "DELETE", headers: { "apikey": serviceRoleKey, "Authorization": "Bearer " + serviceRoleKey },
        }).catch(() => undefined);
      }
      if (message.includes("ساعة") || message.includes("رقم الهاتف")) return reply({ error: message }, 429);
      return reply({ error: "ما نجّمش نحفظ الإعلان حالياً. تثبّت من المعلومات وعاود المحاولة." }, 400);
    }
    const categoryLabels: Record<string, string> = { service_requests: "الخدمات", job_posts: "فرص العمل", real_estate_posts: "العقارات", market_posts: "السوق" };
    await sendAdminAlert("إعلان جديد ينتظر المراجعة", `وصل إعلان جديد إلى أحلى توانسة.\nالقسم: ${categoryLabels[table] || "غير محدد"}\nالعنوان: ${title}\nالمدينة: ${city}\nالحالة: في انتظار المراجعة.`);
    return reply({ ok: true, message: "وصل الإعلان للإدارة للمراجعة." });
  } catch (error) {
    await sendAdminAlert("خطأ تقني في استقبال الإعلانات", "تعذّر إكمال طلب إرسال إعلان. راجع سجلات Supabase لمعرفة التفاصيل.");
    console.error("submit-public-post error", String(error));
    return reply({ error: "صار خطأ في الاتصال. عاود المحاولة بعد قليل." }, 500);
  }
});
