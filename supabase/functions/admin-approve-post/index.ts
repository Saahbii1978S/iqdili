// AUDIT CANDIDATE REVISION — not deployed to Supabase.
// Exported from active Supabase Edge Function "admin-approve-post" on 2026-11-15.
// Deployed version at export: 11.
// This file is preserved for audit/recovery only; do not deploy without separate review and approval.
// Runtime secrets remain environment variables and are not included in this snapshot.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { readLimitedRequest } from "../_shared/request-size.ts";
import { classifyStorageHeadStatus } from "../_shared/storage-head.ts";
import { buildStorageCleanupJobs, enqueueStorageCleanup, isValidStorageObjectPath } from "../_shared/storage-cleanup-queue.ts";
const ORIGIN = "https://ahla-tounsa-project.github.io";
const cors = {"Access-Control-Allow-Origin":ORIGIN,"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
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

const tables:Record<string,string>={service_requests:"listing-images",job_posts:"listing-images",real_estate_posts:"listing-images",market_posts:"market-images"};
function addCalendarMonths(date:Date,months:number){const result=new Date(date);const day=result.getUTCDate();result.setUTCDate(1);result.setUTCMonth(result.getUTCMonth()+months);const lastDay=new Date(Date.UTC(result.getUTCFullYear(),result.getUTCMonth()+1,0)).getUTCDate();result.setUTCDate(Math.min(day,lastDay));return result;}
async function admin(req:Request){
 const url=Deno.env.get("SUPABASE_URL")!, key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const auth=req.headers.get("authorization")||"";
 if(!auth.startsWith("Bearer ")) return {ok:false as const,url,key};
 const user=await fetch(url+"/auth/v1/user",{headers:{apikey:key,Authorization:auth}});
 if(!user.ok) return {ok:false as const,url,key};
 const userData=await user.json();
 const check=await fetch(url+"/rest/v1/rpc/is_admin",{method:"POST",headers:{apikey:key,Authorization:auth,"Content-Type":"application/json"},body:"{}"});
 if(!check.ok || await check.json().catch(()=>false)!==true) return {ok:false as const,url,key};
 return {ok:true as const,url,key,userId:userData.id as string,authorization:auth};
}
function folderFor(table:string){
 return table==="service_requests"?"services":table==="job_posts"?"jobs":table==="real_estate_posts"?"realty":"market";
}
function safePath(path:unknown,table:string):path is string{
 return typeof path==="string" && path.startsWith(folderFor(table)+"/") && isValidStorageObjectPath(path);
}
function objectInfoUrl(url:string,bucket:string,path:string){
 return url+"/storage/v1/object/info/"+bucket+"/"+path.split("/").map(encodeURIComponent).join("/");
}
function storageHeaders(key:string){return {apikey:key,Authorization:"Bearer "+key};}
function makePublicPath(sourcePath:string,table:string){
 const folder=folderFor(table);
 const extension=sourcePath.slice(sourcePath.lastIndexOf(".")+1).toLowerCase();
 return folder+"/approved-"+crypto.randomUUID()+"."+extension;
}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST")return reply({error:"طريقة الطلب غير مدعومة."},405);
 if(req.headers.get("origin")!==ORIGIN)return reply({error:"مصدر الطلب غير مسموح."},403);
 try{
  const auth=await admin(req);if(!auth.ok)return reply({error:"الدخول للإدارة غير مصرح."},401);
  const boundedRequest=await readLimitedRequest(req,1024);
  if(!boundedRequest)return reply({error:"حجم الطلب أكبر من المسموح."},413);
  const body=await boundedRequest.json().catch(()=>null);const table=body?.table,id=body?.id;
  if(!body||typeof body!=="object")return reply({error:"الطلب غير صالح."},400);
  if(typeof table!=="string"||!Object.hasOwn(tables,table)||!(typeof id==="string"||typeof id==="number")||!/^\d{1,18}$/.test(String(id)))return reply({error:"الطلب غير صالح."},400);
  const rowResponse=await fetch(auth.url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&select=*",{headers:{apikey:auth.key,Authorization:"Bearer "+auth.key}});
  if(!rowResponse.ok)return reply({error:"تعذّر تحميل الإعلان."},502);
  const rows=await rowResponse.json();if(!Array.isArray(rows)||rows.length!==1)return reply({error:"الإعلان غير موجود."},404);
  const row=rows[0];if(row.status!=="pending")return reply({error:"الإعلان لم يعد في قائمة الانتظار."},409);
  const text=(String(row.title||"")+" "+String(row.description||"")).toLowerCase();
  const protectedDemoIds:Record<string,string[]>={service_requests:["13"],job_posts:["7"],market_posts:["2","3","7","8","9"],real_estate_posts:["1","2","6"]};
  if((protectedDemoIds[table]||[]).includes(String(id)) || /(تجر(?:ي)?ب|اختبار|test|demo|مثال)/i.test(text)){
   return reply({error:"هذا إعلان تجريبي محمي، لا يمكن نشره."},403);
  }

  const sourcePaths=Array.isArray(row.image_urls)?row.image_urls:[];
  if(sourcePaths.length>20 || sourcePaths.some((path:unknown)=>!safePath(path,table))){
   return reply({error:"قائمة الصور غير صالحة. ما تمش نشر الإعلان."},400);
  }
  const uniqueSources=[...new Set(sourcePaths as string[])];
  const publicPaths=uniqueSources.map(path=>makePublicPath(path,table));
  const cleanupJobs=[
   ...buildStorageCleanupJobs([tables[table]],publicPaths),
   ...buildStorageCleanupJobs(["pending-images"],uniqueSources)
  ];
  if(cleanupJobs.length && !await enqueueStorageCleanup(auth.url,auth.key,cleanupJobs)){
   console.error("Could not stage approval image recovery jobs",table,String(id));
   return reply({error:"تعذّر تجهيز حماية الصور. ما تمش نشر الإعلان."},502);
  }

  const headers=storageHeaders(auth.key);
  for(let i=0;i<uniqueSources.length;i++){
   const sourcePath=uniqueSources[i],destinationPath=publicPaths[i];
   const sourceHead=await fetch(objectInfoUrl(auth.url,"pending-images",sourcePath),{method:"HEAD",headers,signal:AbortSignal.timeout(7000)});
   const sourceState=classifyStorageHeadStatus(sourceHead.status);
   if(sourceState==="error"){
    console.error("approval source image preflight failed",sourceHead.status);
    return reply({error:"تعذّر التثبت من صورة الإعلان. ما تمش نشره."},502);
   }
   if(sourceState==="missing")return reply({error:"إحدى صور الإعلان غير موجودة. ما تمش نشره."},409);

   const copy=await fetch(auth.url+"/storage/v1/object/copy",{
    method:"POST",
    headers:{...headers,"Content-Type":"application/json"},
    body:JSON.stringify({bucketId:"pending-images",sourceKey:sourcePath,destinationBucket:tables[table],destinationKey:destinationPath}),
    signal:AbortSignal.timeout(12000)
   });
   if(!copy.ok){
    const detail=await copy.text().catch(()=> "");
    console.error("approval image copy failed",copy.status,detail.slice(0,250));
    return reply({error:"تعذّر نقل إحدى الصور بأمان. الإعلان ما تنشرش."},502);
   }
  }

  const expectedImages=Array.isArray(row.image_urls)?row.image_urls:[];
  const replacementImages=sourcePaths.map((path:string)=>{
   const index=uniqueSources.indexOf(path);
   return index>=0?publicPaths[index]:path;
  });
  const expiresAt=addCalendarMonths(new Date(),3).toISOString();
  const update=await fetch(auth.url+"/rest/v1/rpc/approve_post_if_unchanged",{
   method:"POST",
   headers:{apikey:auth.key,Authorization:auth.authorization,"Content-Type":"application/json"},
   body:JSON.stringify({
    p_table:table,
    p_id:Number(id),
    p_expected_row:row,
    p_new_image_urls:replacementImages,
    p_expires_at:expiresAt
   }),
   signal:AbortSignal.timeout(10000)
  });
  if(!update.ok){
   console.error("atomic approval RPC failed",update.status,await update.text().catch(()=> ""));
   return reply({error:"ما تأكدش النشر لأن بيانات الإعلان تبدّلت أو صار خطأ. الصور الزايدة باش تتراجع آلياً."},409);
  }
  const changed=await update.json().catch(()=>null);
  if(changed!==true){
   return reply({error:"الإعلان تبدّل بعد المراجعة. ما تمش نشره، والصور الزايدة باش تتراجع آلياً."},409);
  }

  await sendAdminAlert("تم نشر إعلان في أحلى توانسة", `تمت الموافقة على إعلان ونشره.\\nالقسم: ${table}\\nرقم الإعلان: ${id}\\nالعنوان: ${String(row.title || "").slice(0, 120)}`);
  return reply({ok:true,message:"تمت الموافقة على الإعلان ونشره."});
 }catch(e){await sendAdminAlert("خطأ تقني في الموافقة على إعلان","تعذّر إكمال عملية الموافقة. راجع سجلات Supabase لمعرفة التفاصيل.");console.error("admin-approve-post error",String(e));return reply({error:"صار خطأ أثناء الموافقة."},500);}
});
