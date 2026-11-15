// READ-ONLY RECOVERY SNAPSHOT
// Exported from active Supabase Edge Function "upload-pending-image" on 2026-11-15.
// Deployed version at export: 6.
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
const folders: Record<string, string> = { services: "services", jobs: "jobs", realty: "realty", market: "market" };

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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "طريقة الطلب غير مدعومة." }, 405);
  if (req.headers.get("origin") !== ALLOWED_ORIGIN) return reply({ error: "مصدر الطلب غير مسموح." }, 403);
  try {
    const turnstileSecret = Deno.env.get("TURNSTILE_SECRET_KEY");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!turnstileSecret || !supabaseUrl || !serviceRoleKey) {
      console.error("Pending image upload environment is incomplete");
      return reply({ error: "خدمة رفع الصور غير مهيّأة حالياً." }, 503);
    }

    const boundedRequest = await readLimitedRequest(req, 4000000);
    if (!boundedRequest) return reply({ error: "حجم الطلب كبير أكثر من اللازم." }, 413);
    const form = await boundedRequest.formData();
    const token = form.get("turnstileToken");
    if (typeof token !== "string" || !token || token.length > 2048) {
      return reply({ error: "كمّل التحقق من Cloudflare قبل رفع الصورة." }, 400);
    }
    const verifyResponse = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ secret: turnstileSecret, response: token }),
    });
    const verification = await verifyResponse.json().catch(() => ({}));
    if (!verifyResponse.ok || verification.success !== true || verification.hostname !== "saahbii1978s.github.io") {
      console.warn("Pending image Turnstile verification rejected", verification["error-codes"] || []);
      return reply({ error: "التحقق من Cloudflare ما نجحش. عاود المحاولة." }, 403);
    }

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
    if (await limitResponse.json().catch(() => false) !== true) {
      return reply({ error: "وصلت للحدّ المسموح لرفع الصور. عاود بعد ساعة." }, 429);
    }

    const category = form.get("category");
    const file = form.get("file");
    if (typeof category !== "string" || !Object.hasOwn(folders, category)) return reply({ error: "قسم الصورة غير صحيح." }, 400);
    if (!(file instanceof File)) return reply({ error: "ما وصلتناش صورة صالحة." }, 400);
    if (file.size < 1 || file.size > 3145728) return reply({ error: "حجم الصورة لازم ما يفوتش 3 ميغابايت." }, 413);
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) return reply({ error: "الصورة لازم تكون JPG أو PNG أو WebP." }, 415);
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (!validImageSignature(bytes, file.type)) return reply({ error: "محتوى الملف ما يطابقش نوع الصورة المعلن." }, 415);

    const extension = file.type === "image/jpeg" ? "jpg" : file.type === "image/png" ? "png" : "webp";
    const path = folders[category] + "/" + crypto.randomUUID() + "." + extension;
    const uploadResponse = await fetch(supabaseUrl + "/storage/v1/object/pending-images/" + path.split("/").map(encodeURIComponent).join("/"), {
      method: "POST",
      headers: { "apikey": serviceRoleKey, "Authorization": "Bearer " + serviceRoleKey, "Content-Type": file.type, "Cache-Control": "3600", "x-upsert": "false" },
      body: bytes,
    });
    if (!uploadResponse.ok) {
      const detail = await uploadResponse.text().catch(() => "");
      console.error("Private pending image upload failed", uploadResponse.status, detail.slice(0, 300));
      return reply({ error: "ما نجّمش نخزّن الصورة بأمان. عاود المحاولة." }, 502);
    }
    return reply({ ok: true, bucket: "pending-images", path });
  } catch (error) {
    console.error("upload-pending-image error", String(error));
    return reply({ error: "صار خطأ أثناء رفع الصورة. عاود المحاولة." }, 500);
  }
});