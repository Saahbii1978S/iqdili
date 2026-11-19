import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const ALLOWED_ORIGINS = new Set(["https://saahbii1978s.github.io", "https://ahla-tounsa-project.github.io"]);
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const reply=(v:unknown,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{...cors,"Content-Type":"application/json"}});
const folders:Record<string,string>={service_requests:"services",job_posts:"jobs",real_estate_posts:"realty",market_posts:"market"};
async function checkAdmin(req:Request,url:string,key:string){
 const auth=req.headers.get("authorization")||"";
 if(!auth.startsWith("Bearer "))return false;
 const user=await fetch(url+"/auth/v1/user",{headers:{apikey:key,Authorization:auth}});
 if(!user.ok)return false;
 const check=await fetch(url+"/rest/v1/rpc/is_admin",{method:"POST",headers:{apikey:key,Authorization:auth,"Content-Type":"application/json"},body:"{}"});
 return check.ok && await check.json().catch(()=>false)===true;
}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST")return reply({error:"طريقة الطلب غير مدعومة."},405);
 if(!ALLOWED_ORIGINS.has(req.headers.get("origin") || ""))return reply({error:"مصدر الطلب غير مسموح."},403);
 try{
  const url=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!key)return reply({error:"خدمة الصور غير مهيأة."},503);
  if(!await checkAdmin(req,url,key))return reply({error:"الدخول للإدارة غير مصرح."},401);
  const body=await req.json(),table=body?.table,id=body?.id;
  if(typeof table!=="string"||!Object.hasOwn(folders,table)||!(typeof id==="string"||typeof id==="number")||String(id).length>30)return reply({error:"الطلب غير صالح."},400);
  const rowRes=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(id))+"&select=image_urls",{headers:{apikey:key,Authorization:"Bearer "+key}});
  if(!rowRes.ok){console.error("Admin image row query failed",table,rowRes.status,(await rowRes.text()).slice(0,250));return reply({error:"تعذّر قراءة بيانات صورة الإعلان."},502);}
  const rows=await rowRes.json();
  if(!Array.isArray(rows)||!rows.length)return reply({error:"الإعلان غير موجود."},404);
  const path=Array.isArray(rows[0].image_urls)?rows[0].image_urls[0]:null;
  if(!path)return reply({ok:true,url:null});
  if(typeof path!=="string"||!path.startsWith(folders[table]+"/")||!/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(path)||path.includes("..")||path.includes("//"))return reply({error:"مسار الصورة غير صالح."},400);
  const encoded=path.split("/").map(encodeURIComponent).join("/");
  const signRes=await fetch(url+"/storage/v1/object/sign/pending-images/"+encoded,{method:"POST",headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},body:JSON.stringify({expiresIn:300})});
  const signText=await signRes.text();
  if(!signRes.ok){console.error("Admin image signing failed",signRes.status,signText.slice(0,300));return reply({error:"تعذّر إنشاء رابط آمن للصورة ("+signRes.status+")."},502);}
  const signed=JSON.parse(signText),value=signed.signedURL||signed.signedUrl;
  if(typeof value!=="string"||!value)return reply({error:"مخزن الصور لم يرجّع رابطاً صالحاً."},502);
  let signedUrl=value;
  if(!/^https?:\/\//i.test(signedUrl)){
   signedUrl=url+(signedUrl.startsWith("/storage/v1/")?signedUrl:"/storage/v1"+(signedUrl.startsWith("/")?signedUrl:"/"+signedUrl));
  }
  return reply({ok:true,url:signedUrl});
 }catch(e){console.error("admin-post-image error",String(e));return reply({error:"صار خطأ أثناء تحميل الصورة."},500);}
});