#!/usr/bin/env python3
"""Writes the installer's welcome and closing pages, one pair per language in pages.json, into <out>/<language>.lproj.
The Installer picks the pair that matches the system's language and falls back to English.
    make-pages.py <output folder>"""
import html, json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1]
template = open(os.path.join(here, "page-template.html"), encoding="utf-8").read()
pages = json.load(open(os.path.join(here, "pages.json"), encoding="utf-8"))
right_to_left = {"ar", "he", "ur"}
for language, texts in pages.items():
    folder = os.path.join(out, language + ".lproj")
    os.makedirs(folder, exist_ok=True)
    for name in ("welcome", "conclusion"):
        title, *paragraphs = texts[name]
        body = "\n".join("<p>" + html.escape(p) + "</p>" for p in paragraphs)
        page = (template.replace("@LANG@", language).replace("@DIR@", "rtl" if language in right_to_left else "ltr")
                .replace("@TITLE@", html.escape(title)).replace("@BODY@", body))
        open(os.path.join(folder, name + ".html"), "w", encoding="utf-8").write(page)
print(len(pages), "languages")
