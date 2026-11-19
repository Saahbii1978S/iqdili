import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const ALLOWED_ORIGINS = new Set(["https://saahbii1978s.github.io", "https://ahla-tounsa-project.github.io"]);
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Vary": "Origin",
};
const reply = (payload: unknown, status = 200) =>
  new Response(JSON.stringify(payload), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  if (!ALLOWED_ORIGINS.has(req.headers.get("origin") || "")) return reply({ error: "Origin not allowed" }, 403);

  const authorization = req.headers.get("authorization") || "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const apiKey = Deno.env.get("BREVO_API_KEY");
  const recipient = Deno.env.get("ADMIN_ALERT_EMAIL");
  const sender = Deno.env.get("BREVO_SENDER_EMAIL");

  if (!authorization.startsWith("Bearer ") || !supabaseUrl || !serviceRoleKey) {
    return reply({ error: "Authentication or server configuration unavailable" }, 401);
  }
  if (!apiKey || !recipient || !sender) {
    console.error("Admin signup email alerts are not fully configured");
    return reply({ error: "Admin email alerts are not configured" }, 503);
  }

  try {
    const authResponse = await fetch(supabaseUrl + "/auth/v1/user", {
      headers: { apikey: serviceRoleKey, Authorization: authorization },
    });
    if (!authResponse.ok) return reply({ error: "Invalid session" }, 401);
    const user = await authResponse.json();
    if (typeof user.id !== "string" || typeof user.email !== "string" || !user.email_confirmed_at) {
      return reply({ error: "A confirmed email account is required" }, 403);
    }

    const eventUrl = new URL(supabaseUrl + "/rest/v1/admin_notification_events");
    eventUrl.searchParams.set("on_conflict", "user_id,event_type");
    const insertResponse = await fetch(eventUrl, {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: "Bearer " + serviceRoleKey,
        "Content-Type": "application/json",
        Prefer: "resolution=ignore-duplicates,return=representation",
      },
      body: JSON.stringify({ user_id: user.id, event_type: "signup_confirmed" }),
    });
    if (!insertResponse.ok) {
      console.error("Could not record signup notification", insertResponse.status);
      return reply({ error: "Could not record notification" }, 500);
    }
    const inserted = await insertResponse.json().catch(() => []);
    if (!Array.isArray(inserted) || inserted.length === 0) {
      return reply({ ok: true, alreadyNotified: true });
    }

    const confirmedAt = new Date(user.email_confirmed_at).toLocaleString("ar-TN", { timeZone: "Africa/Tunis" });
    const createdAt = user.created_at
      ? new Date(user.created_at).toLocaleString("ar-TN", { timeZone: "Africa/Tunis" })
      : "غير متوفر";
    const emailResponse = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: {
        accept: "application/json",
        "api-key": apiKey,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        sender: { name: "أحلى توانسة", email: sender },
        to: [{ email: recipient }],
        subject: "تسجيل عضو جديد مؤكّد - أحلى توانسة",
        textContent:
          "تم تأكيد بريد عضو جديد في منصة أحلى توانسة.\n" +
          "البريد الإلكتروني: " + user.email + "\n" +
          "تاريخ إنشاء الحساب: " + createdAt + "\n" +
          "تاريخ تأكيد البريد: " + confirmedAt + "\n" +
          "ملاحظة: لم يتم إرسال كلمة المرور أو أي رمز تحقق.",
      }),
      signal: AbortSignal.timeout(8000),
    });

    if (!emailResponse.ok) {
      const details = await emailResponse.text().catch(() => "");
      console.error("Brevo signup alert failed", emailResponse.status, details.slice(0, 300));
      const deleteUrl = new URL(supabaseUrl + "/rest/v1/admin_notification_events");
      deleteUrl.searchParams.set("user_id", "eq." + user.id);
      deleteUrl.searchParams.set("event_type", "eq.signup_confirmed");
      await fetch(deleteUrl, {
        method: "DELETE",
        headers: { apikey: serviceRoleKey, Authorization: "Bearer " + serviceRoleKey },
      }).catch(() => undefined);
      return reply({ error: "Could not send admin notification" }, 502);
    }

    return reply({ ok: true, notified: true });
  } catch (error) {
    console.error("notify-admin-new-user error", String(error));
    return reply({ error: "Notification service failed" }, 500);
  }
});
