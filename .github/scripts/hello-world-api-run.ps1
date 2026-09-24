# hello-world-api-run.ps1 -- the Windows twin of hello-world-api-run.sh: run the Hello World
# pipeline through the HTTP API of a RUNNING Salpa and prove the worker path works
# (Redis queue -> RQ SimpleWorker -> bocoflow_worker.tasks.* -> three nodes -> three files).
#
# Session-free endpoints only, so no X-Session-ID plumbing.
#
# Runs fine from session 0, where an SSH login on Windows lands: it only speaks HTTP and reads
# files the worker wrote as the same user. Launching the app is the caller's job, and has to
# happen in a desktop session.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File hello-world-api-run.ps1 `
#             [-Api http://127.0.0.1:18000/api] [-Work C:\Users\me\hw-api] [-TimeoutS 300]
# Exit 0 on PASS, 1 on FAIL. The last line is RESULT: ...
param(
  [string]$Api = "http://127.0.0.1:18000/api",
  [string]$Work = "",
  [int]$TimeoutS = 300
)
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
if (-not $Work) { $Work = Join-Path $env:TEMP ("hello-world-api-" + (Get-Date -Format "yyyyMMdd-HHmmss")) }
$Base = $Api -replace '/api$', ''
$T0 = Get-Date

function Since($t) { [int]((Get-Date) - $t).TotalSeconds }
function Ok($msg)  { Write-Output "  ok    $msg" }
function Fail($msg) {
  Write-Output "  FAIL  $msg"
  Write-Output ("RESULT: FAIL  $msg (after " + (Since $T0) + "s; work dir $Work)")
  exit 1
}
function Get-Json($path) {
  try { return Invoke-RestMethod -Method Get -Uri "$Api$path" -TimeoutSec 60 } catch { return $null }
}
function Post-Json($path, $obj) {
  try {
    return Invoke-RestMethod -Method Post -Uri "$Api$path" -ContentType "application/json" `
      -Body ($obj | ConvertTo-Json -Compress -Depth 8) -TimeoutSec 120
  } catch { return @{ error = $_.Exception.Message } }
}
# Run $probe until it returns something truthy or the deadline passes; $null on timeout.
function Wait-For([int]$seconds, [int]$interval, [scriptblock]$probe) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ($true) {
    $v = & $probe
    if ($v) { return $v }
    if ((Get-Date) -ge $deadline) { return $null }
    Start-Sleep $interval
  }
}

Write-Output "=== hello-world-api-run: $Api  work=$Work  timeout=${TimeoutS}s ==="

# 1. server
$t = Get-Date
$up = Wait-For $TimeoutS 5 { try { Invoke-RestMethod -Uri "$Base/health" -TimeoutSec 5 | Out-Null; $true } catch { $false } }
if (-not $up) { Fail "no /health on $Base within ${TimeoutS}s" }
$Thealth = Since $t; Ok "server answers /health (${Thealth}s)"

# 2. worker -- a queued job with no worker looks exactly like a slow one
$t = Get-Date
$workers = Wait-For 60 3 { $w = Get-Json "/workers"; if ($w -and $w.workers) { @($w.workers).Count } else { 0 } }
if (-not $workers) {
  Write-Output ("  /workers -> " + ((Get-Json "/workers") | ConvertTo-Json -Compress -Depth 4))
  Fail "no RQ worker registered within 60s -- the job could never start"
}
$Tworker = Since $t; Ok "$workers worker(s) registered (${Tworker}s)"

# 3. template -- bootstrap is lazy: touch the marketplace, then wait for the entry AND its package
$t = Get-Date
try { Invoke-RestMethod -Uri "$Api/marketplace/packages" -TimeoutSec 180 | Out-Null } catch {}
$entry = Wait-For 120 5 {
  $l = Get-Json "/shelf/workflows"
  if ($l -and $l.workflows) {
    @($l.workflows) | Where-Object { $_.id -eq "hello-world-pipeline" -and $_.all_packages_installed } | Select-Object -First 1
  }
}
if (-not $entry) {
  $l = Get-Json "/shelf/workflows"
  if ($l -and $l.workflows) { @($l.workflows) | ForEach-Object { Write-Output ("  offered: " + $_.id + " " + $_.source_id + " " + $_.packages_installed + "/" + $_.packages_total) } }
  Fail "hello-world-pipeline not offered with its package installed within 120s"
}
$sourceId = if ($entry.source_id) { $entry.source_id } else { "official" }
$Ttemplate = Since $t; Ok "template offered by source '$sourceId' (${Ttemplate}s)"

# 4. load (the server refuses a new workflow whose folder's parent does not exist; make it all)
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$t = Get-Date
$r = Post-Json "/shelf/workflows/$sourceId/hello-world-pipeline/load" @{ working_path = $Work }
$wf = $r.workflow_id
if (-not $wf) { Write-Output ("  /load -> " + ($r | ConvertTo-Json -Compress -Depth 4)); Fail "template did not load" }
$Tload = Since $t; Ok ("loaded as workflow " + $wf.Substring(0, 8) + " (${Tload}s)")

$wfData = Get-Json "/workflow/$wf"
$nodeIds = @()
if ($wfData.graph -and $wfData.graph.nodes) {
  $nodeIds = @($wfData.graph.nodes | ForEach-Object { if ($_.id) { $_.id } else { $_.node_id } })
}
if ($nodeIds.Count -eq 0 -and $wfData.react) {
  foreach ($layer in $wfData.react.layers) {
    if ($layer.type -eq "diagram-nodes") { $nodeIds = @($layer.models.PSObject.Properties.Name) }
  }
}
if ($nodeIds.Count -ne 3) { Fail ("expected 3 nodes in the loaded workflow, found " + $nodeIds.Count) }

# 5. run
$t = Get-Date
$r = Post-Json "/workflow/$wf/execute_async" @{}
$job = $r.job_id
if (-not $job) { Write-Output ("  /execute_async -> " + ($r | ConvertTo-Json -Compress -Depth 4)); Fail "orchestrator job was not enqueued" }
Ok ("orchestrator enqueued as job " + $job.Substring(0, 8))

$deadline = (Get-Date).AddSeconds($TimeoutS); $lastPrint = Get-Date; $status = ""
while ($true) {
  $js = Get-Json "/job/$job/status"
  $status = if ($js) { [string]$js.status } else { "" }
  if ($status -eq "finished") { break }
  if ($status -in @("failed", "canceled", "stopped")) {
    Write-Output ("  job status -> " + ($js | ConvertTo-Json -Compress -Depth 4))
    Fail "orchestrator job $status after $(Since $t)s"
  }
  if (((Get-Date) - $lastPrint).TotalSeconds -ge 10) {
    Write-Output ("        " + (Since $t) + "s  " + $status + "  " + $js.status_message); $lastPrint = Get-Date
  }
  if ((Get-Date) -ge $deadline) {
    Write-Output ("  job status -> " + ($js | ConvertTo-Json -Compress -Depth 4))
    Fail "job still '$status' after ${TimeoutS}s"
  }
  Start-Sleep 2
}
$Trun = Since $t; Ok "orchestrator finished (${Trun}s)"

$completed = 0
foreach ($nid in $nodeIds) {
  $h = Get-Json "/workflow/$wf/node/$nid/history?limit=1"
  $st = if ($h -and $h.executions -and @($h.executions).Count -gt 0) { [string]$h.executions[0].status } else { "no history" }
  Write-Output ("        node " + $nid.Substring(0, 8) + "  " + $st)
  if ($st -eq "completed") { $completed++ }
}
if ($completed -ne 3) { Fail "$completed/3 nodes completed" }
Ok "3/3 nodes completed"

# Execution History once gave a run the duration of its longest node. A run
# lasts from its first node's start to its last node's finish. The three nodes here run one after
# another, so the two differ, and the history must report the span. The longest node is printed
# too, so the record shows whether this run could tell the two apart.
# A timestamp arrives as a string in Windows PowerShell 5.1, and already as a DateTime in
# PowerShell 7, which converts ISO strings itself. Both go through the same conversion, which
# keeps the milliseconds.
function To-Utc($v) {
  if ($v -is [datetime]) { return $v.ToUniversalTime() }
  return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
}
$longest = [int64]0
foreach ($nid in $nodeIds) {
  $h = Get-Json "/workflow/$wf/node/$nid/history?limit=1"
  if ($h -and $h.executions -and @($h.executions).Count -gt 0 -and $h.executions[0].duration_ms) {
    $longest = [math]::Max($longest, [int64]$h.executions[0].duration_ms)
  }
}
$hist = Get-Json "/workflow/$wf/execution-history?limit=1"
if (-not $hist -or -not $hist.executions -or @($hist.executions).Count -eq 0) { Fail "no run in execution-history" }
$e = @($hist.executions)[0]
if ([int]$e.node_count -ne 3) { Fail ("the run in execution-history has " + $e.node_count + " node(s), expected 3") }
$span = [int64]((To-Utc $e.completed_at) - (To-Utc $e.started_at)).TotalMilliseconds
$dur = [int64]$e.duration_ms
if ([math]::Abs($dur - $span) -gt 250) {
  Fail ("execution-history says the run took {0:F1}s, but it spans {1:F1}s" -f ($dur / 1000), ($span / 1000))
}
$tell = if (($span - $longest) -ge 250) { "" } else { ", too close to the longest node to tell the two apart" }
Ok ("run duration {0:F1}s = its span; the longest node took {1:F1}s{2}" -f ($dur / 1000), ($longest / 1000), $tell)

# 6. files
foreach ($f in "demo_encrypted.txt", "demo_decrypted.txt", "demo_reveal.txt") {
  $p = Join-Path $Work $f
  if (-not (Test-Path $p) -or (Get-Item $p).Length -eq 0) {
    Write-Output ("  $Work contains: " + ((Get-ChildItem $Work -Name -ErrorAction SilentlyContinue) -join " "))
    Fail "$f missing or empty in $Work"
  }
}
Ok "demo_encrypted.txt, demo_decrypted.txt, demo_reveal.txt written"
$reveal = Get-Content (Join-Path $Work "demo_reveal.txt") -Raw
if ($reveal -notmatch "Verification: PASS") { Write-Output $reveal; Fail "demo_reveal.txt does not say 'Verification: PASS'" }
Ok "demo_reveal.txt: Verification: PASS"

Write-Output ("RESULT: PASS  hello-world via API in " + (Since $T0) + "s (health ${Thealth}s, worker ${Tworker}s, template ${Ttemplate}s, load ${Tload}s, run ${Trun}s; $workers worker(s); work dir $Work)")
exit 0
