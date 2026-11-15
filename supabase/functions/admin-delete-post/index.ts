import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { readLimitedRequest } from "../_shared/request-size.ts";
import { buildStorageCleanupJobs, enqueueStorageCleanup, activateStorageCleanup, completeStorageCleanup, recordStorageCleanupFailure } from "../_shared/storage-cleanup-queue.ts";
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
  const boundedRequest=await readLimitedRequest(req,1024);
  if(!boundedRequest)return reply({error:"حجم الطلب أكبر من المسموح."},413);
  const body=await boundedRequest.json().catch(()=>null),table=body?.table,id=body?.id,deleteTest=body?.delete_test===true;
  if(!body||typeof table!=="string"||!Object.hasOwn(cfg,table)||!(typeof id==="string"||typeof id==="number")||String(id).length>30)return reply({error:"الطلب غير صالح."},400);
  const rowRes=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&select=id,title,description,status,image_urls",{headers:{apikey:key,Authorization:"Bearer "+key}});
  if(!rowRes.ok)return reply({error:"تعذّر تحميل الإعلان."},502);
  const rows=await rowRes.json();if(!Array.isArray(rows)||rows.length!==1)return reply({error:"الإعلان غير موجود."},404);
  const protectedDemoIds:Record<string,string[]>={service_requests:["13"],job_posts:["7"],market_posts:["2","3","7","8","9"],real_estate_posts:["1","2","6"]};
  const demoText=(String(rows[0].title||"")+" "+String(rows[0].description||"")).toLowerCase();
  const isKnownDemo=(protectedDemoIds[table]||[]).includes(String(id)) || /(تجر(?:ي)?ب|اختبار|test|demo|مثال)/i.test(demoText);
  if(isKnownDemo&&!deleteTest)return reply({error:"هذا إعلان تجريبي محمي. استعمل زر حذف إعلان تجريبي بصلاحية صاحب المشروع."},403);
  if(deleteTest&&!isKnownDemo)return reply({error:"رفض الحذف: الإعلان غير مصنّف كتجربة."},403);
  const paths=Array.isArray(rows[0].image_urls)?rows[0].image_urls:[];
  for(const path of paths){if(typeof path!=="string"||!path.startsWith(cfg[table].folder+"/")||!/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)||path.includes("..")||path.includes("//"))return reply({error:"مسار صورة غير صالح؛ لم يقع حذف الإعلان."},409);}
  // Compare the complete reviewed snapshot at delete time. If the post changed
  // after the read (including status or image paths), do not delete the newer version.
  // Persist cleanup intent before deleting the row. If queue persistence fails, keep the post intact.
  const cleanupJobs=buildStorageCleanupJobs([cfg[table].bucket,"pending-images"],paths);
  if(!await enqueueStorageCleanup(url,key,cleanupJobs)){
   console.error("Could not enqueue admin post image cleanup",table,id);
   return reply({error:"تعذّر تجهيز تنظيف الصور بأمان. لم يقع حذف الإعلان."},503);
  }
  const deleteQuery=new URLSearchParams({
   id:"eq."+String(id),
   title:rows[0].title===null||rows[0].title===undefined?"is.null":"eq."+String(rows[0].title),
   description:rows[0].description===null||rows[0].description===undefined?"is.null":"eq."+String(rows[0].description),
   status:rows[0].status===null||rows[0].status===undefined?"is.null":"eq."+String(rows[0].status),
   image_urls:Array.isArray(rows[0].image_urls)?"eq.{"+paths.join(",")+"}":"is.null"
  });
  const del=await fetch(url+"/rest/v1/"+table+"?"+deleteQuery.toString(),{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,Prefer:"return=representation"}});
  if(!del.ok){
   const detail=await del.text().catch(()=>"");
   console.error("admin-delete-post database DELETE failed",JSON.stringify({table,id,status:del.status,detail:detail.slice(0,1200)}));
   return reply({error:"تعذّر حذف سجل الإعلان من قاعدة البيانات. لم يقع تنظيف الصور."},502);
  }
  const deleted=await del.json().catch(()=>null);
  if(!Array.isArray(deleted)||deleted.length!==1)return reply({error:"تغيّرت بيانات الإعلان أثناء العملية؛ لم يقع حذف النسخة المحدّثة. حدّث الصفحة وحاول مجدداً."},409);
  if(!await activateStorageCleanup(url,key,cleanupJobs))return reply({ok:true,cleanupPending:true,message:"تم حذف الإعلان، لكن تعذّر تفعيل مهمة تنظيف الصور. يلزم تدخل الإدارة."});
  // Remove images only after the database row is gone, so a storage failure cannot leave a live post without its images.
  for(const bucket of [cfg[table].bucket,"pending-images"]){
   const bucketJobs=cleanupJobs.filter(job=>job.bucket===bucket);
   if(!bucketJobs.length)continue;
   const rm=await fetch(url+"/storage/v1/object/"+bucket,{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},body:JSON.stringify({prefixes:bucketJobs.map(job=>job.object_path)})});
   if(!rm.ok){
    console.error("Admin post deleted but image cleanup is pending",bucket,rm.status);
    for(const job of bucketJobs)await recordStorageCleanupFailure(url,key,job,"Storage DELETE returned "+rm.status);
    await sendAdminAlert("تنبيه تنظيف صور إعلان محذوف","تم حذف سجل الإعلان من قاعدة البيانات، لكن بقيت صور تحتاج تنظيفاً.\\nالقسم: "+table+"\\nرقم الإعلان: "+id+"\\nالمخزن: "+bucket);
    return reply({ok:true,cleanupPending:true,message:"تم حذف الإعلان، وبقيت مهمة تنظيف الصور محفوظة لإعادة المحاولة."});
   }
   for(const job of bucketJobs){
    if(!await completeStorageCleanup(url,key,job)){
     console.error("Storage cleanup succeeded but queue completion update failed",bucket,job.object_path);
     await sendAdminAlert("تنبيه تحديث سجل تنظيف الصور","تم تنظيف صورة إعلان، لكن تعذّر تحديث سجل المهمة.\\nالقسم: "+table+"\\nرقم الإعلان: "+id+"\\nالمخزن: "+bucket);
     return reply({ok:true,cleanupPending:true,message:"تم حذف الإعلان وتنظيف الصور، لكن بقي تحديث سجل التنظيف معلقاً."});
    }
   }
  }
  await sendAdminAlert("تم حذف إعلان من إدارة أحلى توانسة", `تم حذف إعلان من لوحة الإدارة.\nالقسم: ${table}\nرقم الإعلان: ${id}`);
  return reply({ok:true,message:"تم حذف الإعلان وصوره نهائياً."});
 }catch(e){await sendAdminAlert("خطأ تقني أثناء حذف إعلان","تعذّر إكمال عملية حذف إعلان. راجع سجلات Supabase لمعرفة التفاصيل.");console.error("admin-delete-post",String(e));return reply({error:"صار خطأ أثناء الحذف."},500);}
});