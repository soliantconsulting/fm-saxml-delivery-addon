#!/usr/bin/env bash
# Brings an installed copy of the SaXML delivery add-on up to date, whatever version it is on.
# The latest definitions are read from src/SaXMLDelivery.fmp12 in this repo. See README.md.
#   update-saxml-addon.sh --username=<account> [--host=<host>] [--apply] <file>,<file>,...
# A <file> is a name on --host, or a full path or fmnet:// address. Separate files with commas.
# Without --apply it only does a dry run and changes nothing.
#
# It compares each installed file with the source and, for what differs:
#   - creates missing fields
#   - replaces the layout's objects with the latest ones (the layout is not meant to be customized)
#   - creates missing scripts
#   - replaces the body of existing scripts in place (script ids and names stay, so references keep working)
# It never deletes anything. It does not touch privilege sets; see update-saxml-addon.prompt.md.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SOURCE=${SOURCE:-$HERE/../src/SaXMLDelivery.fmp12}
SOURCE_USER=${SOURCE_USER:-Admin}

USERNAME="" HOST="" APPLY=0 TARGETS=()
for a in "$@"; do
  case $a in
    --username=*) USERNAME=${a#*=} ;;
    --host=*) HOST=${a#*=} ;;
    --apply) APPLY=1 ;;
    --*) echo "unknown option: $a" >&2; exit 64 ;;
    *) IFS=, read -ra parts <<< "$a"
       for p in "${parts[@]}"; do
         p=${p#"${p%%[![:space:]]*}"}; p=${p%"${p##*[![:space:]]}"}  # trim spaces around a name
         [ -n "$p" ] && TARGETS+=("$p")
       done ;;
  esac
done
[ -n "$USERNAME" ] && [ ${#TARGETS[@]} -gt 0 ] || { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
for t in "${TARGETS[@]}"; do
  [[ $t == */* || -n $HOST ]] || { echo "$t is a bare name; give --host=<host> or a full path" >&2; exit 64; }
done
command -v filemaker >/dev/null || { echo "the filemaker command (part of ADK) is not on PATH" >&2; exit 1; }
[ -f "$SOURCE" ] || { echo "missing $SOURCE" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Helper for the JSON work. The six reads (3 scripts, the fields, the layout) are the same for the
# source and each target.
#   plan:   what each element needs, written as op files (creates, then script updates)
#   verify: the target now matches the source
#   errors: print the errors in an output file
cat > "$TMP/helper.py" <<'PY'
import json, sys

SCRIPTS = ["saxmlDelivery_createXml", "saxmlDelivery_readme", "saxmlDelivery_runPipeline"]
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
    if len(ops) != len(SCRIPTS) + 3:
        raise SystemExit("ERROR no read result (did the file open?)")
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

def version(r):
    s = r["scripts"].get("saxmlDelivery_createXml")
    for st in (s or {}).get("body", []):
        if st.get("name") == "$addonVersion":
            return st["value"].strip('"')
    return "unknown"

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

def privilege_sets_needing_grant(r):
    """Custom privilege sets that list the table's fields one by one and give no access to a job field.
    A set that grants all fields, or has no grant of its own for the table, covers new fields already."""
    out = []
    for s in r["privsets"]:
        for t in s.get("records", {}).get("tables", []):
            if t["name"] != TABLE or t.get("fields", {}).get("access") != "limited":
                continue
            granted = {f["name"] for f in t["fields"].get("fields", []) if f.get("access") != "noAccess"}
            if not {"jobStatus", "jobMessage"} <= granted:
                out.append(s["name"])
    return out

cmd = sys.argv[1]
if cmd == "version":
    print(version(reads(sys.argv[2])))
elif cmd == "plan":
    src, tgt = reads(sys.argv[2]), reads(sys.argv[3])
    if all(v is None for v in tgt["scripts"].values()) and not tgt["fields"]:
        print("NOT-INSTALLED")
        sys.exit(2)
    if tgt["layout"] is None:
        print("ERROR the layout %s is missing; reinstall the add-on" % LAYOUT, file=sys.stderr)
        sys.exit(3)
    creates, updates = [], []
    print("  installed version %s, latest %s" % (version(tgt), version(src)))
    for n in missing_fields(src, tgt):
        f = src["fields"][n]
        op = {"op": "create:field", "table": TABLE, "name": n, "type": f["type"]}
        for k in ("fieldType", "comment", "calculation", "options"):
            if k in f:
                op[k] = f[k]
        creates.append(op)
        print("  field %-24s CREATE" % n)
    if layout_flat(src["layout"]) != layout_flat(tgt["layout"]):
        creates += layout_ops(src, tgt)
        print("  layout %-26s REPLACE OBJECTS" % LAYOUT)
    else:
        print("  layout %-26s unchanged" % LAYOUT)
    for n in SCRIPTS:
        s, t = src["scripts"][n], tgt["scripts"][n]
        if t is None:
            creates.append({"op": "create:script", "name": n, "folder": s["folder"], "hidden": s["hidden"],
                            "runWithFullAccess": s["runWithFullAccess"], "body": s["body"]})
            print("  script %-26s CREATE (%d steps)" % (n, s["steps"]))
        else:
            d = differing(s["body"], t["body"])
            if d == 0:
                print("  script %-26s unchanged" % n)
            else:
                updates.append({"op": "update:script", "name": n, "token": t["token"], "body": s["body"]})
                print("  script %-26s UPDATE (%d -> %d steps, %d differ)" % (n, t["steps"], s["steps"], d))
    open(sys.argv[4], "w").write("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in creates))
    open(sys.argv[5], "w").write("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in updates))
    print("NOTHING-TO-DO" if not creates and not updates else "CHANGES")
elif cmd == "verify":
    src, tgt = reads(sys.argv[2]), reads(sys.argv[3])
    bad = [n for n in SCRIPTS if tgt["scripts"][n] is None or differing(src["scripts"][n]["body"], tgt["scripts"][n]["body"])]
    bad += ["field " + n for n in missing_fields(src, tgt)]
    bad += ["layout"] if layout_flat(src["layout"]) != layout_flat(tgt["layout"]) else []
    print("MISMATCH " + ", ".join(bad) if bad else "OK")
    sys.exit(1 if bad else 0)
elif cmd == "privneeds":
    print(", ".join(privilege_sets_needing_grant(reads(sys.argv[2]))))
elif cmd == "errors":
    for o in lines(sys.argv[2]):
        if o.get("status") == "error" or o.get("type") == "fatal":
            e = o["error"]
            print("    %s (dbError %s): %s" % (e.get("code"), e.get("dbError", "-"), e.get("message", "")[:240]))
PY

H() { python3 -I "$TMP/helper.py" "$@"; }
run() { # run <file> <ndjson> [--dry-run] -> output in $TMP/out.txt
  local f=$1 ops=$2; shift 2
  filemaker "--file=$f" "--username=$USERNAME" --keychain --prompt "$@" "$ops" > "$TMP/out.txt" 2>&1
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
{"op":"read:field","table":"SaXMLDelivery","detail":true}
{"op":"read:layout","name":"SaXMLDeliveryExecutionContext","detail":true}
{"op":"read:privilegeSet","detail":true,"filter":{"builtIn":false}}
E

echo "Reading the latest definitions from $(basename "$SOURCE")"
filemaker "--file=$SOURCE" "--username=$SOURCE_USER" "$TMP/read.ndjson" > "$TMP/source.txt" 2>&1
H plan "$TMP/source.txt" "$TMP/source.txt" /dev/null /dev/null >/dev/null 2>"$TMP/err.txt" \
  || { echo "could not read the source file: $(cat "$TMP/err.txt")" >&2; exit 1; }
echo "Latest version: $(H version "$TMP/source.txt")"

declare -a OK_TARGETS=() REPORT=() REACHABLE=() UPDATED=() NEEDS=()

# Phase 0: ask for every password up front. Opening a file with no operations settles its
# credentials and changes nothing, and FileMaker offers to keep the password in the keychain,
# so the later phases need no prompts as long as you accept that offer.
echo; echo "== Passwords"
echo "If a password window appears, enter the password there."
for t in "${TARGETS[@]}"; do
  f=$(hosted "$t")
  echo "$t"
  run "$f" /dev/null
  if grep -q '"type":"summary"' "$TMP/out.txt" && ! grep -q '"type":"fatal"' "$TMP/out.txt"; then
    REACHABLE+=("$t")
  else
    echo "  cannot open it, so it will be skipped:"; H errors "$TMP/out.txt"
    REPORT+=("$t: skipped (could not open: login or connection failed)")
  fi
done
[ ${#REACHABLE[@]} -gt 0 ] || { echo; echo "No file could be opened."; printf '  %s\n' "${REPORT[@]}"; exit 1; }
if [ $APPLY -eq 1 ]; then echo; echo "== Plan (--apply: the update follows straight away)"; else echo; echo "== Dry run"; fi

# Phase 1: plan every file. A dry run also asks the file to check each operation without writing.
i=0
for t in "${REACHABLE[@]}"; do
  i=$((i+1)); f=$(hosted "$t")
  echo "$t  ($f)"
  run "$f" "$TMP/read.ndjson"
  if ! H plan "$TMP/source.txt" "$TMP/out.txt" "$TMP/c$i.ndjson" "$TMP/u$i.ndjson" > "$TMP/plan.txt" 2>"$TMP/err.txt"; then
    if grep -q NOT-INSTALLED "$TMP/plan.txt"; then
      echo "  skipped: the add-on is not installed in this file"; REPORT+=("$t: skipped (add-on not installed)")
    else
      echo "  failed: $(cat "$TMP/err.txt")"; REPORT+=("$t: failed ($(cat "$TMP/err.txt"))")
    fi
    continue
  fi
  grep -v -E '^(CHANGES|NOTHING-TO-DO)$' "$TMP/plan.txt"
  if grep -q NOTHING-TO-DO "$TMP/plan.txt"; then REPORT+=("$t: already up to date"); continue; fi
  if [ $APPLY -eq 0 ]; then
    bad=0
    for ops in "$TMP/c$i.ndjson" "$TMP/u$i.ndjson"; do
      [ -s "$ops" ] || continue
      # Script updates may use fields that the creates add, so they can only be checked once those exist.
      if [ "$ops" = "$TMP/u$i.ndjson" ] && [ -s "$TMP/c$i.ndjson" ]; then echo "  script updates are checked after the creates are applied"; continue; fi
      run "$f" "$ops" --dry-run
      if ! grep -q '"errors":0' "$TMP/out.txt"; then bad=1; echo "  dry run refused:"; H errors "$TMP/out.txt"; fi
    done
    if [ $bad -eq 1 ]; then REPORT+=("$t: failed dry run"); continue; fi
    REPORT+=("$t: would be updated")
  fi
  OK_TARGETS+=("$i|$t|$f")
done

if [ ${#OK_TARGETS[@]} -eq 0 ]; then
  echo; echo "Nothing to apply."; printf '  %s\n' "${REPORT[@]}"; exit 0
fi

if [ $APPLY -eq 0 ]; then
  echo; echo "== Summary (dry run)"; printf '  %s\n' "${REPORT[@]}"
  echo; echo "Dry run only: nothing was changed. Back the files up, close Manage Database and the script editor in each, then run again with --apply to update ${#OK_TARGETS[@]} file(s)."
  exit 0
fi

# Phase 2: apply, then verify from a fresh read.
echo; echo "== Apply"
for entry in "${OK_TARGETS[@]}"; do
  IFS='|' read -r i t f <<< "$entry"
  echo "$t"
  failed=0
  if [ -s "$TMP/c$i.ndjson" ]; then
    run "$f" "$TMP/c$i.ndjson"
    grep -q '"errors":0' "$TMP/out.txt" && grep -q '"rolledBack":false' "$TMP/out.txt" || { failed=1; H errors "$TMP/out.txt"; }
    # Creating fields and scripts invalidates earlier tokens, so plan the updates again from a fresh read.
    if [ $failed -eq 0 ]; then
      run "$f" "$TMP/read.ndjson"
      H plan "$TMP/source.txt" "$TMP/out.txt" "$TMP/c$i.ndjson" "$TMP/u$i.ndjson" >/dev/null 2>&1 || failed=1
    fi
  fi
  if [ $failed -eq 0 ] && [ -s "$TMP/u$i.ndjson" ]; then
    run "$f" "$TMP/u$i.ndjson"
    grep -q '"errors":0' "$TMP/out.txt" && grep -q '"rolledBack":false' "$TMP/out.txt" || { failed=1; H errors "$TMP/out.txt"; }
  fi
  if [ $failed -eq 0 ]; then
    run "$f" "$TMP/read.ndjson"
    v=$(H verify "$TMP/source.txt" "$TMP/out.txt" 2>&1) && { echo "  updated and verified"; REPORT+=("$t: updated and verified"); UPDATED+=("$t")
                     sets=$(H privneeds "$TMP/out.txt" 2>/dev/null)
                     if [ -n "$sets" ]; then NEEDS+=("$t ($sets)"); fi; } \
      || { echo "  verify failed: $v"; REPORT+=("$t: applied but verify failed ($v)"); }
  else
    echo "  failed (see above); this file may need a rerun. A lock error (303, 3313, 3315) means someone has Manage Database or the script editor open."
    REPORT+=("$t: failed")
  fi
done

echo; echo "== Summary"; printf '  %s\n' "${REPORT[@]}"
if [ ${#NEEDS[@]} -gt 0 ]; then
  echo; echo "These files have privilege sets that list the SaXMLDelivery fields one by one, with no access to jobStatus or jobMessage:"
  printf '  %s\n' "${NEEDS[@]}"
  echo "If the account that reads the job record over the Data API uses one of them, it needs view access to both fields. To update them, give this prompt to Claude Code, started in this repo:"
  echo
  files=$(IFS=,; for n in "${NEEDS[@]}"; do echo "${n%% (*}"; done | paste -sd, -)
  echo "  Follow update/update-saxml-addon.prompt.md, section 2 only, to update the privilege sets in $files${HOST:+ on $HOST}. The schema and scripts are already updated. Use the account $USERNAME."
fi
