#!/usr/bin/env bash
# hello-world-api-run.sh -- run the Hello World pipeline through the HTTP API of a RUNNING Salpa
# and prove the worker path works: Redis queue -> RQ worker -> bocoflow_worker.tasks.* -> three
# nodes -> three files on disk.
#
# WHY THIS EXISTS
#
# An install check that stops at "the backend answered" or "the node registry is non-empty"
# never puts a job on the queue, so a worker that cannot import its tasks passes it. The RQ worker
# resolves `bocoflow_worker.tasks.execute_node` and `orchestrate_workflow_parallel` by dotted
# string at job time; this is the check that exercises that resolution on a packaged build, with
# no UI and no session.
#
# Every endpoint here is session-free, so plain curl works from a CI runner, an SSH session, or
# a terminal next to a running app.
#
# Usage:
#   hello-world-api-run.sh [--api http://127.0.0.1:18000/api] [--work DIR] [--timeout-s 300]
#
# Exit 0 on PASS, 1 on FAIL; the last line is `RESULT: ...` with timings. Does NOT launch or
# stop the app -- that is the caller's job (see .github/workflows/linux-deb-smoke.yml).
set -uo pipefail

API="http://127.0.0.1:18000/api"
WORK=""
TIMEOUT_S=300
while [ $# -gt 0 ]; do
  case "$1" in
    --api)       API="$2"; shift 2 ;;
    --work)      WORK="$2"; shift 2 ;;
    --timeout-s) TIMEOUT_S="$2"; shift 2 ;;
    -h|--help)   sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$WORK" ] || WORK="${TMPDIR:-/tmp}/hello-world-api-$(date +%s)"
BASE="${API%/api}"          # /health lives beside /api, not under it
T0=$(date +%s)

for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "RESULT: FAIL  $tool not found"; exit 1; }
done

# ------------------------------------------------------------------------------- helpers
now()   { date +%s; }
since() { echo $(( $(now) - $1 )); }
ok()    { echo "  ok    $*"; }
fail()  { echo "  FAIL  $*"; echo "RESULT: FAIL  $* (after $(since "$T0")s; work dir $WORK)"; exit 1; }

# Body on success, empty on transport error. --max-time so a wedged server cannot hang a poll;
# the loops carry their own deadlines.
get()  { curl -sS --max-time 60 "$API$1" 2>/dev/null; }
post() { curl -sS --max-time 120 -H 'Content-Type: application/json' -X POST --data "$2" "$API$1" 2>/dev/null; }

# jq without jq. `jpy EXPR` evaluates a Python expression over the JSON on stdin (bound to `d`)
# and prints it -- strings raw, everything else as JSON, None as nothing. Any error prints
# nothing, so callers can treat "" as "not there yet".
jpy() { python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = eval(sys.argv[1])
    if v is not None:
        print(v if isinstance(v, str) else json.dumps(v))
except Exception:
    pass' "$1" 2>/dev/null; }

# poll SECONDS INTERVAL FN -- run FN until it prints something; print it. 1 on timeout.
poll() {
  local deadline=$(( $(now) + $1 )) out
  while :; do
    out=$("$3")
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    [ "$(now)" -ge "$deadline" ] && return 1
    sleep "$2"
  done
}

server_up()     { curl -sf --max-time 5 -o /dev/null "$BASE/health" && echo up; }
worker_count()  { get /workers | jpy 'len(d.get("workers", [])) or ""'; }
# Offered AND installed: /load does not check installation, execution would just fail later.
template_entry() {
  get /shelf/workflows | jpy 'next((json.dumps(w) for w in d.get("workflows", [])
      if w.get("id") == "hello-world-pipeline" and w.get("all_packages_installed")), "")'
}

echo "=== hello-world-api-run: $API  work=$WORK  timeout=${TIMEOUT_S}s ==="

