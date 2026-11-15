import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { isProtectedDemoPost } from "../_shared/protected-demo.ts";
const TOKEN_HASH="5315d23014e4a1d37335410ac337d9f10d5d4408019d9f165a6b557130a09dd3";
const tables:Record<string,{bucket:string,folder:string}>={service_requests:{bucket:"listing-images",folder:"services"},job_posts:{bucket:"listing-images",folder:"jobs"},real_estate_posts:{bucket:"listing-images",folder:"realty"},market_posts:{bucket:"market-images",folder:"market"}};
async function sha(v:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v));return [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,"0")).join("");}
function validPath(p:unknown,f:string):p is string{return typeof p==="string"&&p.startsWith(f+"/")&&/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(p)&&!p.includes("..")&&!p.includes("//");}
async function remove(url:string,key:string,bucket:string,paths:string[]){if(!paths.length)return true;const r=await fetch(url+"/storage/v1/object/"+bucket,{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},body:JSON.stringify({prefixes:paths})});if(!r.ok){console.error("expiry storage removal",bucket,r.status);return false;}return true;}
async function sendAdminAlert(subject:string,textContent:string):Promise<void>{
 const apiKey=Deno.env.get("BREVO_API_KEY"),recipient=Deno.env.get("ADMIN_ALERT_EMAIL"),sender=Deno.env.get("BREVO_SENDER_EMAIL");
 if(!apiKey||!recipient||!sender){console.warn("Admin email alerts are not fully configured");return;}
 try{const response=await fetch("https://api.brevo.com/v3/smtp/email",{method:"POST",headers:{"accept":"application/json","api-key":apiKey,"content-type":"application/json"},body:JSON.stringify({sender:{name:"أحلى توانسة",email:sender},to:[{email:recipient}],subject,textContent}),signal:AbortSignal.timeout(7000)});if(!response.ok)console.error("Admin email alert failed",response.status);}
 catch(error){console.error("Admin email alert exception",String(error));}
}
function sameTextFilter(column:string,value:unknown):string{return value===null||value===undefined?`${column}=is.null`:`${column}=eq.${encodeURIComponent(String(value))}`;}
Deno.serve(async(req:Request)=>{
 if(req.method!=="POST")return new Response("Method not allowed",{status:405});
 const auth=req.headers.get("authorization")||"";
 if(!auth.startsWith("Bearer ")||await sha(auth.slice(7))!==TOKEN_HASH)return new Response("Unauthorized",{status:401});
 const url=Deno.env.get("SUPABASE_URL")!,key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const result:Record<string,number>={},protectedSkipped:Record<string,number>={},cleanupFailures:string[]=[],scanErrors:string[]=[],deleteErrors:string[]=[],invalidPathSkips:string[]=[];
 for(const [table,c] of Object.entries(tables)){
  const now=new Date().toISOString();let lastId:string|null=null,count=0,protectedCount=0;
  while(true){
   const filters=["status=eq.approved","expires_at=lte."+encodeURIComponent(now),"select=id,title,description,image_urls","order=id.asc","limit=100"];
   if(lastId!==null)filters.push("id=gt."+encodeURIComponent(lastId));
   const q=await fetch(url+"/rest/v1/"+table+"?"+filters.join("&"),{headers:{apikey:key,Authorization:"Bearer "+key}});
   if(!q.ok){scanErrors.push(table);console.error("expiry scan failed",table,q.status);break;}
   const rows=await q.json();
   if(!Array.isArray(rows)){scanErrors.push(table);console.error("expiry scan returned invalid data",table);break;}
   if(rows.length===0)break;
   for(const row of rows){
    lastId=String(row.id);
    if(isProtectedDemoPost(table,row.id,row.title,row.description)){protectedCount++;continue;}
    const paths=Array.isArray(row.image_urls)?row.image_urls:[];
    if(paths.some((p:unknown)=>!validPath(p,c.folder))){invalidPathSkips.push(table+":"+String(row.id));console.error("expiry skipped unexpected image path",table,String(row.id));continue;}
    const deleteFilters=["id=eq."+encodeURIComponent(String(row.id)),"status=eq.approved","expires_at=lte."+encodeURIComponent(now),sameTextFilter("title",row.title),sameTextFilter("description",row.description)];
    const d=await fetch(url+"/rest/v1/"+table+"?"+deleteFilters.join("&"),{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,Prefer:"return=representation"}});
    if(!d.ok){deleteErrors.push(table+":"+String(row.id));console.error("expiry delete failed",table,String(row.id),d.status);continue;}
    const deleted=await d.json().catch(()=>null);
    if(!Array.isArray(deleted)||deleted.length!==1)continue;
    count++;
    const publicClean=await remove(url,key,c.bucket,paths),pendingClean=await remove(url,key,"pending-images",paths);
    if(!publicClean||!pendingClean){cleanupFailures.push(table+":"+String(row.id));console.error("Expired listing deleted but image cleanup is pending",table,row.id);}
   }
   if(rows.length<100)break;
  }
  result[table]=count;protectedSkipped[table]=protectedCount;
 }
 const totalDeleted=Object.values(result).reduce((sum,count)=>sum+Math.max(count,0),0);
 if(cleanupFailures.length)await sendAdminAlert("تنبيه تنظيف صور الإعلانات المنتهية","تم حذف الإعلانات من قاعدة البيانات، لكن بقيت صور تحتاج تنظيفاً:\n"+cleanupFailures.join("\n"));
 if(totalDeleted>0)await sendAdminAlert("ملخّص الحذف الآلي في أحلى توانسة","تم حذف إعلانات انتهت مدتها بعد 3 أشهر.\n"+Object.entries(result).map(([table,count])=>table+": "+count).join("\n"));
 if(scanErrors.length)await sendAdminAlert("خطأ تقني في الحذف الآلي","تعذّر فحص بعض أقسام الإعلانات: "+[...new Set(scanErrors)].join(", ")+". راجع سجلات Supabase.");
 if(deleteErrors.length)await sendAdminAlert("تعذّر حذف بعض الإعلانات المنتهية","فشلت عملية حذف بعض السجلات: "+deleteErrors.slice(0,100).join("\\n")+(deleteErrors.length>100?"\\nوبقية السجلات في سجلات الوظيفة.":""));
 if(invalidPathSkips.length)await sendAdminAlert("مراجعة مسارات صور إعلانات منتهية","تم إيقاف حذف بعض الإعلانات بسبب مسارات صور غير متوقعة: "+invalidPathSkips.slice(0,100).join("\\n")+(invalidPathSkips.length>100?"\\nوبقية السجلات في سجلات الوظيفة.":""));
 return new Response(JSON.stringify({ok:scanErrors.length===0&&deleteErrors.length===0,deleted:result,protectedSkipped,deleteFailures:deleteErrors.length,invalidImagePathSkips:invalidPathSkips.length,cleanupFailures:cleanupFailures.length}),{headers:{"Content-Type":"application/json"}});
});
