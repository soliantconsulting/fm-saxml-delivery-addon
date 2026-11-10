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
#
# Hosted files are processed at the same time, each in one filemaker session from the first read to the commit.
# Local files are processed one at a time, because a session locks the files its data sources point to.
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
             "Save a Copy as XML leaves out table occurrences whose table the account cannot access at all, and writes "
             "fields it cannot access as <No Access> in calculations. View limited by False with field access on keeps "
             "both in the export while showing no record. Don't set these tables, or their fields, to no access.")
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
            g = table_grant(s, table)
            if s.get("builtIn") or table in named:
                continue
            if g.get("view") == "limited" and g.get("viewCalculation", {}).get("text", "").strip() == "False" \
                    and g.get("fields", {}).get("access") != "all":
                # no record passes False, so field access all exposes nothing; 0.2.4 wrote none here
                tables.append({"name": table, "fields": {"access": "all"}})
                say.append("  table %-26s field access all (View is limited by False; field access none breaks calculation text)" % table)
                continue
            if g.get("view") in ("yes", "limited"):
                if g.get("fields", {}).get("access") != "all":
                    # Changing this would widen what the account reads (View yes) or need a judgment call, so say it.
                    notes.append("%s: field access is %s, so other files' calculations show its fields as <No Access> in the SaXML; "
                                 "give the export account field access all on it" % (table, g.get("fields", {}).get("access", "none")))
                continue
            to = next((o["name"] for o in r["tos"] if not o.get("table", {}).get("dataSource") and o.get("table", {}).get("name") == table), None)
            if to is None:
                notes.append("no table occurrence of %s in this file to write the View calculation against; add one" % table)
                continue
            tables.append({"name": table, "view": "limited", "viewCalculation": {"tableOccurrence": to, "text": "False"},
                           "edit": "no", "create": "no", "delete": "no", "fields": {"access": "all"}})
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
elif cmd == "checksource":
    ok, a, b = source_versions_agree(reads(sys.argv[2]))
    if not ok:
        print("saxmlDelivery_getVersion says %s but saxmlDelivery_createXml says %s; fix the source file first" % (a, b))
        sys.exit(1)