# ------------------------------------------------------------------------------- 1. server
t=$(now)
poll "$TIMEOUT_S" 5 server_up >/dev/null || fail "no /health on $BASE within ${TIMEOUT_S}s"
T_health=$(since "$t"); ok "server answers /health (${T_health}s)"

# ------------------------------------------------------------------------------- 2. worker
# A queued job with no worker looks exactly like a slow one, and telling them apart once cost
# 300 s. Ask first.
t=$(now)
workers=$(poll 60 3 worker_count) \
  || { echo "  /workers -> $(get /workers | head -c 400)"; fail "no RQ worker registered within 60s -- the job could never start"; }
T_worker=$(since "$t"); ok "$workers worker(s) registered (${T_worker}s)"

# ------------------------------------------------------------------------------- 3. template
# Bootstrapping of the default packages is LAZY -- it fires on first marketplace access, not
# at startup (linux-deb-smoke.yml). Touch it, then wait for the template.
t=$(now)
curl -sf --max-time 180 -o /dev/null "$API/marketplace/packages" || true
entry=$(poll 120 5 template_entry) \
  || { echo "  offered: $(get /shelf/workflows | jpy '[(w.get("id"), w.get("source_id"), w.get("packages_installed"), w.get("packages_total")) for w in d.get("workflows", [])]')"
       fail "hello-world-pipeline not offered with its package installed within 120s"; }
source_id=$(printf '%s' "$entry" | jpy 'd.get("source_id") or "official"')
T_template=$(since "$t"); ok "template offered by source '$source_id' (${T_template}s)"

# ------------------------------------------------------------------------------- 4. load
# The server refuses a new workflow whose folder's parent does not exist, and makes only the
# last level. Make the whole directory here, so the files land where this script looks.
mkdir -p "$WORK" || fail "cannot create $WORK"
t=$(now)
body=$(python3 -c 'import json,sys; print(json.dumps({"working_path": sys.argv[1]}))' "$WORK")
resp=$(post "/shelf/workflows/$source_id/hello-world-pipeline/load" "$body")
wf=$(printf '%s' "$resp" | jpy 'd["workflow_id"]')
[ -n "$wf" ] || { echo "  /load -> ${resp:0:400}"; fail "template did not load"; }
T_load=$(since "$t"); ok "loaded as workflow ${wf:0:8} (${T_load}s)"

# Node ids from the workflow the server now holds, not from a copy of the template.
# graph.nodes first; the react diagram-nodes layer if a template ever ships without graph.
nodes=$(get "/workflow/$wf" | jpy '" ".join(
  [n.get("id") or n.get("node_id") or "" for n in ((d.get("graph") or {}).get("nodes") or [])]
  or [k for l in (d.get("react") or {}).get("layers", []) if l.get("type") == "diagram-nodes"
        for k in (l.get("models") or {})])')
n_nodes=$(printf '%s' "$nodes" | wc -w | tr -d ' ')
[ "$n_nodes" -eq 3 ] || fail "expected 3 nodes in the loaded workflow, found $n_nodes"

# ------------------------------------------------------------------------------- 5. run
t=$(now)
resp=$(post "/workflow/$wf/execute_async" '{}')
job=$(printf '%s' "$resp" | jpy 'd["job_id"]')
[ -n "$job" ] || { echo "  /execute_async -> ${resp:0:400}"; fail "orchestrator job was not enqueued"; }
ok "orchestrator enqueued as job ${job:0:8}"

status=""; last_print=0
deadline=$(( $(now) + TIMEOUT_S ))
while :; do
  js=$(get "/job/$job/status")
  status=$(printf '%s' "$js" | jpy 'd.get("status", "")')
  case "$status" in
    finished) break ;;
    failed|canceled|stopped)
      echo "  job status -> ${js:0:600}"
      fail "orchestrator job $status after $(since "$t")s" ;;
  esac
  if [ $(( $(now) - last_print )) -ge 10 ]; then
    echo "        $(since "$t")s  ${status:-?}  $(printf '%s' "$js" | jpy 'd.get("status_message", "")')"
    last_print=$(now)
  fi
  [ "$(now)" -ge "$deadline" ] && { echo "  job status -> ${js:0:600}"; fail "job still '${status:-?}' after ${TIMEOUT_S}s"; }
  sleep 2
