import "jsr:@supabase/functions-js/edge-runtime.d.ts";
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
  const body=await req.json().catch(()=>null);
  const table=body?.table,id=body?.id;
  if(typeof table!=="string"||!Object.hasOwn(cfg,table)||!(typeof id==="string"||typeof id==="number")||String(id).length>30)return reply({error:"الطلب غير صالح."},400);
  if((protectedIds[table]||[]).includes(String(id)))return reply({error:"هذا الإعلان التجريبي محمي ولا يمكن حذفه من حساب المستخدم."},403);
  const query=new URLSearchParams({select:"id,user_id,title,description,status,image_urls","id":"eq."+String(id),"user_id":"eq."+user.id,limit:"2"});
  const rowRes=await fetch(url+"/rest/v1/"+table+"?"+query.toString(),{headers:{apikey:key,Authorization:"Bearer "+key}});
  if(!rowRes.ok)return reply({error:"تعذّر التثبت من ملكية الإعلان."},502);
  const rows=await rowRes.json();
  if(!Array.isArray(rows)||rows.length!==1||rows[0].user_id!==user.id)return reply({error:"الإعلان غير موجود في حسابك أو لا تملك صلاحية حذفه."},404);
  const row=rows[0],demoText=(String(row.title||"")+" "+String(row.description||"")).toLowerCase();
  if(/(تجريب|تجريبي|اختبار|test|demo|مثال)/i.test(demoText))return reply({error:"هذا الإعلان مصنّف كتجربة ومحمي من الحذف."},403);
  const paths=Array.isArray(row.image_urls)?row.image_urls:[];
  for(const path of paths){
   if(typeof path!=="string"||!path.startsWith(cfg[table].folder+"/")||!/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)||path.includes("..")||path.includes("//"))return reply({error:"مسار صورة غير صالح؛ لم يقع حذف الإعلان."},409);
  }
  const del=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&user_id=eq."+encodeURIComponent(user.id),{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,Prefer:"return=representation"}});
  if(!del.ok)return reply({error:"تعذّر حذف الإعلان من قاعدة البيانات. تواصل مع الإدارة."},502);
  const deleted=await del.json().catch(()=>null);
  if(!Array.isArray(deleted)||deleted.length!==1)return reply({error:"لم يتم حذف الإعلان؛ حدّث القائمة وحاول مجدداً."},409);
  if(paths.length){
   // Check both buckets: an unpublished post may still have its former public image copy.
   for(const bucket of [cfg[table].bucket,"pending-images"]){
    const existing=[];
    for(const path of paths){
     const encoded=path.split("/").map(encodeURIComponent).join("/");
     const check=await fetch(url+"/storage/v1/object/info/"+bucket+"/"+encoded,{method:"HEAD",headers:{apikey:key,Authorization:"Bearer "+key}});
     if(check.ok)existing.push(path);
     else if(check.status!==404){console.error("Post deleted but image preflight failed",bucket,check.status);return reply({ok:true,cleanupPending:true,message:"تم حذف الإعلان من قاعدة البيانات، لكن تعذّر التثبت من بعض الصور وتنظيفها. تواصل مع الإدارة لإتمام التنظيف."});}
    }
    if(existing.length){
     const rm=await fetch(url+"/storage/v1/object/"+bucket,{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},body:JSON.stringify({prefixes:existing})});
     if(!rm.ok){console.error("Post deleted but image cleanup failed",bucket,rm.status);return reply({ok:true,cleanupPending:true,message:"تم حذف الإعلان، لكن تعذّر تنظيف بعض الصور. تم تسجيل المشكلة للإدارة."});}
    }
   }
  }
  return reply({ok:true,message:"تم حذف إعلانك وصوره."});
 }catch(error){console.error("delete-my-post error",String(error));return reply({error:"صار خطأ أثناء حذف الإعلان."},500);}
});