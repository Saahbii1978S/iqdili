#!/usr/bin/env python3
"""Static regression checks for the public page's inline JavaScript and presence lifecycle."""
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
import tempfile

HTML = Path("index.html").read_text(encoding="utf-8")

class InlineScripts(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.items = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "script":
            return
        attrs = dict(attrs)
        script_type = (attrs.get("type") or "text/javascript").lower()
        if attrs.get("src") or script_type not in {
            "text/javascript", "application/javascript", "module"
        }:
            self.current = None
            return
        self.current = []

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)

    def handle_endtag(self, tag):
        if tag.lower() == "script" and self.current is not None:
            code = "".join(self.current)
            if code.strip():
                self.items.append(code)
            self.current = None

parser = InlineScripts()
parser.feed(HTML)
assert parser.items, "No inline JavaScript blocks were found"

for number, code in enumerate(parser.items, 1):
    with tempfile.NamedTemporaryFile("w", suffix=".js", encoding="utf-8") as handle:
        handle.write(code)
        handle.flush()
        result = subprocess.run(
            ["node", "--check", handle.name],
            text=True,
            capture_output=True,
        )
    if result.returncode:
        raise SystemExit(
            f"Inline script {number} failed node --check:\n{result.stdout}{result.stderr}"
        )

assert "function restartSitePresence()" in HTML
assert "let sitePresenceGeneration=0;" in HTML
assert "let sitePresenceRestartPending=false;" in HTML
assert "if(generation!==sitePresenceGeneration)return;" in HTML
assert "if(!db||generation!==sitePresenceGeneration)return;" in HTML
for event in ("SIGNED_IN", "SIGNED_OUT"):
    marker = f'if(event==="{event}"){{'
    start = HTML.find(marker)
    assert start >= 0, f"{event} listener is missing"
    next_event = HTML.find('if(event==="', start + len(marker))
    block_end = next_event if next_event >= 0 else HTML.find("\\n});", start)
    assert block_end >= 0 and "restartSitePresence();" in HTML[start:block_end], (
        f"{event} must invalidate and restart the presence check"
    )

assert "pendingSitePageViews" in HTML
assert "queuedPageViews.forEach(pageId=>recordSitePageView(pageId));" in HTML
print(f"Validated {len(parser.items)} inline JavaScript blocks and analytics/presence invariants.")
