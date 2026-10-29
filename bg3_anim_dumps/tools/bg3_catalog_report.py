#!/usr/bin/env python3
"""
bg3_catalog_report.py — человекочитаемый отчёт по catalog.json (см. bg3_catalog.py).

    python3 tools/bg3_catalog_report.py bg3_anim_dumps/catalog.json > bg3_anim_dumps/CATALOG.md
"""
import json, sys, re, collections

path = sys.argv[1] if len(sys.argv) > 1 else "bg3_anim_dumps/catalog.json"
data = json.load(open(path, encoding="utf-8"))
entries = data["entries"]
anims = [r for r in entries.values() if r["type"] == "Animation" and r["name"]]

# ---------- классификация ----------
RIGS = ["HUM_M", "HUM_F", "ELF_M", "ELF_F", "DWR_M", "DWR_F", "GTY_M", "GTY_F",
        "TIF_M", "TIF_F", "GNO_M", "GNO_F", "HLF_M", "HLF_F", "ORC_M", "ORC_F",
        "DGB_M", "DGB_F", "GOB_M", "GOB_F", "IMP", "CAT", "RAVEN", "QUASIT"]
TAGS = ["UTIL", "CUST", "SIT", "PM", "EMOT", "IDLE", "LOCO", "CMBT", "STAT", "REAC",
        "CINE", "SCENE", "INTERACT", "TOOL_", "CC", "HIT", "ROM", "EMOTE", "LOOP"]


def rig_of(name):
    n = name.upper()
    for r in RIGS:
        if n.startswith(r):
            return r
    if "_HEAD_" in n or n.startswith("HUM_F_HEAD") or n.startswith("HUM_M_HEAD"):
        return "HEAD/*"
    return "OTHER"


def tags_of(name):
    n = name.upper()
    return [t for t in TAGS if t in n]


by_rig = collections.Counter(rig_of(a["name"]) for a in anims)
by_tag = collections.Counter()
for a in anims:
    for t in tags_of(a["name"]):
        by_tag[t] += 1
with_path = [a for a in anims if a["path"]]

print("# Каталог анимаций BG3\n")
print(f"Сгенерировано: {data['generated']}")
print(f"Запросов: {len(data['queries'])} → **{len(anims)} анимаций** "
      f"(всего ресурсов {len(entries)}), из них с известным путём файла: {len(with_path)}\n")
print("> Пути (SourceFile) есть только у части записей: движок отдаёт их для прямых ")
print("> запросов `type:animation`, а записи, извлечённые из сетов, содержат имя и UUID.\n")

print("## Покрытие по ригам\n")
print("| Риг | Анимаций |")
print("|---|---|")
for rig, n in by_rig.most_common():
    print(f"| {rig} | {n} |")

print("\n## Покрытие по категориям (тег в имени)\n")
print("| Тег | Анимаций | Что это |")
print("|---|---|---|")
MEANING = {
    "UTIL": "бытовые действия (пить, копать, крафтить)",
    "CUST": "ситуативные/кастомные клипы",
    "SIT": "сидение",
    "PM": "Photo Mode — готовые позы",
    "EMOT": "эмоции",
    "IDLE": "стояние, аддитивные шевеления",
    "LOCO": "локомоция",
    "CMBT": "бой",
    "STAT": "состояния (слабость, страх, оглушение)",
    "REAC": "реакции (уклонение, попадание)",
    "CINE": "катсцены",
    "SCENE": "сюжетные сцены",
    "INTERACT": "взаимодействие с объектом",
    "TOOL_": "работа у инструмента",
    "CC": "character creation",
    "HIT": "попадание",
    "ROM": "range of motion (прогон суставов)",
    "EMOTE": "эмоции (альтернативное написание)",
    "LOOP": "зацикленные",
}
for tag, n in by_tag.most_common():
    print(f"| {tag} | {n} | {MEANING.get(tag, '')} |")


def listing(title, items, limit=None, note=""):
    print(f"\n## {title}\n")
    if note:
        print(note + "\n")
    items = sorted(items, key=lambda r: r["name"].lower())
    if limit:
        items = items[:limit]
        print(f"Показано {limit} из {len(items)} (полный список — в catalog.csv).\n")
    print("| Имя | UUID | Путь |")
    print("|---|---|---|")
    for r in items:
        p = r["path"] or "—"
        print(f"| `{r['name']}` | `{r['uuid']}` | `{p}` |")


def sel(pred):
    return [a for a in anims if pred(a["name"].upper())]


listing("Фамильяры: IMP (полный список)", sel(lambda n: n.startswith("IMP")),
        note="Тело: скелет `1e2dd487-c282-52e4-38e4-291d9a901a98`; голова — `7f582f93-18ae-2e98-5177-9e046a6ec7c5`.")
listing("Фамильяры: CAT и RAVEN", sel(lambda n: n.startswith("CAT") or n.startswith("RAVEN")), limit=60)

listing("Быт: UTIL (человек)", sel(lambda n: "_UTIL_" in n and not n.startswith("MMY")), limit=40,
        note="Готовые «жизненные» действия. Часть — триплетами `_Start/_Loop/_End`, что прямо ложится в `LOOP_TO_TRIPLET`.")
listing("Позы: PhotoMode (PM)", sel(lambda n: "_PM_" in n), limit=40)
listing("Сидение: SIT", sel(lambda n: "_SIT" in n), limit=40)
listing("Работа у инструмента / взаимодействие", sel(lambda n: "INTERACT" in n or n.startswith("TOOL_")), limit=40)
listing("Эмоции: EMOT", sel(lambda n: "EMOT" in n), limit=40)
listing("Лагерь и сон: CAMP / Sleep", sel(lambda n: "CAMP" in n or "SLEEP" in n), limit=40)

print("\n## Как пользоваться\n")
print("```bash")
print("python3 tools/bg3_catalog.py                       # пересобрать catalog.json/.csv")
print("python3 tools/bg3_catalog.py --only 'type:animationset imp'")
print("grep -i 'drink' bg3_anim_dumps/catalog.csv         # поиск по готовому каталогу")
print("```\n")
print("catalog.csv колонки: `name;uuid;type;path;skeleton;duration;looping;queries`.")
print("Колонка `queries` показывает, каким запросом запись была найдена — удобно для отладки поиска.")
