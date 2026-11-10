#!/usr/bin/env bash
# Brings an installed copy of the SaXML delivery add-on up to date, whatever version it is on.
# The latest definitions are read from src/SaXMLDelivery.fmp12 in this repo. See README.md.
#   update-saxml-addon.sh --username=<account> [--host=<host>] [--export-account=<name> [--grant-privileges]] [--apply] <file>,<file>,...
# A <file> is a name on --host, or a full path or fmnet:// address. Separate files with commas.
# Without --apply it only does a dry run and changes nothing.
# --export-account names the account the pipeline calls the add-on with. The script then also plans that account's
# privileges in every file given, so list every file of the solution. --grant-privileges, with --apply, applies them.
# --credentials-from=<address> reads the keychain password stored for that file (spelled as --file is) for every
# target, so files that share the account need one stored password instead of one each.
#
# It compares each installed file with the source and, for what differs:
#   - creates missing fields
#   - replaces the layout's objects with the latest ones (the layout is not meant to be customized)
#   - creates missing scripts
#   - replaces the body of existing scripts in place (script ids and names stay, so references keep working)
# With --export-account it also plans, and with --grant-privileges sets, the export account's privilege set in each file:
#   - in a file with the add-on: View and Edit on SaXMLDelivery, its job fields, the two scripts, and records
#     modifiable on its layout
#   - in every file: View limited by False on each base table that table occurrences in the other files use, so the
#     SaXML keeps those table occurrences while the account sees no record
# It only ever adds access, and never deletes anything.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SOURCE=${SOURCE:-$HERE/../src/SaXMLDelivery.fmp12}
SOURCE_USER=${SOURCE_USER:-Admin}

