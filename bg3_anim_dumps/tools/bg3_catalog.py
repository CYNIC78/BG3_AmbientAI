#!/usr/bin/env python3
"""
bg3_catalog.py — сборка каталога анимаций BG3 через поисковик Norbyte (bg3.norbyte.dev).

Идея. Движок отдаёт максимум 30 результатов на запрос, но у каждого результата есть
скрытый атрибут data-xrefs — base64 JSON со ВСЕМИ ресурсами, на которые ссылается
результат. Один анимационный сет (animationset) ссылается на десятки-сотни клипов,
поэтому один запрос к сету даёт сотни анимаций сразу.

Использование:
    python3 tools/bg3_catalog.py                      # собрать в bg3_anim_dumps/
    python3 tools/bg3_catalog.py --queries my.txt     # свой список запросов
    python3 tools/bg3_catalog.py --only "type:animationset imp"

Запросы (синтаксис движка): type:animation / type:animationset / name:X / uuid:X / -X / A | B

Выход:
    <out>/catalog.json    полные данные (uuid -> name, type, path, queries)
    <out>/catalog.csv     name;uuid;type;path
"""

import sys, re, html, json, base64, os, urllib.parse, subprocess, argparse, collections

BASE = "https://bg3.norbyte.dev/search?q="

DEFAULT_QUERIES = [
    # --- фамильяры и существа -------------------------------------------
    "type:animationset imp",
    "type:animationset quasit",
    "type:animationset pseudodragon",
    "type:animationset sprite",
    "type:animationset cat",
    "type:animationset raven",
    "type:animationset shovel",
    # ---humanoid: тела ---------------------------------------------------
    "type:animationset HUM_F_Rig",
    "type:animationset HUM_M_Rig",
    "type:animationset ELF",
    "type:animationset DWR",
    "type:animationset GTY",
    "type:animationset TIF",
    "type:animationset GNO",
    "type:animationset HLF",
    "type:animationset ORC",
    "type:animationset DGB",
    "type:animationset GOB",
    # --- головы / лица ---------------------------------------------------
    "type:animationset HUM_F_Head",
    "type:animationset HUM_M_Head",
    "type:animationset Head EMOT",
    # --- прямые запросы: дают пути SourceFile ---------------------------
    "type:animation HUM_F_Rig_DFLT_UTIL",
    "type:animation HUM_M_Rig_DFLT_UTIL",
    "type:animation HUM_F_Rig_DFLT_PM",
    "type:animation HUM_F_Rig SIT",
    "type:animation HUM_F EMOT",
    "type:animation HUM_F CAMP",
    "type:animation HUM_F_Rig_DFLT_IDLE",
    "type:animation HUM_F_Rig_DFLT_CUST",
    "type:animation INTERACT",
    "type:animation Whetstone",
    "type:animation imp DFLT_PM",
]


def fetch(q):
    url = BASE + urllib.parse.quote(q)
    return subprocess.run(["curl", "-s", "--max-time", "60", url],
                          capture_output=True, text=True).stdout


def parse(page):
    """-> (xref_entries, direct_results)"""
    entries = {}
    for x in re.findall(r'data-xrefs="([^"]+)"', page):
        try:
            entries.update(json.loads(base64.b64decode(x + "=" * (-len(x) % 4))))
        except Exception:
            pass

    direct = []
    t = html.unescape(page)
    for m in re.finditer(r'<attribute id="ID" type="FixedString" value="([0-9a-fA-F\-]+)" />(.*?)</node>', t, re.S):
        uid, body = m.group(1), m.group(2)

        def g(a):
            mm = re.search(r'<attribute id="%s" type="[^"]+" value="([^"]*)"' % a, body)
            return mm.group(1) if mm else ""
        direct.append({"id": uid, "name": g("Name"), "path": g("SourceFile"),
                       "duration": g("Duration"), "looping": g("Looping"),
                       "skeleton": g("SkeletonResource")})
    return entries, direct


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="bg3_anim_dumps")
    ap.add_argument("--queries", help="файл со списком запросов, по одному на строку")
    ap.add_argument("--only", help="один запрос вместо списка")
    a = ap.parse_args()

    queries = [a.only] if a.only else (
        [l.strip() for l in open(a.queries, encoding="utf-8") if l.strip() and not l.startswith("#")]
        if a.queries else DEFAULT_QUERIES)

    os.makedirs(a.out, exist_ok=True)
    cat = {}   # uuid -> {name,type,path,queries[],duration,looping,skeleton}
    per_query = []

    for q in queries:
        page = fetch(q)
        entries, direct = parse(page)
        n_new = 0
        for uid, e in entries.items():
            if not re.fullmatch(r"[0-9a-fA-F\-]{36}", uid or ""):
                continue
            rec = cat.get(uid)
            if rec is None:
                rec = {"uuid": uid, "name": e.get("name", ""), "type": e.get("typeName", ""),
                       "path": "", "duration": "", "looping": "", "skeleton": "", "queries": []}
                cat[uid] = rec
                n_new += 1
            if q not in rec["queries"]:
                rec["queries"].append(q)
            if e.get("name") and not rec["name"]:
                rec["name"] = e["name"]
        for d in direct:
            rec = cat.get(d["id"])
            if rec is None:
                rec = {"uuid": d["id"], "name": d["name"], "type": "Animation",
                       "path": "", "duration": "", "looping": "", "skeleton": "", "queries": []}
                cat[d["id"]] = rec
                n_new += 1
            rec["path"] = rec["path"] or d["path"]
            rec["duration"] = rec["duration"] or d["duration"]
            rec["looping"] = rec["looping"] or d["looping"]
            rec["skeleton"] = rec["skeleton"] or d["skeleton"]
            if q not in rec["queries"]:
                rec["queries"].append(q)
        per_query.append((q, len(entries), len(direct), n_new))
        print(f"{q:42s} xref={len(entries):5d} direct={len(direct):3d} new={n_new:5d} total={len(cat)}", flush=True)

    anims = [r for r in cat.values() if r["type"] == "Animation" and r["name"]]
    anims.sort(key=lambda r: r["name"].lower())
    others = [r for r in cat.values() if r["type"] != "Animation"]

    json.dump({"generated": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
               "queries": queries, "per_query": per_query, "entries": cat},
              open(os.path.join(a.out, "catalog.json"), "w"), ensure_ascii=False)

    with open(os.path.join(a.out, "catalog.csv"), "w", encoding="utf-8") as f:
        f.write("name;uuid;type;path;skeleton;duration;looping;queries\n")
        for r in sorted(cat.values(), key=lambda r: r["name"].lower()):
            f.write(";".join([r["name"], r["uuid"], r["type"], r["path"], r["skeleton"],
                              r["duration"], r["looping"], "|".join(r["queries"])]) + "\n")

    print(f"\nИТОГО: {len(cat)} ресурсов, из них анимаций: {len(anims)}, прочих: {len(others)}")
    print("Записано:", os.path.join(a.out, "catalog.json"), os.path.join(a.out, "catalog.csv"))


if __name__ == "__main__":
    main()
