from pathlib import Path

source = Path("index.html").read_text(encoding="utf-8")

checks = {
    "one-time retry guard exists": "let publicDataReadyRefreshDone=false;" in source,
    "retry runs only after Supabase client exists": "if(db){" in source and "startSitePresence();" in source,
    "only listing sections trigger retry": '["services","jobs","realty","market"].some(id=>' in source,
    "section visibility is checked": 'return section&&!section.classList.contains("hidden");' in source,
    "retry is guarded against duplicate calls": "if(visibleListingSection&&!publicDataReadyRefreshDone){" in source,
    "guard is set before reload": "publicDataReadyRefreshDone=true;\n  loadData();" in source,
    "connect runs at startup": "connect();" in source,
    "late SDK load retries connection": 'supabaseSdkScript.addEventListener("load",connect,{once:true})' in source,
}
failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(("PASS" if passed else "FAIL") + ": " + name)
if failed:
    raise SystemExit(1)
