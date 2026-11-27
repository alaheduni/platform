// =====================================================
// Al-Ahd-Platform : Edge Function باسم create-member
// بتخلي المسؤول أو الأدمن يضيف عضو ويعمل إله حساب بأمان.
// منشورة أصلاً على Supabase (Edge Functions). هاد الملف نسخة احتياطية فقط.
// مكانها المقترح بـ GitHub: supabase/functions/create-member/index.ts
// =====================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // 1) مين اللي عم يطلب؟
  const userClient = createClient(url, anon, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return json({ error: "لازم تسجلي دخول" }, 401);

  const admin = createClient(url, service);

  // 2) شو دوره وجامعته؟
  const { data: me } = await admin
    .from("profiles")
    .select("university_id, role_id")
    .eq("user_id", user.id)
    .maybeSingle();
  if (!me) return json({ error: "ما في صلاحية" }, 403);

  const { data: myRole } = await admin
    .from("roles").select("code").eq("id", me.role_id).single();
  const myCode = myRole?.code;
  if (myCode !== "admin" && myCode !== "coordinator") {
    return json({ error: "ما في صلاحية" }, 403);
  }

  // 3) قراءة البيانات والتحقق منها
  const body = await req.json().catch(() => ({}));
  const full_name = String(body.full_name ?? "").trim();
  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  if (!full_name || !email || password.length < 8) {
    return json({ error: "الاسم والإيميل مطلوبين، وكلمة السر 8 أحرف على الأقل" }, 400);
  }

  // 4) تحديد الدور والجامعة حسب صلاحية الطالب
  let targetRole = "member";
  let universityId = me.university_id;
  if (myCode === "admin") {
    targetRole = body.role === "coordinator" ? "coordinator" : "member";
    universityId = body.university_id ?? null;
  }
  if (!universityId) return json({ error: "لازم تحديد الجامعة" }, 400);

  const { data: roleRow } = await admin
    .from("roles").select("id").eq("code", targetRole).single();
  if (!roleRow) return json({ error: "الدور غير موجود" }, 400);

  // 5) إنشاء الحساب
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name },
  });
  if (createErr || !created.user) {
    return json({ error: createErr?.message ?? "فشل إنشاء الحساب" }, 400);
  }

  // 6) ربطه بجدول profiles (upsert عشان لو في trigger عمل صف قبل)
  const { error: profErr } = await admin.from("profiles").upsert(
    {
      user_id: created.user.id,
      full_name,
      email,
      role_id: roleRow.id,
      university_id: universityId,
      is_active: true,
    },
    { onConflict: "user_id" },
  );
  if (profErr) {
    await admin.auth.admin.deleteUser(created.user.id);
    return json({ error: profErr.message }, 400);
  }

  return json({ ok: true, user_id: created.user.id });
});
