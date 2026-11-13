"""Research only: reads `otool -ov` and prints the classes, methods and
properties that name scene accessories, external displays, scene
specifications, session roles or scene hosting."""
import re
import sys

CLASS = re.compile(r"(?:accessor|externaldisplay|scenespecification|scenehosting|sessionrole|noninteractive)", re.I)
METHOD = re.compile(r"(?:sessionrole|sceneaccessor|externaldisplay|noninteractive)", re.I)

classes = []
current = None
section = None
with open(sys.argv[1], errors="replace") as f:
    for line in f:
        s = line.strip()
        m = re.match(r"^[0-9a-f]+ 0x[0-9a-f]+ _OBJC_(?:CLASS|METACLASS)_\$_(\S+)$", s)
        if m and not line.startswith(" "):
            current = {"name": m.group(1), "meta": "METACLASS" in s, "super": None, "methods": [], "props": [], "ivars": []}
            classes.append(current)
            section = None
            continue
        if current is None:
            continue
        if s.startswith("superclass") and current["super"] is None:
            current["super"] = s.split()[-1].replace("_OBJC_CLASS_$_", "").replace("_OBJC_METACLASS_$_", "")
        elif s.startswith("baseMethods"):
            section = "methods"
        elif s.startswith("baseProperties"):
            section = "props"
        elif s.startswith("ivars"):
            section = "ivars"
        elif s.startswith("baseProtocols") or s.startswith("weakIvarLayout"):
            section = None
        elif s.startswith("name ") and section:
            current[section].append([s.split(None, 2)[-1], ""])
        elif s.startswith("types ") and section == "methods" and current["methods"]:
            current["methods"][-1][1] = s.split(None, 2)[-1]
        elif s.startswith("attributes ") and section == "props" and current["props"]:
            current["props"][-1][1] = s.split(None, 2)[-1]
        elif s.startswith("type ") and section == "ivars" and current["ivars"]:
            current["ivars"][-1][1] = s.split(None, 2)[-1]

print(f"{len(classes)} class records")
for c in classes:
    if CLASS.search(c["name"]):
        kind = "+" if c["meta"] else "-"
        print(f"== {c['name']} : {c['super']} ({'meta' if c['meta'] else 'class'})")
        for n, a in c["props"]:
            print(f"    @property {n}  {a}")
        for n, t in c["ivars"]:
            print(f"    ivar {n}  {t}")
        for n, t in c["methods"]:
            print(f"    {kind} {n}  {t}")
print("#### methods elsewhere that name them")
for c in classes:
    if CLASS.search(c["name"]):
        continue
    kind = "+" if c["meta"] else "-"
    for n, t in c["methods"]:
        if METHOD.search(n):
            print(f"  {kind}[{c['name']} {n}]  {t}")
