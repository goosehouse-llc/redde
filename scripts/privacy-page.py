#!/usr/bin/env python3
# Turns docs/privacy.md into the page at legal.goosehouse.org/redde/privacy, in the template the page
# already has (its head and styles kept). The legal site is the homeschoolwizard-legal Worker, whose
# source is the HomeschoolWizard project's legal/ folder:
#
#   python3 scripts/privacy-page.py docs/privacy.md ~/Projects/HomeschoolWizard/legal/public/redde/privacy.html
#   cd ~/Projects/HomeschoolWizard/legal && npx wrangler deploy
#
# Compare the other pages there with the live ones first: a deploy sends them all.
import html, pathlib, re, sys
md_path, page_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
md = md_path.read_text()
md = re.sub(r"\A---\n.*?\n---\n", "", md, flags=re.S)
page = page_path.read_text()
head = page[:page.index("<body>") + len("<body>")]

def inline(text):
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>', out)
    out = re.sub(r"(?<![\"/>])\b(hello@goosehouse\.org)\b", r'<a href="mailto:\1">\1</a>', out)
    return out

body, para, items = [], [], []
def flush():
    global para, items
    if para: body.append(f"<p>{inline(' '.join(para))}</p>"); para = []
    if items: body.append("<ul>\n" + "\n".join(f"<li>{inline(i)}</li>" for i in items) + "\n</ul>"); items = []

meta = {}
for line in md.splitlines():
    s = line.rstrip()
    m = re.match(r"\*\*(Effective date|Publisher):\*\*\s*(.+)", s)
    if m: meta[m.group(1)] = m.group(2); continue
    if s.startswith("# "): flush(); body.append(f"<h1>{inline(s[2:])}</h1>"); continue
    if s.startswith("## "): flush(); body.append(f"<h2>{inline(s[3:])}</h2>"); continue
    if s.startswith("### "): flush(); body.append(f"<h3>{inline(s[4:])}</h3>"); continue
    if s.startswith("- "): 
        if para: flush()
        items.append(s[2:]); continue
    if not s: flush(); continue
    if items and line.startswith("  "): items[-1] += " " + s.strip(); continue
    if items: flush()
    para.append(s.strip())
flush()
assert body[0].startswith("<h1>"), body[0]
body.insert(1, f'<p class="meta"><strong>Effective date:</strong> {meta["Effective date"]} · <strong>Publisher:</strong> {meta["Publisher"]}</p>')
page_path.write_text(head + "\n" + "\n".join(body) + "\n</body>\n</html>\n")
print(f"{len(body)} blocks, effective {meta['Effective date']}")
