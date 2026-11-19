import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const ALLOWED_ORIGINS = new Set(["https://saahbii1978s.github.io", "https://ahla-tounsa-project.github.io"]);
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const reply=(v:unknown,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{...cors,"Content-Type":"application/json"}});
const tables=["service_requests","job_posts","real_estate_posts","market_posts"];
const protectedDemoIds:Record<string,string[]>={service_requests:["13"],job_posts:["7"],market_posts:["2","3","7","8","9"],real_estate_posts:["1","2","6"]};
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST")return reply({error:"طريقة الطلب غير مدعومة."},405);
 if(!ALLOWED_ORIGINS.has(req.headers.get("origin") || ""))return reply({error:"مصدر الطلب غير مسموح."},403);
 try{
  const url=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const auth=req.headers.get("authorization")||"";
  if(!url||!key||!auth.startsWith("Bearer "))return reply({error:"الدخول للإدارة غير مصرح."},401);
  const userRes=await fetch(url+"/auth/v1/user",{headers:{apikey:key,Authorization:auth}});
  if(!userRes.ok)return reply({error:"جلسة الدخول غير صالحة."},401);
  const user=await userRes.json();
  const check=await fetch(url+"/rest/v1/rpc/is_admin",{method:"POST",headers:{apikey:key,Authorization:auth,"Content-Type":"application/json"},body:"{}"});
  if(!check.ok||(await check.json().catch(()=>false))!==true)return reply({error:"صلاحية المراجعة غير متوفرة."},403);
  const body=await req.json(),table=body?.table,id=body?.id,status=body?.status;
  if(typeof table!=="string"||!tables.includes(table)||!(typeof id==="string"||typeof id==="number")||String(id).length>30||!["rejected","unpublished"].includes(status))return reply({error:"الطلب غير صالح."},400);
  const rowRes=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&select=id,title,description,status",{headers:{apikey:key,Authorization:"Bearer "+key}});
  if(!rowRes.ok)return reply({error:"تعذّر تحميل الإعلان."},502);
  const rows=await rowRes.json();if(!Array.isArray(rows)||rows.length!==1)return reply({error:"الإعلان غير موجود."},404);
  const row=rows[0],expected=status==="rejected"?"pending":"approved";
  if(row.status!==expected)return reply({error:"حالة الإعلان تبدّلت من قبل. حدّث القائمة."},409);
  const text=(String(row.title||"")+" "+String(row.description||"")).toLowerCase();
  if((protectedDemoIds[table]||[]).includes(String(id))||/(تجريب|تجريبي|اختبار|test|demo|مثال)/i.test(text))return reply({error:"هذا إعلان تجريبي محمي، لا يمكن تغيير حالته."},403);
  const update=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&status=eq."+expected,{method:"PATCH",headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json",Prefer:"return=representation"},body:JSON.stringify({status})});
  if(!update.ok)return reply({error:"تعذّر حفظ قرار المراجعة."},502);
  const changed=await update.json();if(!Array.isArray(changed)||!changed.length)return reply({error:"الإعلان تبدّلت حالته من قبل. حدّث القائمة."},409);
  return reply({ok:true,message:status==="rejected"?"تم رفض الإعلان.":"تم إلغاء نشر الإعلان."});
 }catch(error){console.error("admin-update-post-status",String(error));return reply({error:"صار خطأ أثناء تحديث حالة الإعلان."},500);}
});