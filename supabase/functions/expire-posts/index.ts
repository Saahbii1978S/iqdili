import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { isProtectedDemoPost } from "../_shared/protected-demo.ts";
import { buildStorageCleanupJobs, enqueueStorageCleanup, isValidStorageObjectPath } from "../_shared/storage-cleanup-queue.ts";
const TOKEN_HASH=Deno.env.get("EXPIRE_POSTS_TOKEN_HASH")||"";
const tables:Record<string,{bucket:string,folder:string}>={service_requests:{bucket:"listing-images",folder:"services"},job_posts:{bucket:"listing-images",folder:"jobs"},real_estate_posts:{bucket:"listing-images",folder:"realty"},market_posts:{bucket:"market-images",folder:"market"}};
async function sha(v:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v));return [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,"0")).join("");}
function validPath(p:unknown,f:string):p is string{return isValidStorageObjectPath(p)&&p.startsWith(f+"/");}
async function sendAdminAlert(subject:string,textContent:string):Promise<void>{
 const apiKey=Deno.env.get("BREVO_API_KEY"),recipient=Deno.env.get("ADMIN_ALERT_EMAIL"),sender=Deno.env.get("BREVO_SENDER_EMAIL");
 if(!apiKey||!recipient||!sender){console.warn("Admin email alerts are not fully configured");return;}
 try{const response=await fetch("https://api.brevo.com/v3/smtp/email",{method:"POST",headers:{"accept":"application/json","api-key":apiKey,"content-type":"application/json"},body:JSON.stringify({sender:{name:"أحلى توانسة",email:sender},to:[{email:recipient}],subject,textContent}),signal:AbortSignal.timeout(7000)});if(!response.ok)console.error("Admin email alert failed",response.status);}
 catch(error){console.error("Admin email alert exception",String(error));}
}
Deno.serve(async(req:Request)=>{
 if(req.method!=="POST")return new Response("Method not allowed",{status:405});
 const auth=req.headers.get("authorization")||"";
 if(!auth.startsWith("Bearer ")||await sha(auth.slice(7))!==TOKEN_HASH)return new Response("Unauthorized",{status:401});
 const url=Deno.env.get("SUPABASE_URL")!,key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const result:Record<string,number>={},protectedSkipped:Record<string,number>={},cleanupFailures:string[]=[],scanErrors:string[]=[],deleteErrors:string[]=[],invalidPathSkips:string[]=[];
 for(const [table,c] of Object.entries(tables)){
  const now=new Date().toISOString();let lastId:string|null=null,count=0,protectedCount=0;
  while(true){
   const filters=["status=eq.approved","expires_at=lte."+encodeURIComponent(now),"select=*","order=id.asc","limit=100"];
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
    const cleanupJobs=buildStorageCleanupJobs([c.bucket,"pending-images"],paths as string[]);
    if(cleanupJobs.length>500){
     cleanupFailures.push(table+":"+String(row.id));
     console.error("expiry cleanup job batch exceeds safety limit",table,String(row.id));
     continue;
    }
    if(!await enqueueStorageCleanup(url,key,cleanupJobs)){
     cleanupFailures.push(table+":"+String(row.id));
     console.error("expiry cleanup could not be staged; listing preserved",table,String(row.id));
     continue;
    }
    const deletion=await fetch(url+"/rest/v1/rpc/delete_post_and_activate_storage_cleanup",{
     method:"POST",
     headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},
     body:JSON.stringify({
      p_table:table,
      p_id:String(row.id),
      p_expected_user_id:null,
      p_require_owner:false,
      p_expected_row:row,
      p_jobs:cleanupJobs
     })
    });
    if(!deletion.ok){
     deleteErrors.push(table+":"+String(row.id));
     console.error("expiry atomic delete failed",table,String(row.id),deletion.status,await deletion.text().catch(()=> ""));
     continue;
    }
    const outcome=await deletion.json().catch(()=>null);
    if(!outcome||outcome.deleted!==true){
     deleteErrors.push(table+":"+String(row.id));
     console.warn("expiry snapshot changed before deletion; listing retained",table,String(row.id));
     continue;
    }
    count++;
   }
   if(rows.length<100)break;
  }
  result[table]=count;protectedSkipped[table]=protectedCount;
 }
 const totalDeleted=Object.values(result).reduce((sum,count)=>sum+Math.max(count,0),0);
 if(cleanupFailures.length)await sendAdminAlert("تعذّر تجهيز تنظيف بعض الإعلانات المنتهية","تم الإبقاء على الإعلانات وصورها دون حذف لأن تسجيل مهام تنظيف الصور لم ينجح:\n"+cleanupFailures.join("\n"));
 if(totalDeleted>0)await sendAdminAlert("ملخّص الحذف الآلي في أحلى توانسة","تم حذف إعلانات انتهت مدتها بعد 3 أشهر.\n"+Object.entries(result).map(([table,count])=>table+": "+count).join("\n"));
 if(scanErrors.length)await sendAdminAlert("خطأ تقني في الحذف الآلي","تعذّر فحص بعض أقسام الإعلانات: "+[...new Set(scanErrors)].join(", ")+". راجع سجلات Supabase.");
 if(deleteErrors.length)await sendAdminAlert("تعذّر حذف بعض الإعلانات المنتهية","فشلت عملية حذف بعض السجلات: "+deleteErrors.slice(0,100).join("\n")+(deleteErrors.length>100?"\nوبقية السجلات في سجلات الوظيفة.":""));
 if(invalidPathSkips.length)await sendAdminAlert("مراجعة مسارات صور إعلانات منتهية","تم إيقاف حذف بعض الإعلانات بسبب مسارات صور غير متوقعة: "+invalidPathSkips.slice(0,100).join("\n")+(invalidPathSkips.length>100?"\nوبقية السجلات في سجلات الوظيفة.":""));
 return new Response(JSON.stringify({ok:scanErrors.length===0&&deleteErrors.length===0&&invalidPathSkips.length===0&&cleanupFailures.length===0,deleted:result,protectedSkipped,deleteFailures:deleteErrors.length,invalidImagePathSkips:invalidPathSkips.length,cleanupFailures:cleanupFailures.length}),{headers:{"Content-Type":"application/json"}});
});
