import { isProtectedDemoPost } from "./protected-demo.ts";
Deno.test("protects known test record IDs per table", () => {
  if (!isProtectedDemoPost("service_requests", 13, "خدمة", "")) throw new Error("known service test ID must be protected");
  if (isProtectedDemoPost("job_posts", 13, "وظيفة", "")) throw new Error("protected IDs must remain table-specific");
});
Deno.test("protects Arabic and English test labels", () => {
  const cases: Array<[string, string]> = [["إعلان تجريبي", ""], ["", "هذا اختبار"], ["test listing", ""], ["", "demo content"], ["مثال على الخدمة", ""], ["هذه تجربة قديمة", ""]];
  for (const [title, description] of cases) if (!isProtectedDemoPost("job_posts", 999999, title, description)) throw new Error(`expected test content to be protected: ${title} ${description}`);
});
Deno.test("does not protect an ordinary listing solely by its ID or text", () => {
  if (isProtectedDemoPost("market_posts", 999999, "كرسي مستعمل", "في حالة جيدة")) throw new Error("ordinary listing must not be treated as a test");
});
