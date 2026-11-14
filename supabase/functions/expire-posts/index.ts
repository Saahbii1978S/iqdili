import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const TOKEN_HASH="5315d23014e4a1d37335410ac337d9f10d5d4408019d9f165a6b557130a09dd3";
const tables:Record<string,{bucket:string,folder:string}>={service_requests:{bucket:"listing-images",folder:"services"},job_posts:{bucket:"listing-images",folder:"jobs"},real_estate_posts:{bucket:"listing-images",folder:"realty"},market_posts:{bucket:"market-images",folder:"market"}};
async function sha(v:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v));return [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,"0")).join("");}
function validPath(p:unknown,f:string):p is string{return typeof p==="string"&&p.startsWith(f+"/")&&/^[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$/i.test(p)&&!p.includes("..")&&!p.includes("//");}
async function remove(url:string,key:string,bucket:string,paths:string[]){if(!paths.length)return true;const r=await fetch(url+"/storage/v1/object/"+bucket,{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},body:JSON.stringify({prefixes:paths})});if(!r.ok){console.error("expiry storage removal",bucket,r.status);return false;}return true;}

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

Deno.serve(async(req:Request)=>{
 if(req.method!=="POST")return new Response("Method not allowed",{status:405});
 const auth=req.headers.get("authorization")||"";
 if(!auth.startsWith("Bearer ")||await sha(auth.slice(7))!==TOKEN_HASH)return new Response("Unauthorized",{status:401});
 const url=Deno.env.get("SUPABASE_URL")!,key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const result:Record<string,number>={};
 const cleanupFailures:string[]=[];
 for(const [table,c] of Object.entries(tables)){
  const now=new Date().toISOString();
  const q=await fetch(url+"/rest/v1/"+table+"?status=eq.approved&expires_at=lte."+encodeURIComponent(now)+"&select=id,image_urls&limit=100",{headers:{apikey:key,Authorization:"Bearer "+key}});
  if(!q.ok){result[table]=-1;continue;}
  const rows=await q.json();let count=0;
  for(const row of rows){
   const paths=Array.isArray(row.image_urls)?row.image_urls:[];
   if(paths.some((p:unknown)=>!validPath(p,c.folder)))continue;
   const d=await fetch(url+"/rest/v1/"+table+"?id=eq."+encodeURIComponent(String(row.id))+"&status=eq.approved&expires_at=lte."+encodeURIComponent(now),{method:"DELETE",headers:{apikey:key,Authorization:"Bearer "+key,Prefer:"return=representation"}});
   if(!d.ok)continue;
   const deleted=await d.json().catch(()=>null);
   if(!Array.isArray(deleted)||deleted.length!==1)continue;
   count++;
   // Remove the Storage copies only after the expired database row is gone.
   const publicClean=await remove(url,key,c.bucket,paths);
   const pendingClean=await remove(url,key,"pending-images",paths);
   if(!publicClean||!pendingClean){cleanupFailures.push(table+":"+String(row.id));console.error("Expired listing deleted but image cleanup is pending",table,row.id);}
  }
  result[table]=count;
 }
 const totalDeleted = Object.values(result).reduce((sum, count) => sum + Math.max(count, 0), 0);
 const hadErrors = Object.values(result).some((count) => count < 0);
 if(cleanupFailures.length)await sendAdminAlert("تنبيه تنظيف صور الإعلانات المنتهية","تم حذف الإعلانات من قاعدة البيانات، لكن بقيت صور تحتاج تنظيفاً:\n"+cleanupFailures.join("\n"));
 if (totalDeleted > 0) await sendAdminAlert("ملخّص الحذف الآلي في أحلى توانسة", "تم حذف إعلانات انتهت مدتها بعد 3 أشهر.\n" + Object.entries(result).map(([table, count]) => table + ": " + count).join("\n"));
 if (hadErrors) await sendAdminAlert("خطأ تقني في الحذف الآلي", "تعذّر فحص أو معالجة بعض أقسام الإعلانات أثناء مهمة الحذف الآلي. راجع سجلات Supabase.");
 return new Response(JSON.stringify({ok:true,deleted:result}),{headers:{"Content-Type":"application/json"}});
});