USERNAME="" HOST="" APPLY=0 EXPORT="" GRANT=0 CREDS=() TARGETS=()
for a in "$@"; do
  case $a in
    --username=*) USERNAME=${a#*=} ;;
    --host=*) HOST=${a#*=} ;;
    --apply) APPLY=1 ;;
    --export-account=*) EXPORT=${a#*=} ;;
    --grant-privileges) GRANT=1 ;;
    --credentials-from=*) CREDS=("$a") ;;
    --*) echo "unknown option: $a" >&2; exit 64 ;;
    *) IFS=, read -ra parts <<< "$a"
       for p in "${parts[@]}"; do
         p=${p#"${p%%[![:space:]]*}"}; p=${p%"${p##*[![:space:]]}"}  # trim spaces around a name
         [ -n "$p" ] && TARGETS+=("$p")
       done ;;
  esac
done
[ -n "$USERNAME" ] && [ ${#TARGETS[@]} -gt 0 ] || { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
[ $GRANT -eq 0 ] || [ -n "$EXPORT" ] || { echo "--grant-privileges needs --export-account=<name>" >&2; exit 64; }
for t in "${TARGETS[@]}"; do
  [[ $t == */* || -n $HOST ]] || { echo "$t is a bare name; give --host=<host> or a full path" >&2; exit 64; }
done
command -v filemaker >/dev/null || { echo "the filemaker command (part of ADK) is not on PATH" >&2; exit 1; }
[ -f "$SOURCE" ] || { echo "missing $SOURCE" >&2; exit 1; }

TMP=$(mktemp -d)
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }  # bash 3.2 on macOS has no sub-second clock
START=$(now)
trap '[ -s "$TMP/timing.tsv" ] && H timing "$TMP/timing.tsv" "$(perl -e "printf q(%.3f), $(now) - $START")"; rm -rf "$TMP"' EXIT

# Helper for the JSON work. The six reads (3 scripts, the fields, the layout) are the same for the
# source and each target.
#   plan:   what each element needs, written as op files (creates, then script updates)
#   verify: the target now matches the source
#   errors: print the errors in an output file
cat > "$TMP/helper.py" <<'PY'
import json, sys

SCRIPTS = ["saxmlDelivery_createXml", "saxmlDelivery_readme", "saxmlDelivery_runPipeline", "saxmlDelivery_getVersion"]
TABLE = "SaXMLDelivery"
LAYOUT = "SaXMLDeliveryExecutionContext"

def lines(path):
    out = []
    for l in open(path, errors="replace"):
        try:
            out.append(json.loads(l))
        except ValueError:
            pass
    return out

def reads(path):
    """{'scripts': {name: describe|None}, 'fields': {name: describe}, 'layout': describe}. Raises on any other error."""
    fatal = [o for o in lines(path) if o.get("type") == "fatal"]
    if fatal:
        e = fatal[0]["error"]
        raise SystemExit("ERROR %s (dbError %s): %s" % (e.get("code"), e.get("dbError"), e.get("message", "")[:200]))
    ops = [o for o in lines(path) if "op" in o]
    if len(ops) != len(SCRIPTS) + 6:
        raise SystemExit("ERROR no read result (did the file open?)")
    ops, extra = ops[:len(SCRIPTS) + 3], ops[len(SCRIPTS) + 3:]
    res = {"scripts": {}}
    for name, o in zip(SCRIPTS, ops):
        if o["status"] == "ok":
            res["scripts"][name] = o["result"]
        elif o["error"].get("code") == "script_not_found":
            res["scripts"][name] = None
        else:
            raise SystemExit("ERROR %s: %s" % (o["error"].get("code"), o["error"].get("message", "")[:200]))
    f, l, p = ops[-3], ops[-2], ops[-1]
    res["fields"] = {i["name"]: i for i in f["result"]["items"]} if f["status"] == "ok" else {}
    res["layout"] = l["result"] if l["status"] == "ok" else None
    res["privsets"] = p["result"]["items"] if p["status"] == "ok" else []
    res["tos"], res["sources"], res["accounts"] = [o["result"]["items"] if o["status"] == "ok" else [] for o in extra]
    return res

def norm(body):
    def strip(x):
        if isinstance(x, dict):
            return {k: strip(v) for k, v in x.items() if k != "uuid"}
        if isinstance(x, list):
            return [strip(v) for v in x]
        return x
    return strip(body)

def within(a, b):
    """Every key a step has in the source is the same in the target; extra target keys are read-back defaults."""
    if isinstance(a, dict):
        return isinstance(b, dict) and all(k in b and within(v, b[k]) for k, v in a.items())
    if isinstance(a, list):
        return isinstance(b, list) and len(a) == len(b) and all(within(x, y) for x, y in zip(a, b))
    return a == b

def differing(src, tgt):
    a, b = norm(src), norm(tgt)
    return abs(len(a) - len(b)) + sum(1 for x, y in zip(a, b) if not within(x, y))

def script_version(s):
    for st in (s or {}).get("body", []):
        if st.get("name") == "$addonVersion":
            return st["value"].strip('"')
    return None

def version(r):
    """The version a file reports: saxmlDelivery_getVersion has it from 0.2.2 on, saxmlDelivery_createXml always did."""
    return (script_version(r["scripts"].get("saxmlDelivery_getVersion"))
            or script_version(r["scripts"].get("saxmlDelivery_createXml")) or "unknown")

def source_versions_agree(r):
    """The version is written in both saxmlDelivery_getVersion and saxmlDelivery_createXml; they must say the same."""
    a = script_version(r["scripts"].get("saxmlDelivery_getVersion"))
    b = script_version(r["scripts"].get("saxmlDelivery_createXml"))
    return a is not None and a == b, a, b

def missing_fields(src, tgt):
    return [n for n in src["fields"] if n not in tgt["fields"]]

def layout_flat(layout):
    """The layout's objects without ids, and its body height: what has to match the source."""
    def f(o):
        o = json.loads(json.dumps(o))
        o.pop("id", None); o.pop("accessibilityLabel", None)
        if o["type"] == "field":
            o["field"] = o["field"]["name"]
        if "objects" in o:
            o["objects"] = [f(x) for x in o["objects"]]
        return o
    return {"objects": [f(x) for x in layout["contents"]["objects"]], "bodyHeight": layout["parts"][0]["height"]}

def layout_ops(src, tgt):
    """Replaces the target layout's objects with the source's. Objects are not edited one by one because the
    layout moves between versions, and the add-on's layout is not meant to be customized. Nothing but the layout's
    objects and body height are touched."""
    def conv(o):
        o = json.loads(json.dumps(o))
        o.pop("container", None)  # read-only marker for groups
        o.pop("border", None); o.pop("textAlign", None)  # read-backs of localStyle, which is sent as is
        if o["type"] == "field":
            o["field"] = o["field"]["name"]
            o["label"] = ""  # the source has its own label objects; don't let each field add another
        if o["type"] == "webViewer":
            o.update(o.pop("webViewer"))
        if "objects" in o:
            o["objects"] = [conv(x) for x in o["objects"]]
        return o
    ops = []
    if layout_flat(src["layout"])["bodyHeight"] != layout_flat(tgt["layout"])["bodyHeight"]:
        # before the objects, so they are not squeezed into the old, shorter body
        ops.append({"op": "update:layout", "name": LAYOUT, "updateParts": [{"type": "body", "height": src["layout"]["parts"][0]["height"]}]})
    ops.append({"op": "update:layout", "name": LAYOUT,
                "removeObjects": [{"id": o["id"]} for o in tgt["layout"]["contents"]["objects"]],
                "addObjects": [conv(o) for o in src["layout"]["contents"]["objects"]]})
    return ops

def script_access(s, name):
    """A custom set's access to a script: its own entry, else the grant for scripts without one. None if the read has neither."""
    scripts = s.get("scripts", {})
    for e in scripts.get("scripts", []):
        if e.get("name") == name:
            return e.get("access")
    return scripts.get("newScripts", {}).get("access")

def privilege_sets_needing_grant(r):
    """Custom privilege sets that lack access to something the add-on added, each as 'name (what)'.
      fields: the set lists the table's fields one by one and gives no access to a job field. A set that grants all
              fields, or has no grant of its own for the table, covers new fields already.
      script: the set can run saxmlDelivery_createXml but not saxmlDelivery_getVersion. A set that grants all
              scripts, or gives new scripts access, covers it already."""
    out = []
    for s in r["privsets"]:
        if s.get("builtIn"):
            continue
        what = []
        for t in s.get("records", {}).get("tables", []):
            if t["name"] != TABLE or t.get("fields", {}).get("access") != "limited":
                continue
            granted = {f["name"] for f in t["fields"].get("fields", []) if f.get("access") != "noAccess"}
            if not {"jobStatus", "jobMessage"} <= granted:
                what.append("fields")
        runs_createxml = script_access(s, "saxmlDelivery_createXml") not in (None, "noAccess")
        if runs_createxml and script_access(s, "saxmlDelivery_getVersion") == "noAccess":
            what.append("script")
        if what:
            out.append("%s (%s)" % (s["name"], ", ".join(what)))
    return out

# --- Privileges of the export account (the account the pipeline calls the add-on with over the Data API) ---
# Built-in sets other than [Read-Only Access] grant everything the export needs.
VIEW_NOTE = ("SaXML export: tables with View limited by False are used by table occurrences in other files. "
             "Save a Copy as XML leaves out table occurrences whose table the account cannot access at all; "
             "limited by False keeps them in the export while showing no record. Don't set these tables to no access.")
JOB_FIELDS = {"xmlFile": "modifiable", "jobStatus": "viewOnly", "jobMessage": "viewOnly", "createTimestamp": "viewOnly"}

def table_grant(s, table):
    """A set's record access to a table: its own entry, else the grant for tables without one."""
    recs = s.get("records", {})
    for t in recs.get("tables", []):
        if t["name"] == table:
            return t
    return recs.get("newTables", {})

def layout_grant(s, name):
    lays = s.get("layouts", {})
    for l in lays.get("layouts", []):
        if l.get("name") == name:
            return l
    return lays.get("newLayouts", {})

def file_label(path):
    """FileA from fmnet://host/FileA, /a/b/FileA.fmp12, file:FileA.fmp12 or fmnet:/host/FileA."""
    base = path.split(":", 1)[-1].rstrip("/").split("/")[-1]
    return base[:-6] if base.lower().endswith(".fmp12") else base

def export_set(r, account):
    """(privilege set describe, None) or (None, problem)."""
    acct = next((a for a in r["accounts"] if a["name"].lower() == account.lower()), None)
    if acct is None:
        return None, "account %s does not exist in this file" % account
    s = next((p for p in r["privsets"] if p["name"] == acct["privilegeSet"]), None)
    if s is None:
        return None, "cannot read privilege set %s" % acct["privilegeSet"]
    return s, None

def addon_grants(r, s):
    """What the export account needs in a file that has the add-on, as (records tables, scripts, layouts, notes)."""
    tables, scripts, layouts, notes = [], [], [], []
    if s.get("builtIn"):
        if s["name"] == "[Read-Only Access]":
            notes.append("set [Read-Only Access] cannot clear xmlFile after the download; give the account a custom set")
        return tables, scripts, layouts, notes
    g = table_grant(s, TABLE)
    entry = {}
    if g.get("view") != "yes" or g.get("edit") != "yes":
        entry.update({"view": "yes", "edit": "yes"})
    f = g.get("fields", {})
    if f.get("access") != "all":
        have = {x["name"]: x.get("access") for x in f.get("fields", [])}
        rank = {"noAccess": 0, "viewOnly": 1, "modifiable": 2}
        add = [{"name": n, "access": a} for n, a in JOB_FIELDS.items()
               if rank.get(have.get(n, f.get("newFields", {}).get("access", "noAccess")), 0) < rank[a]]
        if add:
            entry["fields"] = {"fields": add}
    if entry:
        entry["name"] = TABLE
        tables.append(entry)
    for n in ("saxmlDelivery_createXml", "saxmlDelivery_getVersion"):
        if r["scripts"].get(n) is not None and script_access(s, n) in (None, "noAccess"):
            scripts.append({"name": n, "access": "executableOnly"})
    l = layout_grant(s, LAYOUT)
    if l.get("access") in (None, "noAccess") or l.get("records") != "modifiable":
        layouts.append({"name": LAYOUT, "access": l["access"] if l.get("access") not in (None, "noAccess") else "viewOnly",
                        "records": "modifiable"})
    if "fmrest" not in s.get("extendedPrivileges", []):
        notes.append("set %s lacks the fmrest extended privilege; add it by hand if the Data API account uses it" % s["name"])
    return tables, scripts, layouts, notes

def cross_file_needs(files):
    """{label: {table: [referring 'File::TO', ...]}} for base tables that other files' TOs use, plus warnings."""
    labels = {l.lower(): l for l in files}
    needs, warns = {}, []
    for a, r in files.items():
        paths = {d["name"]: d.get("paths", []) for d in r["sources"]}
        for to in r["tos"]:
            t = to.get("table", {})
            ds = t.get("dataSource")
            if not ds or ds not in paths:
                continue  # local, or ODBC
            b = next((labels[file_label(p).lower()] for p in paths[ds] if file_label(p).lower() in labels), None)
            if b is None:
                warns.append("%s::%s uses data source %s (%s), which is not in this run; add that file" % (a, to["name"], ds, ", ".join(paths[ds])))
            elif not t.get("resolved") or "name" not in t:
                warns.append("%s::%s: its base table in %s could not be resolved" % (a, to["name"], b))
            else:
                needs.setdefault(b, {}).setdefault(t["name"], []).append("%s::%s" % (a, to["name"]))
    return needs, warns

def privilege_plan(files, account):
    """{label: (update:privilegeSet op or None, [plan lines])} for the export account in every file."""
    needs, warns = cross_file_needs(files)
    out = {}
    for label, r in files.items():
        say = []
        s, problem = export_set(r, account)
        if problem:
            out[label] = (None, ["  PROBLEM " + problem])
            continue
        installed = any(v is not None for v in r["scripts"].values())
        tables, scripts, layouts, notes = addon_grants(r, s) if installed else ([], [], [], [])
        named = {t["name"] for t in tables}
        for table, refs in sorted(needs.get(label, {}).items()):
            if s.get("builtIn") or table_grant(s, table).get("view") in ("yes", "limited") or table in named:
                continue
            to = next((o["name"] for o in r["tos"] if not o.get("table", {}).get("dataSource") and o.get("table", {}).get("name") == table), None)
            if to is None:
                notes.append("no table occurrence of %s in this file to write the View calculation against; add one" % table)
                continue
            tables.append({"name": table, "view": "limited", "viewCalculation": {"tableOccurrence": to, "text": "False"},
                           "edit": "no", "create": "no", "delete": "no", "fields": {"access": "none"}})
            say.append("  table %-26s View limited by False (used by %s%s)" % (table, ", ".join(refs[:3]), ", ..." if len(refs) > 3 else ""))
        for t in tables:
            if t["name"] == TABLE:
                say.append("  table %-26s %s" % (TABLE, ", ".join(filter(None, [
                    "View and Edit yes" if "view" in t else "",
                    "fields " + ", ".join("%s %s" % (f["name"], f["access"]) for f in t.get("fields", {}).get("fields", [])) if "fields" in t else ""]))))
        for x in scripts:
            say.append("  script %-25s executable only" % x["name"])
        for x in layouts:
            say.append("  layout %-25s %s, records modifiable" % (x["name"], x["access"]))
        op = None
        if tables or scripts or layouts:
            op = {"op": "update:privilegeSet", "name": s["name"]}
            desc = s.get("description") or ""
            if any(t.get("viewCalculation", {}).get("text") == "False" for t in tables) and VIEW_NOTE not in desc:
                op["description"] = (desc.rstrip() + ("" if desc.rstrip()[-1:] in ".!?" else ".") + " " if desc.strip() else "") + VIEW_NOTE
                say.append("  description: adds a note on why some tables have View limited by False")
            if tables: op["records"] = {"tables": tables}
            if scripts: op["scripts"] = {"scripts": scripts}
            if layouts: op["layouts"] = {"layouts": layouts}
            say.insert(0, "  privilege set %s (account %s):" % (s["name"], account))
        else:
            say.insert(0, "  privilege set %s (account %s): nothing needed" % (s["name"], account))
        out[label] = (op, say + ["  NOTE " + n for n in notes])
    return out, warns

def plan(src, tgt, say=print):
    """The creates and the script updates that bring tgt up to the source, printing a line per element."""
    if all(v is None for v in tgt["scripts"].values()) and not tgt["fields"]:
        say("NOT-INSTALLED")
        sys.exit(2)
    if tgt["layout"] is None:
        print("ERROR the layout %s is missing; reinstall the add-on" % LAYOUT, file=sys.stderr)
        sys.exit(3)
    creates, updates = [], []
    say("  installed version %s, latest %s" % (version(tgt), version(src)))
    for n in missing_fields(src, tgt):
        f = src["fields"][n]
        op = {"op": "create:field", "table": TABLE, "name": n, "type": f["type"]}
        for k in ("fieldType", "comment", "calculation", "options"):
            if k in f:
                op[k] = f[k]
        creates.append(op)
        say("  field %-24s CREATE" % n)
    if layout_flat(src["layout"]) != layout_flat(tgt["layout"]):
        creates += layout_ops(src, tgt)
        say("  layout %-26s REPLACE OBJECTS" % LAYOUT)
    else:
        say("  layout %-26s unchanged" % LAYOUT)
    for n in SCRIPTS:
        s, t = src["scripts"][n], tgt["scripts"][n]
        if t is None:
            creates.append({"op": "create:script", "name": n, "folder": s["folder"], "hidden": s["hidden"],
                            "runWithFullAccess": s["runWithFullAccess"], "body": s["body"]})
            say("  script %-26s CREATE (%d steps)" % (n, s["steps"]))
        else:
            d = differing(s["body"], t["body"])
            if d == 0:
                say("  script %-26s unchanged" % n)
            else:
                updates.append({"op": "update:script", "name": n, "token": t["token"], "body": s["body"]})
                say("  script %-26s UPDATE (%d -> %d steps, %d differ)" % (n, t["steps"], s["steps"], d))
    return creates, updates

cmd = sys.argv[1]
if cmd == "version":
    print(version(reads(sys.argv[2])))
elif cmd == "plan":
    creates, updates = plan(reads(sys.argv[2]), reads(sys.argv[3]))
    open(sys.argv[4], "w").write("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in creates))
    open(sys.argv[5], "w").write("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in updates))
    print("NOTHING-TO-DO" if not creates and not updates else "CHANGES")
elif cmd == "session":
    # session <source.txt> <read.ndjson> <creates> <updates> <privileges> <out> <filemaker args...>
    # Applies the creates, the script updates and the privilege grants in one filemaker run, so the file is opened
    # once and the whole update commits or rolls back as one batch. filemaker answers each op as it arrives on
    # stdin, so after the creates the file is read again in the same run: creating invalidates the update ops'
    # tokens, and the updates are planned again from that read.
    import subprocess
    src = reads(sys.argv[2])
    read_ops = [l for l in open(sys.argv[3]) if l.strip()]
    creates = [l for l in open(sys.argv[4]) if l.strip()]
    updates = [l for l in open(sys.argv[5]) if l.strip()]
    grants = [l for l in open(sys.argv[6]) if l.strip()]
    sys.argv[6:7] = []
    out = open(sys.argv[6], "w")
    err = open(sys.argv[6] + ".err", "w+")  # a file, not a pipe, so a full stderr pipe cannot stall the run
    p = subprocess.Popen(["filemaker"] + sys.argv[7:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=err, text=True, bufsize=1)
    def send(ops):
        """Sends ops one by one and returns their results; stops at the first error or if filemaker ends."""
        res = []
        for op in ops:
            p.stdin.write(op if op.endswith("\n") else op + "\n"); p.stdin.flush()
            line = p.stdout.readline()
            if not line:
                return res, False
            out.write(line)
            res.append(line)
            if json.loads(line).get("status") == "error":
                return res, False
        return res, True
    ok = True
    if creates:
        _, ok = send(creates)
        if ok:
            res, ok = send(read_ops)
            if ok:
                open(sys.argv[6] + ".read", "w").write("".join(res))
                _, updates = plan(src, reads(sys.argv[6] + ".read"), say=lambda *a: None)
                updates = [json.dumps(o, ensure_ascii=False) for o in updates]
    if ok and updates:
        _, ok = send(updates)
    if ok and grants:
        _, ok = send(grants)
    p.stdin.close()
    out.write(p.stdout.read())
    rc = p.wait()
    err.seek(0); out.write(err.read())
    sys.exit(rc or (0 if ok else 1))
elif cmd == "verify":
    src, tgt = reads(sys.argv[2]), reads(sys.argv[3])
    bad = [n for n in SCRIPTS if tgt["scripts"][n] is None or differing(src["scripts"][n]["body"], tgt["scripts"][n]["body"])]
    bad += ["field " + n for n in missing_fields(src, tgt)]
    bad += ["layout"] if layout_flat(src["layout"]) != layout_flat(tgt["layout"]) else []
    print("MISMATCH " + ", ".join(bad) if bad else "OK")
    sys.exit(1 if bad else 0)
elif cmd == "checksource":
    ok, a, b = source_versions_agree(reads(sys.argv[2]))
    if not ok:
        print("saxmlDelivery_getVersion says %s but saxmlDelivery_createXml says %s; fix the source file first" % (a, b))
        sys.exit(1)
elif cmd == "privplan":
    # privplan <account> <list.tsv>: rows of index, label, read file. Writes p<index>.ndjson next to each read,
    # prints the plan per file, and exits 1 when any file still needs a grant (used to verify after the apply).
    rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[3]) if l.strip()]
    files = {lab: reads(path) for _, lab, path in rows}
    plans, warns = privilege_plan(files, sys.argv[2])
    pending = False
    for i, lab, path in rows:
        op, say = plans[lab]
        print(lab)
        print("\n".join(say))
        pending |= op is not None
        open(path.rsplit("/", 1)[0] + "/p%s.ndjson" % i, "w").write(json.dumps(op, ensure_ascii=False) + "\n" if op else "")
    for w in warns:
        print("  WARNING " + w)
    sys.exit(10 if pending else 0)
elif cmd == "privneeds":
    print(", ".join(privilege_sets_needing_grant(reads(sys.argv[2]))))
elif cmd == "errors":
    for o in lines(sys.argv[2]):
        if o.get("status") == "error" or o.get("type") == "fatal":
            e = o["error"]
            print("    %s (dbError %s): %s" % (e.get("code"), e.get("dbError", "-"), e.get("message", "")[:240]))
elif cmd == "openreason":
    reasons = {212: "login failed", 714: "account is not [Full Access]", 802: "no file by that name",
               803: "host not found or file in use", 303: "schema is locked by another session"}
    for o in lines(sys.argv[2]):
        if o.get("status") == "error" or o.get("type") == "fatal":
            print(reasons.get(o["error"].get("dbError"), o["error"].get("code") or "unknown error"))
            break
    else:
        print("unknown error")
elif cmd == "timing":
    # timing.tsv rows: kind, file, ops, seconds. One row per filemaker call; each call opens and closes the file.
    rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2]) if l.strip()]
    wall = float(sys.argv[3])
    order = [("source", "source read", False), ("read", "read", False),
             ("dryrun", "dry run", False), ("apply", "apply", True)]
    print("\n== Timing (seconds, wall clock per filemaker call, including opening and closing the file)")
    print("  %-14s %6s %6s %9s %9s" % ("call", "calls", "ops", "total", "avg/call"))
    groups = {False: 0.0, True: 0.0}
    for kind, label, writes in order:
        rs = [r for r in rows if r[0] == kind]
        if not rs:
            continue
        secs = sum(float(r[3]) for r in rs)
        groups[writes] += secs
        print("  %-14s %6d %6d %9.1f %9.1f" % (label, len(rs), sum(int(r[2]) for r in rs), secs, secs / len(rs)))
    cli = groups[False] + groups[True]
    print("  no changes (source read, read, dry run): %.1f" % groups[False])
    print("  changes (apply): %.1f" % groups[True])
    print("  filemaker total: %.1f of %.1f; the rest (%.1f) is outside the filemaker command" % (cli, wall, wall - cli))
    files = []
    for r in rows:
        if r[0] != "source" and r[1] not in files:
            files.append(r[1])
    if files:
        print("  per file:")
        for f in files:
            rs = [r for r in rows if r[1] == f]
            print("    %-30s %3d calls %9.1f" % (f, len(rs), sum(float(r[3]) for r in rs)))
PY

H() { python3 -I "$TMP/helper.py" "$@"; }
timed() { # timed <kind> <file> <ndjson> <command...>: runs the command and logs its time to timing.tsv
  local kind=$1 f=$2 ops=$3 t0 n=0; shift 3
  [ "$ops" = /dev/null ] || n=$(grep -c . "$ops")
  t0=$(now); "$@"; local rc=$?
  printf '%s\t%s\t%s\t%s\n' "$kind" "${f##*/}" "$n" "$(perl -e "printf q(%.3f), $(now) - $t0")" >> "$TMP/timing.tsv"
  return $rc
}
run() { # run <file> <ndjson> [--dry-run] -> output in $TMP/out.txt
  local f=$1 ops=$2 kind; shift 2
  kind=read
  timed "$kind" "$f" "$ops" filemaker "--file=$f" "--username=$USERNAME" --keychain ${CREDS[@]+"${CREDS[@]}"} --prompt "$@" "$ops" > "$TMP/out.txt" 2>&1
}
session() { # session <i> <file> [--dry-run]: the creates, updates and grants for file i in one filemaker run -> $TMP/out.txt
  local i=$1 f=$2 kind=apply; shift 2
  [ "${1:-}" = --dry-run ] && kind=dryrun
  cat "$TMP/c$i.ndjson" "$TMP/u$i.ndjson" "$TMP/p$i.ndjson" > "$TMP/cu$i.ndjson"  # only to count the ops for the timing
  timed "$kind" "$f" "$TMP/cu$i.ndjson" H session "$TMP/source.txt" "$TMP/read.ndjson" "$TMP/c$i.ndjson" "$TMP/u$i.ndjson" "$TMP/p$i.ndjson" "$TMP/out.txt" \
    "--file=$f" "--username=$USERNAME" --keychain ${CREDS[@]+"${CREDS[@]}"} --prompt "$@"
}
hosted() { # a bare name goes to --host, without .fmp12; a path or fmnet:// address is used as given
  if [[ $1 != */* ]]; then
    [ -n "$HOST" ] || { echo "no --host given for $1" >&2; exit 64; }
    echo "fmnet://$HOST/${1%.fmp12}"
  else echo "$1"; fi
}

cat > "$TMP/read.ndjson" <<'E'
{"op":"read:script","name":"saxmlDelivery_createXml"}
{"op":"read:script","name":"saxmlDelivery_readme"}
{"op":"read:script","name":"saxmlDelivery_runPipeline"}
{"op":"read:script","name":"saxmlDelivery_getVersion"}
{"op":"read:field","table":"SaXMLDelivery","detail":true}
{"op":"read:layout","name":"SaXMLDeliveryExecutionContext","detail":true}
{"op":"read:privilegeSet","detail":true}
{"op":"read:tableOccurrence"}
{"op":"read:externalDataSource","detail":true}
{"op":"read:account","detail":true}
E

echo "Reading the latest definitions from $(basename "$SOURCE")"
timed source "$SOURCE" "$TMP/read.ndjson" filemaker "--file=$SOURCE" "--username=$SOURCE_USER" "$TMP/read.ndjson" > "$TMP/source.txt" 2>&1
H plan "$TMP/source.txt" "$TMP/source.txt" /dev/null /dev/null >/dev/null 2>"$TMP/err.txt" \
  || { echo "could not read the source file: $(cat "$TMP/err.txt")" >&2; exit 1; }
H checksource "$TMP/source.txt" || exit 1
echo "Latest version: $(H version "$TMP/source.txt")"

declare -a OK_TARGETS=() REPORT=() REACHABLE=() UPDATED=() NEEDS=() PRE023=() PSKIP=()

# 0.2.3 changed no schema; it marks files whose pipeline account may lack record access in other files.
below_023() { [ -n "$1" ] && [ "$1" != 0.2.3 ] && [ "$(printf '%s\n' "$1" 0.2.3 | sort -V | head -1)" = "$1" ]; }
multifile_note() {
  [ ${#PRE023[@]} -gt 0 ] || return 0
  echo; echo "Check the pipeline account's record access in ${PRE023[*]} and every file their solution uses (see \"Multi-file solutions\" in README.md):"
  echo "  FileMaker opens other files with that account's own privilege set, even though the export runs with full access. Where it cannot"
  echo "  access a base table's records, the SaXML silently leaves out every table occurrence in other files based on that table. View limited by False fixes it without showing any record."
  echo "  Run again with every file of the solution and --export-account=<the pipeline's account> to check and set it."
}

# Phase 0: read every file, which also asks for every password up front. FileMaker offers to keep
# the password in the keychain, so the later phases need no prompts as long as you accept that offer.
echo; echo "== Passwords"
echo "If a password window appears, enter the password there."
for t in "${TARGETS[@]}"; do
  f=$(hosted "$t")
  echo "$t"
  run "$f" "$TMP/read.ndjson"
  if grep -q '"type":"summary"' "$TMP/out.txt" && ! grep -q '"type":"fatal"' "$TMP/out.txt"; then
    REACHABLE+=("$t"); cp "$TMP/out.txt" "$TMP/r${#REACHABLE[@]}.txt"
  else
    echo "  cannot open it, so it will be skipped:"; H errors "$TMP/out.txt"
    REPORT+=("$t: skipped (could not open: $(H openreason "$TMP/out.txt"))")
  fi
done
[ ${#REACHABLE[@]} -gt 0 ] || { echo; echo "No file could be opened."; printf '  %s\n' "${REPORT[@]}"; exit 1; }
if [ $APPLY -eq 1 ]; then echo; echo "== Plan (--apply: the update follows straight away)"; else echo; echo "== Dry run"; fi

label() { local n=${1##*/}; echo "${n%.fmp12}"; }
plist() { # plist <tsv> [<verify read prefix>]: index, file name, read file for every reachable file
  local i=0 t r; : > "$1"
  for t in "${REACHABLE[@]}"; do
    i=$((i+1)); r="$TMP/r$i.txt"; [ -n "${2:-}" ] && [ -f "$TMP/$2$i.txt" ] && r="$TMP/$2$i.txt"
    printf '%s\t%s\t%s\n' "$i" "$(label "$(hosted "$t")")" "$r" >> "$1"
  done
}

# Privileges: planned across all files at once, because a file needs access for the table occurrences of the others.
i=0; for t in "${REACHABLE[@]}"; do i=$((i+1)); : > "$TMP/p$i.ndjson"; done
if [ -n "$EXPORT" ]; then
  echo; echo "== Privileges of the export account $EXPORT"
  plist "$TMP/files.tsv"
  H privplan "$EXPORT" "$TMP/files.tsv"
  rc=$?; [ $rc -eq 0 ] || [ $rc -eq 10 ] || { echo "could not plan the privileges" >&2; exit 1; }
fi
if [ $APPLY -eq 1 ]; then echo; echo "== Plan (--apply: the update follows straight away)"; else echo; echo "== Dry run"; fi

# Phase 1: plan every file from its read. A dry run also asks the file to check the ops without writing.
i=0
for t in "${REACHABLE[@]}"; do
  i=$((i+1)); f=$(hosted "$t"); installed=1; schema=0
  echo "$t  ($f)"
  : > "$TMP/c$i.ndjson"; : > "$TMP/u$i.ndjson"
  if H plan "$TMP/source.txt" "$TMP/r$i.txt" "$TMP/c$i.ndjson" "$TMP/u$i.ndjson" > "$TMP/plan.txt" 2>"$TMP/err.txt"; then
    grep -v -E '^(CHANGES|NOTHING-TO-DO)$' "$TMP/plan.txt"
    if grep -q CHANGES "$TMP/plan.txt"; then schema=1; below_023 "$(H version "$TMP/r$i.txt" 2>/dev/null)" && PRE023+=("$t"); fi
  elif grep -q NOT-INSTALLED "$TMP/plan.txt"; then
    installed=0; echo "  the add-on is not installed in this file"
  else
    echo "  failed: $(cat "$TMP/err.txt")"; REPORT+=("$t: failed ($(cat "$TMP/err.txt"))"); continue
  fi
  if [ -s "$TMP/p$i.ndjson" ]; then
    echo "  privilege grants planned (see above)"
    if [ $APPLY -eq 1 ] && [ $GRANT -eq 0 ]; then PSKIP+=("$t"); : > "$TMP/p$i.ndjson"; fi
  fi
  if [ $schema -eq 0 ] && [ ! -s "$TMP/p$i.ndjson" ]; then
    if [ $installed -eq 1 ]; then REPORT+=("$t: already up to date"); else REPORT+=("$t: add-on not installed, nothing to grant"); fi
    continue
  fi
  if [ $APPLY -eq 0 ]; then
    session "$i" "$f" --dry-run
    if ! grep -q '"errors":0' "$TMP/out.txt"; then echo "  dry run refused:"; H errors "$TMP/out.txt"; REPORT+=("$t: failed dry run"); continue; fi
    REPORT+=("$t: would be updated")
  fi
  OK_TARGETS+=("$i|$t|$f|$installed")
done

skipped_note() {
  [ ${#PSKIP[@]} -gt 0 ] || return 0
  echo; echo "Privilege grants were planned but not applied in ${PSKIP[*]}. Rerun with --grant-privileges to apply them."
}

if [ ${#OK_TARGETS[@]} -eq 0 ]; then
  echo; echo "Nothing to apply."; printf '  %s\n' "${REPORT[@]}"; skipped_note; exit 0
fi

if [ $APPLY -eq 0 ]; then
  echo; echo "== Summary (dry run)"; printf '  %s\n' "${REPORT[@]}"
  [ -n "$EXPORT" ] || multifile_note
  echo; echo "Dry run only: nothing was changed. Back the files up, close Manage Database and the script editor in each, then run again with --apply${EXPORT:+ (and --grant-privileges for the privilege grants)} to update ${#OK_TARGETS[@]} file(s)."
  exit 0
fi

# Phase 2: apply each file in one run (creates, a fresh read, script updates, grants), then verify from a new read.
echo; echo "== Apply"
for entry in "${OK_TARGETS[@]}"; do
  IFS='|' read -r i t f installed <<< "$entry"
  echo "$t"
  failed=0
  session "$i" "$f"
  grep -q '"errors":0' "$TMP/out.txt" && grep -q '"rolledBack":false' "$TMP/out.txt" || { failed=1; H errors "$TMP/out.txt"; }
  if [ $failed -eq 0 ]; then
    run "$f" "$TMP/read.ndjson"; cp "$TMP/out.txt" "$TMP/v$i.txt"
    if [ "$installed" = 0 ]; then
      echo "  privileges applied"; REPORT+=("$t: privileges applied"); UPDATED+=("$t")
    elif v=$(H verify "$TMP/source.txt" "$TMP/out.txt" 2>&1); then
      echo "  updated and verified"; REPORT+=("$t: updated and verified"); UPDATED+=("$t")
      sets=$(H privneeds "$TMP/out.txt" 2>/dev/null)
      if [ -n "$sets" ]; then NEEDS+=("$t ($sets)"); fi
    else
      echo "  verify failed: $v"; REPORT+=("$t: applied but verify failed ($v)")
    fi
  else
    echo "  failed (see above); this file may need a rerun. A lock error (303, 3313, 3315) means someone has Manage Database or the script editor open."
    REPORT+=("$t: failed")
  fi
done

echo; echo "== Summary"; printf '  %s\n' "${REPORT[@]}"
if [ -n "$EXPORT" ] && [ $GRANT -eq 1 ]; then
  echo; echo "== Privileges after the update"
  plist "$TMP/files2.tsv" v
  if H privplan "$EXPORT" "$TMP/files2.tsv" > "$TMP/pcheck.txt"; then
    echo "  verified: the export account has everything it needs in every file"
  else
    grep -E 'PROBLEM|NOTE|WARNING|^  (table|script|layout|privilege set .*:$)' "$TMP/pcheck.txt" | grep -v 'nothing needed' | sed 's/^/  still missing: /'
  fi
elif [ ${#NEEDS[@]} -gt 0 ]; then
  echo; echo "These files have privilege sets that lack access to something the add-on added. fields: no access to jobStatus or jobMessage. script: cannot execute saxmlDelivery_getVersion."
  printf '  %s\n' "${NEEDS[@]}"
  echo "If the Data API account uses one of them, rerun with every file of the solution, --export-account=<that account> and --grant-privileges."
fi
skipped_note
[ -n "$EXPORT" ] || multifile_note