elif cmd == "multi":
    # multi <source.txt> <read.ndjson> <tmpdir> <apply 0|1> <grant 0|1> <export account or ""> -- <label|address>... -- <filemaker args>
    # Each file gets ONE filemaker session, and all files run at once. A session reads its file, waits until every file
    # has been read (the privilege plan needs all of them), sends its creates, updates and grants, reads the file again
    # in the same session (reads see the uncommitted writes) to verify, and commits when its input closes. Under --apply
    # nothing is committed until every file has been verified; a file that fails rolls back on its own.
    import subprocess, threading, time
    from concurrent.futures import ThreadPoolExecutor
    src_path, read_path, tmp, apply_, grant, export = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1", sys.argv[6] == "1", sys.argv[7]
    rest = sys.argv[8:]
    i1 = rest.index("--"); i2 = rest.index("--", i1 + 1)
    targets = [t.split("|", 1) for t in rest[i1 + 1:i2]]
    fm_args = rest[i2 + 1:]
    src = reads(src_path)
    read_ops = [l.rstrip("\n") for l in open(read_path) if l.strip()]
    timing = open(tmp + "/timing.tsv", "a")
    REASONS = {212: "login failed", 714: "account is not [Full Access]", 802: "no file by that name",
               803: "host not found or file in use", 303: "schema is locked by another session"}

    class Session:
        def __init__(self, label, address):
            self.label, self.address, self.out = label, address, []
            self.start()
        def start(self):
            self.raw, self.ok, self.ops = [], True, 0
            self.t0 = time.time()
            self.err = open("%s/%s.err" % (tmp, self.label), "w+")
            self.p = subprocess.Popen(["filemaker", "--file=" + self.address, "--timeout=0"] + fm_args + (["--dry-run"] if not apply_ else []),
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err, text=True, bufsize=1)
        def say(self, s=""):
            self.out.append(s)
        def send(self, ops, reads_only=False):
            """Results of ops sent one by one; stops at the first error, or when filemaker ends (self.ok False).
            With reads_only an error result (a script the file lacks) is an answer, not a failure."""
            res = []
            for op in ops:
                if not self.ok:
                    break
                try:
                    self.p.stdin.write((op if isinstance(op, str) else json.dumps(op, ensure_ascii=False)) + "\n"); self.p.stdin.flush()
                except BrokenPipeError:
                    self.ok = False; break
                self.ops += 1
                while True:
                    line = self.p.stdout.readline()
                    if not line:
                        self.ok = False; break
                    self.raw.append(line)
                    try:
                        o = json.loads(line)
                    except ValueError:
                        continue
                    if o.get("type") == "fatal":
                        self.ok = False; break
                    if "op" in o:
                        res.append(line)
                        if o.get("status") == "error" and not reads_only:
                            self.ok = False
                        break
            return res
        def close(self, kind=None):
            try:
                self.p.stdin.close()
            except BrokenPipeError:
                pass
            self.raw += self.p.stdout.readlines()
            self.p.wait()
            self.err.seek(0)
            self.raw += self.err.readlines()  # the summary, fatal errors and credential records go to stderr
            timing.write("%s\t%s\t%d\t%.3f\n" % (kind or ("apply" if apply_ else "dryrun"), self.label, self.ops, time.time() - self.t0)); timing.flush()
            summ = [json.loads(l) for l in self.raw if l.startswith('{"type":"summary"')]
            return bool(summ) and summ[-1].get("errors") == 0 and not summ[-1].get("rolledBack")
        def errors(self):
            for l in self.raw:
                try:
                    o = json.loads(l)
                except ValueError:
                    continue
                if o.get("status") == "error" or o.get("type") == "fatal":
                    e = o["error"]
                    yield "    %s (dbError %s): %s" % (e.get("code"), e.get("dbError", "-"), e.get("message", "")[:240])
        def reason(self):
            for l in self.raw:
                try:
                    o = json.loads(l)
                except ValueError:
                    continue
                if o.get("status") == "error" or o.get("type") == "fatal":
                    return REASONS.get(o["error"].get("dbError"), o["error"].get("code") or "unknown error")
            return "unknown error"

    def below(v, ref):
        try:
            return tuple(int(x) for x in v.split(".")) < tuple(int(x) for x in ref.split("."))
        except (AttributeError, ValueError):
            return False

    # Hosted files run at the same time, each held open from the first read to the commit. Local files can't: a
    # session opens the files its data sources point to, which locks them for the others. So local files run one
    # at a time, opened once to read and once to write.
    hold = all(addr.startswith("fmnet://") for _, addr in targets)
    sessions = []
    if hold:
        for n, (lab, addr) in enumerate(targets):
            if n:
                time.sleep(1.5)  # starting many filemaker processes at the same instant can fail to start the network stack
            sessions.append(Session(lab, addr))
    reads_of = {}
    def open_error(s):
        for l in s.raw:
            try:
                o = json.loads(l)
            except ValueError:
                continue
            if o.get("type") == "fatal":
                return o["error"].get("dbError") or o["error"].get("code")
        return None
    def first_read(s):
        # Opening several files at once sometimes fails for no lasting reason: FileMaker Server answers 802 (no such
        # file), or the local network stack does not start (network_init_failed). Retry those; a refused login is not.
        for attempt in range(4):
            lines = s.send(read_ops, reads_only=True)
            if s.ok or attempt == 3:
                break
            s.close("read")
            if open_error(s) not in (802, "network_init_failed"):
                s.closed = True
                break
            time.sleep(2 + 3 * attempt)
            s.start()
        s.first = lines
        s.bad = {i for i, l in enumerate(lines) if json.loads(l).get("status") == "error"}
        if s.ok and len(lines) == len(read_ops):
            path = "%s/%s.r.txt" % (tmp, s.label)
            open(path, "w").write("".join(lines))
            try:
                reads_of[s.label] = reads(path)
            except SystemExit as e:
                s.ok = False; s.fail = str(e)
        else:
            s.ok = False
    print("\n== Reading %d file(s)%s" % (len(targets), " at once" if hold else ""))
    print("If a password window appears, enter the password there.")
    if hold:
        with ThreadPoolExecutor(max_workers=len(sessions) or 1) as ex:
            list(ex.map(first_read, sessions))
    else:
        for lab, addr in targets:
            s = Session(lab, addr); sessions.append(s)
            first_read(s)
            if not getattr(s, "closed", False):
                s.close("read")
            s.closed = True
    report, pre023, pskip, needs_sets = [], [], [], []
    live = []
    for s in sessions:
        if s.label in reads_of:
            live.append(s)
        else:
            if not getattr(s, "closed", False):
                s.close("read")
            print("%s: cannot open it, so it will be skipped:" % s.label)
            for e in s.errors():
                print(e)
            report.append("%s: skipped (could not open: %s)" % (s.label, s.reason()))
    if not live:
        print("\nNo file could be opened.")
        print("\n".join("  " + r for r in report))
        sys.exit(1)

    grants = {s.label: None for s in live}
    if export:
        print("\n== Privileges of the export account %s" % export)
        plans, warns = privilege_plan({s.label: reads_of[s.label] for s in live}, export)
        for s in live:
            op, say = plans[s.label]
            print(s.label); print("\n".join(say))
            grants[s.label] = op
        for w in warns:
            print("  WARNING " + w)
    print("\n== Plan (--apply: the update follows straight away)" if apply_ else "\n== Dry run")

    def reread(s, created):
        """Reads the file again in its session. Skips the reads that failed the first time (a script the file lacks,
        the add-on's table in a file without the add-on), because under --abort-on-error any error result rolls the
        whole session back, and puts the first answers in their place. A script just created is read again."""
        names = {c["name"] for c in created if c.get("op") == "create:script"}
        send = [i for i in range(len(read_ops)) if i not in s.bad or (i < len(SCRIPTS) and SCRIPTS[i] in names)]
        got = s.send([read_ops[i] for i in send], reads_only=True)
        if not s.ok or len(got) != len(send):
            s.ok = False
            return None
        lines = list(s.first)
        for i, l in zip(send, got):
            lines[i] = l
        path = "%s/%s.%d.txt" % (tmp, s.label, len(s.raw)); open(path, "w").write("".join(lines))
        return reads(path)

    def work(s):
        """Plans and sends this file's ops, then reads it again in the session. Returns its status word."""
        tgt = reads_of[s.label]
        s.say("%s  (%s)" % (s.label, s.address))
        installed = True
        try:
            creates, updates = plan(src, tgt, say=lambda l: l == "NOT-INSTALLED" or s.say(l))
        except SystemExit as e:
            if e.code == 2:
                installed, creates, updates = False, [], []
                s.say("  the add-on is not installed in this file")
            else:
                s.say("  failed: the layout %s is missing; reinstall the add-on" % LAYOUT)
                return "failed", installed
        s.installed = installed
        if creates or updates:
            if installed and below(version(tgt), "0.2.3"):
                pre023.append(s.label)
        g = grants[s.label]
        if g:
            s.say("  privilege grants planned (see above)")
            if apply_ and not grant:
                pskip.append(s.label); g = None
        if not creates and not updates and not g:
            return ("up to date" if installed else "not installed"), installed
        if not hold or s.bad:
            if hold:
                s.close("read")  # its error results would roll the writes back; start clean
            s.start()
            s.opened = True
        s.send(creates)
        if s.ok and creates:
            again = reread(s, creates)
            if s.ok:
                _, updates = plan(src, again, say=lambda *a: None)
        if s.ok:
            s.send(updates)
        if s.ok and g:
            s.send([g])
        if not s.ok:
            return "failed", installed
        if apply_:
            s.post = reread(s, creates)
            if not s.ok:
                return "failed", installed
            if installed:
                bad = [n for n in SCRIPTS if s.post["scripts"][n] is None or differing(src["scripts"][n]["body"], s.post["scripts"][n]["body"])]
                bad += ["field " + n for n in missing_fields(src, s.post)]
                bad += ["layout"] if layout_flat(src["layout"]) != layout_flat(s.post["layout"]) else []
                if bad:
                    s.verify_failed = ", ".join(bad)
                    return "verify failed", installed
        return "changed", installed

    if hold:
        with ThreadPoolExecutor(max_workers=len(live)) as ex:
            results = list(ex.map(work, live))
        # commit (or end the dry run) for every file, then print each file's lines in the order given
        with ThreadPoolExecutor(max_workers=len(live)) as ex:
            closed = list(ex.map(lambda s: s.close() or (bool(s.bad) and not getattr(s, "opened", False)), live))
    else:
        results, closed = [], []
        for s in live:
            results.append(work(s))
            closed.append(s.close() if getattr(s, "opened", False) else True)
    # a file with nothing to send has nothing to commit
    closed = [c or st in ("up to date", "not installed") for c, (st, _) in zip(closed, results)]
    for s, (status, installed), committed in zip(live, results, closed):
        print("\n".join(s.out))
        if status == "changed" and not committed:
            status = "failed"
        if status == "failed":
            print("  failed:")
            for e in s.errors():
                print(e)
            print("  This file was rolled back and may need a rerun. A lock error (303, 3313, 3315) means someone has Manage Database or the script editor open.")
            report.append("%s: failed" % s.label)
        elif status == "verify failed":
            print("  verify failed: MISMATCH " + s.verify_failed)
            report.append("%s: applied but verify failed (MISMATCH %s)" % (s.label, s.verify_failed))
        elif status == "up to date":
            report.append("%s: already up to date" % s.label)
        elif status == "not installed":
            report.append("%s: add-on not installed, nothing to grant" % s.label)
        elif not apply_:
            report.append("%s: would be updated" % s.label)
        elif installed:
            print("  updated and verified"); report.append("%s: updated and verified" % s.label)
            n = privilege_sets_needing_grant(s.post)
            if n and not export:
                needs_sets.append("%s (%s)" % (s.label, ", ".join(n)))
        else:
            print("  privileges applied"); report.append("%s: privileges applied" % s.label)
    changed = [s for s, (st, _) in zip(live, results) if st == "changed"]

    def skipped_note():
        if pskip:
            print("\nPrivilege grants were planned but not applied in %s. Rerun with --grant-privileges to apply them." % " ".join(pskip))
    def multifile_note():
        if pre023 and not export:
            print("\nCheck the pipeline account's record access in %s and every file their solution uses (see \"Multi-file solutions\" in README.md):" % " ".join(pre023))
            print("  FileMaker opens other files with that account's own privilege set, even though the export runs with full access. Where it cannot")
            print("  access a base table's records, the SaXML silently leaves out every table occurrence in other files based on that table. View limited by False fixes it without showing any record.")
            print("  Run again with every file of the solution and --export-account=<the pipeline's account> to check and set it.")

    if not changed and not any(st in ("failed", "verify failed") for st, _ in results):
        print("\nNothing to apply.")
        print("\n".join("  " + r for r in report))
        skipped_note()
        sys.exit(0)
    if not apply_:
        print("\n== Summary (dry run)"); print("\n".join("  " + r for r in report))
        multifile_note()
        print("\nDry run only: nothing was changed. Back the files up, close Manage Database and the script editor in each, then run again with --apply%s to update %d file(s)."
              % (" (and --grant-privileges for the privilege grants)" if export else "", len(changed)))
        sys.exit(0)
    print("\n== Summary"); print("\n".join("  " + r for r in report))
    if export and grant:
        print("\n== Privileges after the update")
        after = {s.label: (getattr(s, "post", None) or reads_of[s.label]) for s in live}
        plans, warns = privilege_plan(after, export)
        if all(op is None for op, _ in plans.values()):
            print("  verified: the export account has everything it needs in every file")
        else:
            for lab, (op, say) in plans.items():
                for l in say[1:] if op is not None else [l for l in say if l.strip().startswith(("NOTE", "PROBLEM"))]:
                    print("  still missing: %s: %s" % (lab, l.strip()))
            for w in warns:
                print("  still missing: WARNING " + w)
    elif needs_sets:
        print("\nThese files have privilege sets that lack access to something the add-on added. fields: no access to jobStatus or jobMessage. script: cannot execute saxmlDelivery_getVersion.")
        print("\n".join("  " + n for n in needs_sets))
        print("If the Data API account uses one of them, rerun with every file of the solution, --export-account=<that account> and --grant-privileges.")
    skipped_note()
    multifile_note()
    sys.exit(1 if any(st in ("failed", "verify failed") for st, _ in results) or not all(closed) else 0)
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
    print("  filemaker total: %.1f; wall clock %.1f (the files run at the same time, so the total can exceed it)" % (cli, wall))
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

# Every file at once, one filemaker session each; see the multi command in the helper.
ARGS=()
for t in "${TARGETS[@]}"; do f=$(hosted "$t"); n=${f##*/}; ARGS+=("${n%.fmp12}|$f"); done
H multi "$TMP/source.txt" "$TMP/read.ndjson" "$TMP" "$APPLY" "$GRANT" "$EXPORT" -- "${ARGS[@]}" -- \
  "--username=$USERNAME" --keychain ${CREDS[@]+"${CREDS[@]}"} --prompt
