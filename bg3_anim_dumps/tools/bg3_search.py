#!/usr/bin/env python3
"""
bg3_search.py — поиск по игровым файлам BG3 через онлайн-движок Norbyte (bg3.norbyte.dev).

Использование:
    python3 tools/bg3_search.py "type:animation imp DFLT_PM"
    python3 tools/bg3_search.py "type:animation Whetstone"

Синтаксис запросов (движок Norbyte):
    type:animation          только ресурсы типа Animation
    type:animationset, type:animationblueprint, type:ikrig, type:skeleton, ...
    name:ExactName          точное имя ресурса
    uuid:xxxx-xxxx          точный UUID
    -слово                  исключить
    A | B                   ИЛИ
    Pierc*                  префикс
    "два слова"             точная фраза

Выдача: имя | путь SourceFile | UUID. Движок отдаёт 30 результатов на запрос —
сужайте запрос, пока не получите полный список ("showing N of N").
"""
import sys, re, html, urllib.parse, subprocess, json
q = sys.argv[1]
url = "https://bg3.norbyte.dev/search?q=" + urllib.parse.quote(q)
raw = subprocess.run(["curl","-s","--max-time","50",url],capture_output=True,text=True).stdout
t = html.unescape(raw)
total = re.search(r'Showing results 1 - (\d+) of (\d+)', re.sub(r'<[^>]+>',' ',t))
res = []
# each result: block starting at "Copy LSX" region; parse node Resource blocks
for m in re.finditer(r'<attribute id="ID" type="FixedString" value="([0-9a-f\-]+)" />(.*?)</node>', t, flags=re.S):
    uid, body = m.group(1), m.group(2)
    def g(a):
        mm = re.search(r'<attribute id="%s" type="[^"]+" value="([^"]*)"' % a, body)
        return mm.group(1) if mm else ""
    name, src = g("Name"), g("SourceFile")
    if not src: continue
    res.append((name, src, uid, g("Duration"), g("Looping"), g("SkeletonResource")))
seen=set(); out=[]
for r in res:
    if r[1] in seen: continue
    seen.add(r[1]); out.append(r)
print("QUERY:", q, "| showing", total.group(1) if total else "?", "of", total.group(2) if total else "?")
for n,s,u,d,l,sk in out:
    print(f"{n:52s} {u}  dur={d:>9s} loop={l:5s} skel={sk} | {s}")
print("returned unique:", len(out))

