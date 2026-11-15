// AUDIT CANDIDATE REVISION — not deployed to Supabase.
// Exported from active Supabase Edge Function "admin-update-post-status" on 2026-11-15.
// Deployed version at export: 2.
// This candidate keeps status changes authenticated with the administrator JWT.
// Runtime secrets remain environment variables and are not included in this snapshot.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { readLimitedRequest } from "../_shared/request-size.ts";
const ORIGIN="https://saahbii1978s.github.io";
const cors={"Access-Control-Allow-Origin":ORIGIN,"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const reply=(v:unknown,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{...cors,"Content-Type":"application/json"}});
const tables:Record<string,{bucket:string,folder:string}>={
 service_requests:{bucket:"listing-images",folder:"services"},
 job_posts:{bucket:"listing-images",folder:"jobs"},
 real_estate_posts:{bucket:"listing-images",folder:"realty"},
 market_posts:{bucket:"market-images",folder:"market"}
};
const protectedDemoIds:Record<string,string[]>={service_requests:["13"],job_posts:["7"],market_posts:["2","3","7","8","9"],real_estate_posts:["1","2","6"]};
function safeImagePath(path:unknown,folder:string):path is string{
 return typeof path==="string"&&path.startsWith(folder+"/")&&/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)&&!path.includes("..")&&!path.includes("//");
}
async function cleanupPublicImages(url:string,key:string,table:string,paths:string[]):Promise<boolean>{
 if(!paths.length)return true;
 const config=tables[table],existing:string[]=[];
 for(const path of paths){
  if(!safeImagePath(path,config.folder))return false;
  const encoded=path.split("/").map(encodeURIComponent).join("/");
  const check=await fetch(url+"/storage/v1/object/info/"+config.bucket+"/"+encoded,{method:"HEAD",headers:{apikey:key,Authorization:"Bearer "+key}});
  if(check.status===404)continue;
  if(!check.ok){console.error("Public image cleanup preflight failed",table,check.status);return false;}
  existing.push(path);
 }
 if(!existing.length)return true;
 const remove=await fetch(url+"/storage/v1/object/"+config.bucket,{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},body:JSON.stringify({prefixes:existing})});
 if(!remove.ok){console.error("Public image cleanup failed",table,remove.status);return false;}
 return true;
}
async function sendAdminAlert(subject:string,textContent:string):Promise<void>{
 const apiKey=Deno.env.get("BREVO_API_KEY"),recipient=Deno.env.get("ADMIN_ALERT_EMAIL"),sender=Deno.env.get("BREVO_SENDER_EMAIL");
 if(!apiKey||!recipient||!sender){console.warn("Admin email alerts are not fully configured");return;}
 try{
  const response=await fetch("https://api.brevo.com/v3/smtp/email",{method:"POST",headers:{"accept":"application/json","api-key":apiKey,"content-type":"application/json"},body:JSON.stringify({sender:{name:"أحلى توانسة",email:sender},to:[{email:recipient}],subject,textContent}),signal:AbortSignal.timeout(7000)});
  if(!response.ok)console.error("Admin cleanup alert failed",response.status);
 }catch(error){console.error("Admin cleanup alert exception",String(error));}
}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST")return reply({error:"طريقة الطلب غير مدعومة."},405);
 if(req.headers.get("origin")!==ORIGIN)return reply({error:"مصدر الطلب غير مسموح."},403);
 try{
  const url=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const auth=req.headers.get("authorization")||"";
  if(!url||!key||!auth.startsWith("Bearer "))return reply({error:"الدخول للإدارة غير مصرح."},401);
  const userRes=await fetch(url+"/auth/v1/user",{headers:{apikey:key,Authorization:auth}});
  if(!userRes.ok)return reply({error:"جلسة الدخول غير صالحة."},401);
  const check=await fetch(url+"/rest/v1/rpc/is_admin",{method:"POST",headers:{apikey:key,Authorization:auth,"Content-Type":"application/json"},body:"{}"});
  if(!check.ok||(await check.json().catch(()=>false))!==true)return reply({error:"صلاحية المراجعة غير متوفرة."},403);
  const boundedRequest=await readLimitedRequest(req,16000);
  if(!boundedRequest)return reply({error:"حجم الطلب كبير أكثر من اللازم."},413);
  const body=await boundedRequest.json(),table=body?.table,id=body?.id,status=body?.status;
  if(typeof table!=="string"||!Object.hasOwn(tables,table)||!(typeof id==="string"||typeof id==="number")||String(id).length>30||!["rejected","unpublished"].includes(status))return reply({error:"الطلب غير صالح."},400);
  const rowRes=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&select=id,title,description,status,image_urls",{headers:{apikey:key,Authorization:"Bearer "+key}});
  if(!rowRes.ok)return reply({error:"تعذّر تحميل الإعلان."},502);
  const rows=await rowRes.json();if(!Array.isArray(rows)||rows.length!==1)return reply({error:"الإعلان غير موجود."},404);
  const row=rows[0],expected=status==="rejected"?"pending":"approved";
  if(row.status!==expected)return reply({error:"حالة الإعلان تبدّلت من قبل. حدّث القائمة."},409);
  const text=(String(row.title||"")+" "+String(row.description||"")).toLowerCase();
  if((protectedDemoIds[table]||[]).includes(String(id))||/(تجر(?:ي)?ب|اختبار|test|demo|مثال)/i.test(text))return reply({error:"هذا إعلان تجريبي محمي، لا يمكن تغيير حالته."},403);
  const update=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&status=eq."+expected,{method:"PATCH",headers:{apikey:key,Authorization:auth,"Content-Type":"application/json",Prefer:"return=representation"},body:JSON.stringify({status})});
  if(!update.ok)return reply({error:"تعذّر حفظ قرار المراجعة."},502);
  const changed=await update.json();if(!Array.isArray(changed)||!changed.length)return reply({error:"الإعلان تبدّلت حالته من قبل. حدّث القائمة."},409);
  const paths=Array.isArray(row.image_urls)?row.image_urls:[];
  const cleaned=await cleanupPublicImages(url,key,table,paths);
  if(!cleaned){
   console.error("Status updated but public image cleanup remains pending",table,String(id));
   await sendAdminAlert("تنبيه تنظيف صورة إعلان في أحلى توانسة","تم تحديث حالة الإعلان، لكن تعذّر تنظيف نسخة الصورة العامة.\nالقسم: "+table+"\nرقم الإعلان: "+String(id));
   return reply({ok:true,cleanupPending:true,message:"تبدّلت حالة الإعلان، لكن تنظيف الصورة العامة ما كملش. تم تنبيه الإدارة."});
  }
  return reply({ok:true,message:status==="rejected"?"تم رفض الإعلان.":"تم إلغاء نشر الإعلان."});
 }catch(error){console.error("admin-update-post-status",String(error));return reply({error:"صار خطأ أثناء تحديث حالة الإعلان."},500);}
});
