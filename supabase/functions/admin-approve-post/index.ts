import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const ALLOWED_ORIGINS = new Set(["https://saahbii1978s.github.io", "https://ahla-tounsa-project.github.io"]);
const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
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
 return {ok:true as const,url,key,userId:userData.id as string};
}
function safePath(path:unknown,table:string){
 const folder=table==="service_requests"?"services":table==="job_posts"?"jobs":table==="real_estate_posts"?"realty":"market";
 return typeof path==="string" && path.startsWith(folder+"/") && /^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path) && !path.includes("..") && !path.includes("//");
}
function objectInfoUrl(url:string,bucket:string,path:string){
 return url+"/storage/v1/object/info/"+bucket+"/"+path.split("/").map(encodeURIComponent).join("/");
}
function storageHeaders(key:string){return {apikey:key,Authorization:"Bearer "+key};}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST")return reply({error:"طريقة الطلب غير مدعومة."},405);
 if(!ALLOWED_ORIGINS.has(req.headers.get("origin") || ""))return reply({error:"مصدر الطلب غير مسموح."},403);
 try{
  const auth=await admin(req);if(!auth.ok)return reply({error:"الدخول للإدارة غير مصرح."},401);
  const body=await req.json();const table=body?.table,id=body?.id;
  if(typeof table!=="string"||!Object.hasOwn(tables,table)||!(typeof id==="string"||typeof id==="number")||String(id).length>30)return reply({error:"الطلب غير صالح."},400);
  const rowResponse=await fetch(auth.url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&select=id,title,description,status,image_urls",{headers:{apikey:auth.key,Authorization:"Bearer "+auth.key}});
  if(!rowResponse.ok)return reply({error:"تعذّر تحميل الإعلان."},502);
  const rows=await rowResponse.json();if(!Array.isArray(rows)||rows.length!==1)return reply({error:"الإعلان غير موجود."},404);
  const row=rows[0];if(row.status!=="pending")return reply({error:"الإعلان لم يعد في قائمة الانتظار."},409);
  const text=(String(row.title||"")+" "+String(row.description||"")).toLowerCase();
  const protectedDemoIds:Record<string,string[]>={service_requests:["13"],job_posts:["7"],market_posts:["2","3","7","8","9"],real_estate_posts:["1","2","6"]};
  if((protectedDemoIds[table]||[]).includes(String(id)) || /(تجريب|تجريبي|اختبار|test|demo|مثال)/i.test(text)){
   return reply({error:"هذا إعلان تجريبي محمي، لا يمكن نشره."},403);
  }
  const path=Array.isArray(row.image_urls)?row.image_urls[0]:null;
  if(path){
   if(!safePath(path,table))return reply({error:"مسار الصورة غير صالح."},400);
   const destinationBucket=tables[table];
   const headers=storageHeaders(auth.key);
   // Idempotency: a previous attempt may have completed the copy before its response was lost.
   const destinationHead=await fetch(objectInfoUrl(auth.url,destinationBucket,path),{method:"HEAD",headers});
   if(!destinationHead.ok){
    const sourceHead=await fetch(objectInfoUrl(auth.url,"pending-images",path),{method:"HEAD",headers});
    if(!sourceHead.ok)return reply({error:"الصورة غير موجودة في المخزن الخاص؛ ما تمش نشر الإعلان."},409);
    const copy=await fetch(auth.url+"/storage/v1/object/copy",{method:"POST",headers:{...headers,"Content-Type":"application/json"},body:JSON.stringify({bucketId:"pending-images",sourceKey:path,destinationBucket,destinationKey:path})});
    if(!copy.ok){
     const detail=await copy.text().catch(()=> "");
     // Confirm whether Storage committed the copy despite returning an error.
     const verify=await fetch(objectInfoUrl(auth.url,destinationBucket,path),{method:"HEAD",headers});
     if(!verify.ok){
      console.error("approved image copy failed",copy.status,detail.slice(0,300));
      return reply({error:"ما نجّمش ننقل الصورة للمخزن المنشور. الإعلان ما تنشرش."},502);
     }
    }
   }
  }
  const update=await fetch(auth.url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&status=eq.pending",{method:"PATCH",headers:{apikey:auth.key,Authorization:"Bearer "+auth.key,"Content-Type":"application/json",Prefer:"return=representation"},body:JSON.stringify({status:"approved",expires_at:addCalendarMonths(new Date(),3).toISOString()})});
  if(!update.ok){console.error("approval status update failed",update.status,await update.text().catch(()=> ""));return reply({error:"تم تجهيز الصورة لكن لم تتأكد عملية النشر. حدّث القائمة قبل أي محاولة أخرى."},502);}
  const updated=await update.json();if(!Array.isArray(updated)||!updated.length)return reply({error:"الإعلان تبدّلت حالته من قبل. حدّث القائمة."},409);
  await sendAdminAlert("تم نشر إعلان في أحلى توانسة", `تمت الموافقة على إعلان ونشره.\nالقسم: ${table}\nرقم الإعلان: ${id}\nالعنوان: ${String(row.title || "").slice(0, 120)}`);
  return reply({ok:true,message:"تمت الموافقة على الإعلان ونشره."});
 }catch(e){await sendAdminAlert("خطأ تقني في الموافقة على إعلان","تعذّر إكمال عملية الموافقة. راجع سجلات Supabase لمعرفة التفاصيل.");console.error("admin-approve-post error",String(e));return reply({error:"صار خطأ أثناء الموافقة."},500);}
});