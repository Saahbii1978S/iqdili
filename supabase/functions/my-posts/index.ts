import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const ORIGIN="https://saahbii1978s.github.io";
const cors={"Access-Control-Allow-Origin":ORIGIN,"Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,"Content-Type":"application/json"}});
const tables=["service_requests","job_posts","real_estate_posts","market_posts"] as const;
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
 if(req.method!=="POST")return reply({error:"طريقة الطلب غير مدعومة."},405);
 if(req.headers.get("origin")!==ORIGIN)return reply({error:"مصدر الطلب غير مسموح."},403);
 try{
  const url=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const auth=req.headers.get("authorization")||"";
  if(!url||!key)return reply({error:"خدمة الحسابات غير مهيّأة."},503);
  if(!auth.startsWith("Bearer ")||auth.length>5000)return reply({error:"سجّل الدخول لحسابك أولاً."},401);
  const userResponse=await fetch(url+"/auth/v1/user",{headers:{apikey:key,Authorization:auth}});
  if(!userResponse.ok)return reply({error:"انتهت جلسة الحساب. عاود تسجيل الدخول."},401);
  const user=await userResponse.json().catch(()=>({}));
  if(typeof user.id!=="string")return reply({error:"تعذّر التثبت من الحساب."},401);
  const selects:Record<string,string>={
   service_requests:"id,title,description,city,phone,status,created_at,expires_at,image_urls",
   job_posts:"id,title,description,city,phone,status,created_at,expires_at,image_urls,job_type,work_nature",
   real_estate_posts:"id,title,description,city,phone,status,created_at,expires_at,image_urls,property_type,listing_type,price,size,rooms",
   market_posts:"id,title,description,city,phone,status,created_at,expires_at,image_urls,category,listing_type,price"
  };
  const output:Record<string,unknown[]>={};
  for(const table of tables){
   const query=new URLSearchParams({select:selects[table],user_id:"eq."+user.id,order:"created_at.desc",limit:"100"});
   const response=await fetch(url+"/rest/v1/"+table+"?"+query.toString(),{headers:{apikey:key,Authorization:"Bearer "+key}});
   if(!response.ok){console.error("my-posts query failed",table,response.status);return reply({error:"تعذّر تحميل إعلانات حسابك. عاود التحديث."},502);}
   output[table]=await response.json();
  }
  return reply({ok:true,posts:output});
 }catch(error){console.error("my-posts error",String(error));return reply({error:"صار خطأ أثناء تحميل إعلانات حسابك."},500);}
});