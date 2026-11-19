export const PROTECTED_DEMO_IDS: Record<string, readonly string[]> = {
  service_requests: ["13"],
  job_posts: ["7"],
  market_posts: ["2", "3", "7", "8", "9"],
  real_estate_posts: ["1", "2", "6"],
};
const DEMO_TEXT_PATTERN = /(تجر(?:ي)?ب|اختبار|test|demo|مثال)/i;
export function isProtectedDemoPost(table: string, id: string | number, title: unknown, description: unknown): boolean {
  if ((PROTECTED_DEMO_IDS[table] ?? []).includes(String(id))) return true;
  return DEMO_TEXT_PATTERN.test(`${String(title ?? "")} ${String(description ?? "")}`);
}