done
T_run=$(since "$t"); ok "orchestrator finished (${T_run}s)"

# The job finishing is the ORCHESTRATOR's word; the nodes' own records are the proof.
completed=0
for nid in $nodes; do
  st=$(get "/workflow/$wf/node/$nid/history?limit=1" | jpy 'd["executions"][0]["status"]')
  echo "        node ${nid:0:8}  ${st:-no history}"
  [ "$st" = "completed" ] && completed=$((completed + 1))
done
[ "$completed" -eq 3 ] || fail "$completed/3 nodes completed"
ok "3/3 nodes completed"

# Execution History once gave a run the duration of its longest node. A run
# lasts from its first node's start to its last node's finish. The three nodes here run one after
# another, so the two differ, and the history must report the span. The longest node is printed
# too, so the record shows whether this run could tell the two apart.
longest=0
for nid in $nodes; do
  d=$(get "/workflow/$wf/node/$nid/history?limit=1" | jpy 'int(d["executions"][0].get("duration_ms") or 0)')
  case "$d" in ''|*[!0-9]*) d=0 ;; esac
  [ "$d" -gt "$longest" ] && longest=$d
done
verdict=$(get "/workflow/$wf/execution-history?limit=1" | python3 -c '
import json, sys
from datetime import datetime
def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))  # 3.9 and 3.10 refuse a bare "Z"
longest = int(sys.argv[1])
try:
    e = json.load(sys.stdin)["executions"][0]
    span = int((ts(e["completed_at"]) - ts(e["started_at"])).total_seconds() * 1000)
    dur = int(e["duration_ms"])
    n = e.get("node_count")
except Exception as exc:
    print("FAIL no usable run in execution-history (%s)" % exc)
    sys.exit()
if n != 3:
    print("FAIL the run in execution-history has %s node(s), expected 3" % n)
elif abs(dur - span) > 250:
    print("FAIL execution-history says the run took %.1fs, but it spans %.1fs" % (dur / 1000, span / 1000))
else:
    tell = "" if span - longest >= 250 else ", too close to the longest node to tell the two apart"
    print("ok run duration %.1fs = its span; the longest node took %.1fs%s" % (dur / 1000, longest / 1000, tell))
' "$longest")
case "$verdict" in
  ok*) ok "${verdict#ok }" ;;
  *) fail "${verdict#FAIL }" ;;
esac

# ------------------------------------------------------------------------------- 6. files
# case_name is "demo" in the template's node config, so the files are demo_*.txt. The reveal
# node compares decrypted against original itself and prints the verdict -- that line IS the
# round-trip check.
for f in demo_encrypted.txt demo_decrypted.txt demo_reveal.txt; do
  [ -s "$WORK/$f" ] || { echo "  $WORK contains: $(ls -1 "$WORK" 2>/dev/null | tr '\n' ' ')"; fail "$f missing or empty in $WORK"; }
done
ok "demo_encrypted.txt, demo_decrypted.txt, demo_reveal.txt written"
grep -q 'Verification: PASS' "$WORK/demo_reveal.txt" \
  || { sed 's/^/        /' "$WORK/demo_reveal.txt"; fail "demo_reveal.txt does not say 'Verification: PASS'"; }
ok "demo_reveal.txt: Verification: PASS"

echo "RESULT: PASS  hello-world via API in $(since "$T0")s (health ${T_health}s, worker ${T_worker}s, template ${T_template}s, load ${T_load}s, run ${T_run}s; $workers worker(s); work dir $WORK)"
exit 0
