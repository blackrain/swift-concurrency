#!/usr/bin/env python3
"""Assemble the guide into one book-structured Markdown file (with raw HTML for openers).

usage: build_md.py <guide-root> <out.md> [<pages.json>]
pages.json (optional) maps anchor -> page number, used to fill the table of contents.
"""
import json, os, re, sys, html

root, out = sys.argv[1], sys.argv[2]
pages = json.load(open(sys.argv[3])) if len(sys.argv) > 3 and os.path.exists(sys.argv[3]) else {}

PARTS = [
    ("00-foundations", "0", "Foundations"),
    ("01-async-await", "1", "async/await"),
    ("02-structured-concurrency", "2", "Structured Concurrency"),
    ("03-isolation-and-actors", "3", "Isolation and Actors"),
    ("04-sendable-and-safety", "4", "Sendable and Data-Race Safety"),
    ("05-async-sequences", "5", "Async Sequences"),
    ("06-apps", "6", "Concurrency in Apps"),
    ("07-internals", "7", "Internals"),
]
APPENDICES = [("capstone.md", "A"), ("cheatsheet.md", "B"), ("glossary.md", "C"), ("resources.md", "D")]

def slug(path): return "ch-" + re.sub(r'[^a-z0-9]+', '-', path.lower().removesuffix('.md')).strip('-')
def inline(md):  # minimal inline markdown -> HTML for titles
    s = html.escape(md, quote=False)
    return re.sub(r'`([^`]+)`', r'<code>\1</code>', s)

def body_of(rel):
    text = open(os.path.join(root, rel)).read()
    base = os.path.dirname(rel)
    def fix(m):
        target = m.group(1)
        if target.startswith('http'): return m.group(0)
        return f"](#{slug(os.path.normpath(os.path.join(base, target)))})"
    text = re.sub(r'\]\(([^)#\s]+?\.md)(#[^)]*)?\)', fix, text)
    text = re.sub(r'\]\((0\d-[a-z-]+)/\)', lambda m: f"](#{slug(m.group(1) + '/' + sorted(os.listdir(os.path.join(root, m.group(1))))[0])})", text)
    text = re.sub(r'<!--\s*check:.*?-->\n', '', text)
    text = re.sub(r'^<details>', '<details open>', text, flags=re.M)
    title, _, body = text.partition('\n')
    return title.lstrip('# ').strip(), body

def label_and_title(title):
    m = re.match(r'^(\d+\.\d+)\s+(.*)$', title)
    return (m.group(1), m.group(2)) if m else (None, title)

chunks, toc = [], []

# --- front matter -------------------------------------------------------------
chunks.append('''<section class="titlepage">
<div class="tp-title">Mastering Swift Concurrency</div>
<div class="tp-subtitle">From Fundamentals to Runtime Internals</div>
<div class="tp-rule"></div>
<div class="tp-edition">Swift 6.4 &middot; Xcode 27.1 Edition</div>
</section>

<section class="copyright">
<p><b>Mastering Swift Concurrency</b><br/>From Fundamentals to Runtime Internals</p>
<p>Swift 6.4 / Xcode 27.1 Edition, October 2026.</p>
<p>Every code listing in this book was compiled with the Swift 6.4 compiler in the Swift 6 language mode; listings that demonstrate an error were checked to produce the quoted diagnostic, and listings that show output were executed. API names and proposal statuses were checked against the <i>swiftlang/swift-evolution</i> and <i>swiftlang/swift</i> repositories and the installed SDK interfaces.</p>
<p>Cover illustration: line engraving rendered from a photograph of a long-coat German Shepherd Dog, supplied by the reader.</p>
<p>Swift, Xcode, SwiftUI, SwiftData, and Instruments are trademarks of Apple Inc. Swift Evolution proposal titles are quoted for reference.</p>
<p>While every effort has been made to verify the information in this book, behavior can change between toolchain releases. Re-run <code>tools/check-snippets.py</code> against a newer toolchain to find what changed.</p>
</section>
''')

TOC_PLACEHOLDER = "@@TOC@@"
chunks.append(TOC_PLACEHOLDER)

pre_title, pre_body = body_of("README.md")
# drop the generated table of contents from the README (the book has its own)
pre_body = re.sub(r'## Table of contents.*?(?=\n## )', '', pre_body, flags=re.S)
chunks.append(f'<section class="chapter-opener preface" id="ch-preface"><div class="label">Preface</div><h1>{inline(pre_title)}</h1></section>\n\n{pre_body}')
toc.append(("front", "ch-preface", "Preface", None))
meta = [{"sid": "ch-preface", "kind": "chapter", "label": "PREFACE", "title": "Preface"}]

# --- parts and chapters ----------------------------------------------------------
for d, num, name in PARTS:
    pid = f"part-{num}"
    chunks.append(f'<section class="part-page" id="{pid}"><div class="part-label">Part {num}</div><div class="part-title">{inline(name)}</div></section>')
    toc.append(("part", pid, f"Part {num}. {name}", None))
    meta.append({"sid": pid, "kind": "part", "label": f"PART {num}", "title": name})
    for f in sorted(os.listdir(os.path.join(root, d))):
        rel = f"{d}/{f}"
        title, body = body_of(rel)
        lab, t = label_and_title(title)
        sid = slug(rel)
        chunks.append(f'<section class="chapter-opener" id="{sid}"><div class="label">Chapter {lab}</div><h1>{inline(t)}</h1></section>\n\n{body}')
        toc.append(("chapter", sid, t, lab))
        meta.append({"sid": sid, "kind": "chapter", "label": f"CHAPTER {lab}", "title": f"{lab}  {re.sub(chr(96), chr(32)*0, t)}"})

# --- appendices ----------------------------------------------------------------
chunks.append('<section class="part-page" id="part-appendices"><div class="part-label">Appendices</div><div class="part-title">Reference</div></section>')
toc.append(("part", "part-appendices", "Appendices", None))
meta.append({"sid": "part-appendices", "kind": "part", "label": "APPENDICES", "title": "Appendices"})
for rel, letter in APPENDICES:
    title, body = body_of(rel)
    sid = slug(rel)
    chunks.append(f'<section class="chapter-opener" id="{sid}"><div class="label">Appendix {letter}</div><h1>{inline(title)}</h1></section>\n\n{body}')
    toc.append(("chapter", sid, title, letter))
    meta.append({"sid": sid, "kind": "chapter", "label": f"APPENDIX {letter}", "title": f"Appendix {letter}  {title}"})

# --- table of contents with (optional) page numbers --------------------------------
rows = ['<section class="toc" id="toc"><h1 class="toc-title">Table of Contents</h1><ul>']
for kind, sid, title, lab in toc:
    pg = pages.get(sid, "")
    num = f'<span class="toc-num">{lab}</span>' if lab else ''
    rows.append(f'<li class="toc-{kind}"><a href="#{sid}">{num}<span class="toc-text">{inline(title)}</span><span class="toc-dots"></span><span class="toc-page">{pg}</span></a></li>')
rows.append('</ul></section>')
md = "\n\n".join(chunks).replace(TOC_PLACEHOLDER, "\n".join(rows))
open(out, "w").write(md)
json.dump(meta, open(os.path.join(os.path.dirname(out) or ".", "meta.json"), "w"), indent=1)
print(f"{len(toc)} toc entries, {sum(1 for t in toc if t[0]=='chapter')} chapters/appendices")
