(function(){
"use strict";
let client=null;
let currentUser=null;
let loaded=new WeakSet();
const busy=new WeakSet();

function escapeHtml(value){
 return String(value??"").replace(/[&<>"']/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[ch]));
}
function addStyles(){
 if(document.getElementById("ahla-comments-styles"))return;
 const style=document.createElement("style");
 style.id="ahla-comments-styles";
 style.textContent=`
 .post-comments{margin-top:14px;padding-top:10px;border-top:1px solid #e5ecea}
 .post-comments-toggle{border:1px solid #d6e4e0;background:#f7fbfa;color:#155b55;border-radius:11px;padding:8px 13px;font:inherit;font-size:15px;cursor:pointer}
 .post-comments-panel{margin-top:10px;padding:12px;background:#fbfdfc;border:1px solid #e3ece9;border-radius:13px}
 .post-comment{padding:10px 0;border-bottom:1px solid #e8efed}
 .post-comment:last-child{border-bottom:0}
 .post-comment-meta{font-size:13px;color:#718078;display:flex;gap:8px;align-items:center}
 .post-comment-body{white-space:pre-wrap;overflow-wrap:anywhere;margin:4px 0;font-size:15px}
 .post-comment-action{border:0;background:transparent;color:#087f78;padding:3px 8px;cursor:pointer;font:inherit;font-size:13px}
 .post-comment-form{display:grid;gap:8px;margin-top:10px}
 .post-comment-form textarea{width:100%;min-height:76px;resize:vertical;border:1px solid #d4e0dc;border-radius:10px;padding:10px;font:inherit;font-size:15px;background:#fff}
 .post-comment-send{justify-self:start;border:0;border-radius:10px;background:#087f78;color:#fff;padding:8px 16px;font:inherit;font-size:14px;cursor:pointer}
 .post-comment-send:disabled{opacity:.55;cursor:wait}
 .post-comment-replies{margin-right:14px;padding-right:10px;border-right:2px solid #dbe9e5}
 .post-comment-login{font-size:14px;color:#687789}
 .post-comment-login button{border:0;background:none;color:#087f78;text-decoration:underline;font:inherit;cursor:pointer}
 .post-comment-error{color:#a23c32;font-size:13px}
 `;
 document.head.appendChild(style);
}
function makeForm(parentId){
 return '<form class="post-comment-form" data-comment-form data-parent-id="'+(parentId||"")+'">'+
  '<textarea maxlength="1000" required placeholder="'+(parentId?"اكتب ردّك هنا...":"اكتب تعليقك على المنشور...")+'"></textarea>'+
  '<button class="post-comment-send" type="submit">نشر '+(parentId?"الرد":"التعليق")+'</button><div class="post-comment-error" aria-live="polite"></div></form>';
}
function loginPrompt(){
 return '<p class="post-comment-login">باش تشارك بتعليق، سجّل الدخول أو أنشئ حسابك. <button type="button" data-comment-login>الدخول للحساب</button></p>';
}
function makeEditForm(commentId,body){
 return '<form class="post-comment-form" data-edit-comment-form data-comment-id="'+Number(commentId)+'">'+
  '<textarea maxlength="1000" required aria-label="تعديل التعليق">'+escapeHtml(body)+'</textarea>'+
  '<div><button class="post-comment-send" type="submit">حفظ التعديل</button> <button class="post-comment-action" type="button" data-cancel-edit>إلغاء</button></div>'+
  '<div class="post-comment-error" aria-live="polite"></div></form>';
}
function renderComment(comment,all){
 const mine=currentUser&&currentUser.id===comment.user_id;
 const replies=all.filter(item=>item.parent_id===comment.id);
 let html='<article class="post-comment" data-comment-id="'+comment.id+'">'+
  '<div class="post-comment-meta"><strong>'+(mine?"أنت":comment.user_id===null?"عضو سابق":"عضو")+'</strong><span>'+escapeHtml(new Date(comment.created_at).toLocaleString("ar-TN"))+'</span></div>'+
  '<p class="post-comment-body">'+escapeHtml(comment.body)+'</p>'+
  (currentUser?'<button type="button" class="post-comment-action" data-reply="'+comment.id+'">ردّ</button>':"")+
  (mine?'<button type="button" class="post-comment-action" data-edit-comment="'+comment.id+'">تعديل</button>'+(replies.length?'<span class="post-comment-login">لا يمكن حذف تعليق فيه ردود</span>':'<button type="button" class="post-comment-action" data-delete-comment="'+comment.id+'">حذف</button>'):"")+
  '<div data-reply-slot="'+comment.id+'"></div>';
 if(replies.length){
  html+='<div class="post-comment-replies">'+replies.map(reply=>'<article class="post-comment" data-comment-id="'+reply.id+'"><div class="post-comment-meta"><strong>'+(currentUser&&currentUser.id===reply.user_id?"أنت":reply.user_id===null?"عضو سابق":"عضو")+'</strong><span>'+escapeHtml(new Date(reply.created_at).toLocaleString("ar-TN"))+'</span></div><p class="post-comment-body">'+escapeHtml(reply.body)+'</p>'+(currentUser&&currentUser.id===reply.user_id?'<button type="button" class="post-comment-action" data-edit-comment="'+reply.id+'">تعديل</button><button type="button" class="post-comment-action" data-delete-comment="'+reply.id+'">حذف</button>':"")+'</article>').join("")+'</div>';
 }
 return html+'</article>';
}
async function refreshUser(){
 if(!client)return;
 const {data,error}=await client.auth.getUser();
 currentUser=error?null:data?.user||null;
 if(currentUser?.is_anonymous)currentUser=null;
}
async function loadComments(widget){
 const panel=widget.querySelector("[data-comments-panel]");
 if(!panel||busy.has(widget))return;
 busy.add(widget);panel.innerHTML='<p class="post-comment-login">جاري تحميل التعليقات...</p>';
 try{
  await refreshUser();
  const {data,error}=await client.from("post_comments")
   .select("id,post_id,parent_id,user_id,body,created_at")
   .eq("post_table",widget.dataset.postTable)
   .eq("post_id",Number(widget.dataset.postId))
   .eq("status","published")
   .order("created_at",{ascending:false})
   .limit(200);
  if(error)throw error;
  // Fetch the newest comments first, then render them in chronological order.
  const rows=(data||[]).reverse();
  const top=rows.filter(row=>!row.parent_id);
  const count=rows.length;
  const toggle=widget.querySelector("[data-comments-toggle]");
  if(toggle)toggle.textContent="💬 التعليقات ("+(count===200?"200+":count)+")";
  panel.innerHTML=(top.length?top.map(row=>renderComment(row,rows)).join(""):'<p class="post-comment-login">ما فماش تعليقات. كن أوّل واحد يعلّق!</p>')+
   (currentUser?makeForm(""):loginPrompt());
  loaded.add(widget);
 }catch(error){
  panel.innerHTML='<p class="post-comment-error">تعذّر تحميل التعليقات. تثبّت من الاتصال وعاود.</p><button type="button" class="post-comment-action" data-comments-retry>إعادة المحاولة</button>';
  console.warn("Post comments:",error);
 }finally{busy.delete(widget);}
}
async function submitComment(form,widget){
 const textarea=form.querySelector("textarea"),button=form.querySelector("button[type=submit]");
 const errorBox=form.querySelector(".post-comment-error");
 const body=textarea.value.trim();
 if(!body){errorBox.textContent="اكتب تعليقك قبل النشر.";return;}
 if(body.length>1000){errorBox.textContent="التعليق طويل برشة. الحدّ الأقصى 1000 حرف.";return;}
 await refreshUser();
 if(!currentUser){errorBox.textContent="يلزمك تسجّل الدخول قبل التعليق.";return;}
 button.disabled=true;errorBox.textContent="";
 try{
  const parentRaw=form.dataset.parentId;
  const payload={post_table:widget.dataset.postTable,post_id:Number(widget.dataset.postId),user_id:currentUser.id,body,status:"published"};
  if(parentRaw)payload.parent_id=Number(parentRaw);
  const {error}=await client.from("post_comments").insert(payload);
  if(error)throw error;
  await loadComments(widget);
 }catch(error){
  errorBox.textContent="ما نجّمش ننشر التعليق. تثبّت من تسجيل الدخول وعاود المحاولة.";
  button.disabled=false;
 }
}
function onClick(event){
 const toggle=event.target.closest("[data-comments-toggle]");
 if(toggle){
  const widget=toggle.closest("[data-post-comments]");
  const panel=widget.querySelector("[data-comments-panel]");
  panel.hidden=!panel.hidden;
  toggle.setAttribute("aria-expanded",String(!panel.hidden));
  if(!panel.hidden&&!loaded.has(widget))loadComments(widget);
  return;
 }
 const login=event.target.closest("[data-comment-login]");
 if(login){if(typeof window.show==="function")window.show("account");else window.location.hash="account";return;}
 const retry=event.target.closest("[data-comments-retry]");
 if(retry){const widget=retry.closest("[data-post-comments]");if(widget)loadComments(widget);return;}
 const reply=event.target.closest("[data-reply]");
 if(reply){
  const widget=reply.closest("[data-post-comments]");
  const slot=reply.parentElement.querySelector('[data-reply-slot="'+reply.dataset.reply+'"]');
  if(slot){slot.innerHTML=slot.innerHTML? "":makeForm(reply.dataset.reply);const area=slot.querySelector("textarea");if(area)area.focus();}
  return;
 }
 const edit=event.target.closest("[data-edit-comment]");
 if(edit){
  const widget=edit.closest("[data-post-comments]");
  const article=edit.closest("[data-comment-id]");
  const body=article?.querySelector(".post-comment-body");
  if(widget&&article&&body&&!article.querySelector("[data-edit-comment-form]")){
   body.hidden=true;
   body.insertAdjacentHTML("afterend",makeEditForm(edit.dataset.editComment,body.textContent||""));
   article.querySelector("[data-edit-comment-form] textarea")?.focus();
  }
  return;
 }
 const cancel=event.target.closest("[data-cancel-edit]");
 if(cancel){
  const form=cancel.closest("[data-edit-comment-form]");
  const article=form?.closest("[data-comment-id]");
  if(article){const body=article.querySelector(".post-comment-body");if(body)body.hidden=false;}
  form?.remove();
  return;
 }
 const remove=event.target.closest("[data-delete-comment]");
 if(remove){
  if(!currentUser||!window.confirm("تحب تحذف التعليق هذا؟"))return;
  const widget=remove.closest("[data-post-comments]");
  client.from("post_comments").delete().eq("id",Number(remove.dataset.deleteComment)).eq("user_id",currentUser.id)
   .then(({error})=>{if(error)throw error;loaded.delete(widget);return loadComments(widget);})
   .catch(error=>alert("تعذّر حذف التعليق: "+(error.message||"عاود المحاولة.")));
 }
}
async function submitEdit(form,widget){
 const textarea=form.querySelector("textarea"),button=form.querySelector("button[type=submit]");
 const errorBox=form.querySelector(".post-comment-error");
 const body=textarea.value.trim();
 if(!body){errorBox.textContent="اكتب التعليق قبل حفظ التعديل.";return;}
 if(body.length>1000){errorBox.textContent="التعليق طويل برشة. الحدّ الأقصى 1000 حرف.";return;}
 await refreshUser();
 if(!currentUser){errorBox.textContent="يلزمك تسجّل الدخول قبل التعديل.";return;}
 button.disabled=true;errorBox.textContent="";
 try{
  const {error}=await client.from("post_comments")
   .update({body})
   .eq("id",Number(form.dataset.commentId))
   .eq("user_id",currentUser.id);
  if(error)throw error;
  loaded.delete(widget);
  await loadComments(widget);
 }catch(error){
  errorBox.textContent="ما نجّمش نحفظ التعديل. تثبّت من تسجيل الدخول وعاود.";
  button.disabled=false;
 }
}
function onSubmit(event){
 const editForm=event.target.closest("[data-edit-comment-form]");
 if(editForm){
  event.preventDefault();
  const widget=editForm.closest("[data-post-comments]");
  if(widget)submitEdit(editForm,widget);
  return;
 }
 const form=event.target.closest("[data-comment-form]");
 if(!form)return;
 event.preventDefault();
 const widget=form.closest("[data-post-comments]");
 if(widget)submitComment(form,widget);
}
function init(){
 if(client||!window.ahlaTounsaSupabase)return;
 client=window.ahlaTounsaSupabase;
 addStyles();
 refreshUser().catch(()=>{});
 client.auth.onAuthStateChange((_event,session)=>{
  currentUser=session?.user&&!session.user.is_anonymous?session.user:null;
  loaded=new WeakSet();
  // Defer Supabase queries until the auth callback has returned and released its lock.
  window.setTimeout(()=>{
   document.querySelectorAll("[data-post-comments]:not([hidden]) [data-comments-panel]").forEach(panel=>{
    if(!panel.hidden){const widget=panel.closest("[data-post-comments]");if(widget)loadComments(widget);}
   });
  },0);
 });
 document.addEventListener("click",onClick);
 document.addEventListener("submit",onSubmit);
}
if(window.ahlaTounsaSupabase)init();
window.addEventListener("ahla:supabase-ready",init);
})();
