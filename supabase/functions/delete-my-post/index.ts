import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { readLimitedRequest } from "../_shared/request-size.ts";
import { buildStorageCleanupJobs, enqueueStorageCleanup } from "../_shared/storage-cleanup-queue.ts";
const ORIGIN="https://saahbii1978s.github.io";
const cors={"Access-Control-Allow-Origin":ORIGIN,"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const reply=(v:unknown,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{...cors,"Content-Type":"application/json"}});

const cfg:Record<string,{bucket:string,folder:string}>={
 service_requests:{bucket:"listing-images",folder:"services"},
 job_posts:{bucket:"listing-images",folder:"jobs"},
 real_estate_posts:{bucket:"listing-images",folder:"realty"},
 market_posts:{bucket:"market-images",folder:"market"}
};
const protectedIds:Record<string,string[]>={service_requests:["13"],job_posts:["7"],market_posts:["2","3","7","8","9"],real_estate_posts:["1","2","6"]};
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST")return reply({error:"طريقة الطلب غير مدعومة."},405);
 if(req.headers.get("origin")!==ORIGIN)return reply({error:"مصدر الطلب غير مسموح."},403);
 try{
  const url=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const auth=req.headers.get("authorization")||"";
  if(!url||!key)return reply({error:"خدمة الحسابات غير مهيّأة."},503);
  if(!auth.startsWith("Bearer ")||auth.length>5000)return reply({error:"سجّل الدخول لحسابك أولاً."},401);
  const userRes=await fetch(url+"/auth/v1/user",{headers:{apikey:key,Authorization:auth}});
  if(!userRes.ok)return reply({error:"جلسة الحساب انتهت. عاود تسجيل الدخول."},401);
  const user=await userRes.json().catch(()=>({}));
  if(typeof user.id!=="string")return reply({error:"تعذّر التثبت من الحساب."},401);
  const boundedRequest=await readLimitedRequest(req,4096);
  if(!boundedRequest)return reply({error:"حجم الطلب أكبر من المسموح."},413);
  const body=await boundedRequest.json().catch(()=>null);
  const table=body?.table,id=body?.id;
  if(typeof table!=="string"||!Object.hasOwn(cfg,table)||!(typeof id==="string"||typeof id==="number")||String(id).length>30)return reply({error:"الطلب غير صالح."},400);
  if((protectedIds[table]||[]).includes(String(id)))return reply({error:"هذا الإعلان التجريبي محمي ولا يمكن حذفه من حساب المستخدم."},403);
  const query=new URLSearchParams({select:"id,user_id,title,description,status,image_urls","id":"eq."+String(id),"user_id":"eq."+user.id,limit:"2"});
  const rowRes=await fetch(url+"/rest/v1/"+table+"?"+query.toString(),{headers:{apikey:key,Authorization:"Bearer "+key}});
  if(!rowRes.ok)return reply({error:"تعذّر التثبت من ملكية الإعلان."},502);
  const rows=await rowRes.json();
  if(!Array.isArray(rows)||rows.length!==1||rows[0].user_id!==user.id)return reply({error:"الإعلان غير موجود في حسابك أو لا تملك صلاحية حذفه."},404);
  const row=rows[0],demoText=(String(row.title||"")+" "+String(row.description||"")).toLowerCase();
  if(/(تجر(?:ي)?ب|اختبار|test|demo|مثال)/i.test(demoText))return reply({error:"هذا الإعلان مصنّف كتجربة ومحمي من الحذف."},403);
  const paths=Array.isArray(row.image_urls)?row.image_urls:[];
  for(const path of paths){
   if(typeof path!=="string"||!path.startsWith(cfg[table].folder+"/")||!/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)||path.includes("..")||path.includes("//"))return reply({error:"مسار صورة غير صالح؛ لم يقع حذف الإعلان."},409);
  }
  const cleanupJobs=buildStorageCleanupJobs([cfg[table].bucket,"pending-images"],paths);
  if(!await enqueueStorageCleanup(url,key,cleanupJobs)){
   console.error("Could not enqueue user post image cleanup",table,id);
   return reply({error:"تعذّر تجهيز تنظيف الصور بأمان. لم يقع حذف الإعلان."},503);
  }
  const deletion=await fetch(url+"/rest/v1/rpc/delete_post_and_activate_storage_cleanup",{
   method:"POST",
   headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},
   body:JSON.stringify({
    p_table:table,p_id:String(id),p_expected_user_id:user.id,p_require_owner:true,
    p_title:row.title??null,p_description:row.description??null,p_status:row.status??null,
    p_image_urls:Array.isArray(row.image_urls)?paths:null,p_jobs:cleanupJobs
   })
  });
  if(!deletion.ok){
   const detail=await deletion.text().catch(()=>"");
   console.error("delete-my-post atomic deletion failed",table,id,deletion.status,detail.slice(0,800));
   return reply({error:"تعذّر حذف الإعلان وتفعيل تنظيف صوره بشكل آمن. لم يقع الحذف."},502);
  }
  const deletionResult=await deletion.json().catch(()=>null);
  if(!deletionResult||deletionResult.deleted!==true)return reply({error:"تغيّرت بيانات الإعلان أثناء العملية؛ لم يقع حذف النسخة المحدّثة. حدّث القائمة وحاول مجدداً."},409);
  const cleanupPending=Number(deletionResult.activated_jobs||0)+Number(deletionResult.deferred_jobs||0)>0;
  return reply({ok:true,cleanupPending,message:cleanupPending?"تم حذف إعلانك، وتنظيف صوره جارٍ في الخلفية.":"تم حذف إعلانك."});
 }catch(error){console.error("delete-my-post error",String(error));return reply({error:"صار خطأ أثناء حذف الإعلان."},500);}
});