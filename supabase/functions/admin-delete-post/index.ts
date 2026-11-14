import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const ORIGIN="https://saahbii1978s.github.io";
const cors={"Access-Control-Allow-Origin":ORIGIN,"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const reply=(v:unknown,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{...cors,"Content-Type":"application/json"}});

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

const cfg:Record<string,{bucket:string,folder:string}>={service_requests:{bucket:"listing-images",folder:"services"},job_posts:{bucket:"listing-images",folder:"jobs"},real_estate_posts:{bucket:"listing-images",folder:"realty"},market_posts:{bucket:"market-images",folder:"market"}};
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST")return reply({error:"طريقة الطلب غير مدعومة."},405);
 if(req.headers.get("origin")!==ORIGIN)return reply({error:"مصدر الطلب غير مسموح."},403);
 try{
  const url=Deno.env.get("SUPABASE_URL")!,key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth=req.headers.get("authorization")||"";
  if(!auth.startsWith("Bearer "))return reply({error:"الدخول للإدارة غير مصرح."},401);
  const u=await fetch(url+"/auth/v1/user",{headers:{apikey:key,Authorization:auth}});
  if(!u.ok)return reply({error:"الدخول للإدارة غير مصرح."},401);
  const check=await fetch(url+"/rest/v1/rpc/is_owner",{method:"POST",headers:{apikey:key,Authorization:auth,"Content-Type":"application/json"},body:"{}"});
  if(!check.ok||(await check.json().catch(()=>false))!==true)return reply({error:"صلاحية الإدارة غير متوفرة."},403);
  const body=await req.json(),table=body?.table,id=body?.id,deleteTest=body?.delete_test===true;
  if(typeof table!=="string"||!Object.hasOwn(cfg,table)||!(typeof id==="string"||typeof id==="number")||String(id).length>30)return reply({error:"الطلب غير صالح."},400);
  const rowRes=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&select=id,title,description,image_urls",{headers:{apikey:key,Authorization:"Bearer "+key}});
  if(!rowRes.ok)return reply({error:"تعذّر تحميل الإعلان."},502);
  const rows=await rowRes.json();if(!Array.isArray(rows)||rows.length!==1)return reply({error:"الإعلان غير موجود."},404);
  const protectedDemoIds:Record<string,string[]>={service_requests:["13"],job_posts:["7"],market_posts:["2","3","7","8","9"],real_estate_posts:["1","2","6"]};
  const demoText=(String(rows[0].title||"")+" "+String(rows[0].description||"")).toLowerCase();
  const isKnownDemo=(protectedDemoIds[table]||[]).includes(String(id)) || /(تجريب|تجريبي|اختبار|test|demo|مثال)/i.test(demoText);
  if(isKnownDemo&&!deleteTest)return reply({error:"هذا إعلان تجريبي محمي. استعمل زر حذف إعلان تجريبي بصلاحية صاحب المشروع."},403);
  if(deleteTest&&!isKnownDemo)return reply({error:"رفض الحذف: الإعلان غير مصنّف كتجربة."},403);
  const paths=Array.isArray(rows[0].image_urls)?rows[0].image_urls:[];
  for(const path of paths){if(typeof path!=="string"||!path.startsWith(cfg[table].folder+"/")||!/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)||path.includes("..")||path.includes("//"))return reply({error:"مسار صورة غير صالح؛ لم يقع حذف الإعلان."},409);}
  const del=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id)),{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,Prefer:"return=representation"}});
  if(!del.ok){
   const detail=await del.text().catch(()=>"");
   console.error("admin-delete-post database DELETE failed",JSON.stringify({table,id,status:del.status,detail:detail.slice(0,1200)}));
   return reply({error:"تعذّر حذف سجل الإعلان من قاعدة البيانات. الصور قد تكون حُذفت؛ راجع الإدارة أو أعد المحاولة بعد الإصلاح."},502);
  }
  const deleted=await del.json().catch(()=>null);
  if(!Array.isArray(deleted)||!deleted.length)return reply({error:"الإعلان لم يعد موجوداً في قاعدة البيانات."},409);
  // Remove images only after the database row is gone, so a storage failure cannot leave a live post without its images.
  for(const bucket of [cfg[table].bucket,"pending-images"]){
   if(!paths.length)continue;
   const rm=await fetch(url+"/storage/v1/object/"+bucket,{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},body:JSON.stringify({prefixes:paths})});
   if(!rm.ok){
    console.error("Admin post deleted but image cleanup is pending",bucket,rm.status);
    await sendAdminAlert("تنبيه تنظيف صور إعلان محذوف","تم حذف سجل الإعلان من قاعدة البيانات، لكن بقيت صور تحتاج تنظيفاً.\nالقسم: "+table+"\nرقم الإعلان: "+id+"\nالمخزن: "+bucket);
    return reply({ok:true,cleanupPending:true,message:"تم حذف الإعلان، لكن بقيت صور تحتاج تنظيفاً. تم إعلام الإدارة."});
   }
  }
  await sendAdminAlert("تم حذف إعلان من إدارة أحلى توانسة", `تم حذف إعلان من لوحة الإدارة.\nالقسم: ${table}\nرقم الإعلان: ${id}`);
  return reply({ok:true,message:"تم حذف الإعلان وصوره نهائياً."});
 }catch(e){await sendAdminAlert("خطأ تقني أثناء حذف إعلان","تعذّر إكمال عملية حذف إعلان. راجع سجلات Supabase لمعرفة التفاصيل.");console.error("admin-delete-post",String(e));return reply({error:"صار خطأ أثناء الحذف."},500);}
});