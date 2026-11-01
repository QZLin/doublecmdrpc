# RemoteThumbnailWFX test automation with DoubleCmdRPC

This sequence exercises the actual Double Commander WFX host path. It does not change PhotoThumbSync V1 or RemoteThumbnailPC protocols.

## Preconditions

1. Build the pinned Double Commander source with the canonical WFX preview bridge and DoubleCmdRPC changes.
2. Build `RemoteThumbnailWFX.wfx64` and configure it in an isolated Double Commander profile.
3. Ensure RemoteThumbnailPC produced a valid catalog/cache fixture, or enable the existing on-demand mode for an isolated non-sensitive test account.
4. Start the host with `--debug-rpc` and record its PID in a local artifact.
5. Use a unique, non-secret `test_id` per test attempt.
6. Replace `<test-host>` and `<remote-test-directory>` below; do not commit the real values, reports, logs, or screenshots.

```powershell
$pidUnderTest = 1234
$ctl = '.\tools\dc-debugctl\dc-debugctl.exe'
$test = 'ftp-direct-preview-' + [guid]::NewGuid().ToString('N')
$dir = 'wfx://FTP/<test-host>/<remote-test-directory>/'
$file = '\<test-host>\<remote-test-directory>\example.jpg'
$script:rpcId = 0

function Invoke-DcRpc {
  param([string]$Method, [hashtable]$Params = @{}, [int]$TimeoutMs = 5000,
        [switch]$Pretty)
  $script:rpcId++
  $request = @{
    jsonrpc = '2.0'; id = $script:rpcId; method = $Method
    params = $Params; timeout_ms = $TimeoutMs
  } | ConvertTo-Json -Depth 12 -Compress
  $requestFile = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($requestFile, $request,
      [Text.UTF8Encoding]::new($false))
    $arguments = @('--pid', $pidUnderTest, '--request-file', $requestFile)
    if ($Pretty) { $arguments += '--pretty' }
    & $ctl @arguments
  }
  finally {
    Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue
  }
}
```

## Baseline and host readiness

```powershell
Invoke-DcRpc dc.ping @{} -Pretty
Invoke-DcRpc dc.getInfo @{} -Pretty
Invoke-DcRpc plugin.getLoaded @{} -Pretty
```

`plugin.getLoaded` should show the configured entry; it may still report `loaded:false` before navigation. The export query below inspects the already loaded module without loading one as a side effect. Confirm `FsGetPreviewBitmapW:true` (preferred) or the ANSI fallback.

For `test.openRemoteDirectory`, use the canonical URI form with `/` separators as shown above.
After opening, Double Commander reports the equivalent WFX path with backslashes.

## Open, switch, trigger, wait

```powershell
Invoke-DcRpc test.openRemoteDirectory `
  @{panel='left'; remote_path=$dir; test_id=$test} 15000
Invoke-DcRpc plugin.getExports @{name='FTP'} -Pretty
Invoke-DcRpc dc.waitForIdle @{panel='left'} 15000
Invoke-DcRpc test.switchToThumbnailView `
  @{panel='left'; test_id=$test}
Invoke-DcRpc test.triggerPreview `
  @{panel='left'; path=$file; test_id=$test; force=$true} 15000
Invoke-DcRpc test.waitForPreview `
  @{path=$file; test_id=$test; require_draw=$true} 30000
```

`test.waitForPreview` requires the target to remain visible. The successful terminal observation is the real `Canvas.StretchDraw` call in `TThumbDrawGrid.DrawCell`, not merely callback return, bitmap wrapping, or redraw scheduling.

## Diagnose and report

```powershell
Invoke-DcRpc wfx.getStats `
  @{path=$file; test_id=$test} -Pretty
Invoke-DcRpc wfx.getLastCalls `
  @{path=$file; test_id=$test; limit=100} -Pretty
Invoke-DcRpc wfx.getErrors `
  @{path=$file; test_id=$test; limit=100} -Pretty
Invoke-DcRpc test.getReport `
  @{path=$file; test_id=$test; event_limit=200} -Pretty
```

The report separates callback absence, resolver miss, missing/invalid WebP object, decode failure, missing HBITMAP, host non-receipt, receipt without paint, and failed cache-update observation. A stage is `not observable` rather than guessed when no available host or plug-in event proves it.

## Cache behavior

First force an in-memory host miss, then trigger twice:

```powershell
Invoke-DcRpc thumbnail.invalidate @{path=$file}
# trigger + wait as above
# trigger + wait once more without invalidation
Invoke-DcRpc test.assertPreviewSource `
  @{path=$file; test_id=$test; source='host_native_cache'}
```

`thumbnail.clearCache` clears only Double Commander's bounded in-memory native bitmap cache. It deliberately does not remove RemoteThumbnailPC's immutable content-addressed WebP objects.

## Concurrency, parser, timeout, and absence smoke tests

Run [`rpc_smoke.ps1`](../tests/debugrpc/rpc_smoke.ps1) against an already running host:

```powershell
.\tests\debugrpc\rpc_smoke.ps1 -TargetPid $pidUnderTest `
  -Client .\tools\dc-debugctl\dc-debugctl.exe
```

It checks ping/info/state (including GUI dispatch), the live current-user-only pipe DACL, invalid JSON, rejected notifications, invalid methods/params, required preview correlation, batch requests, explicit timeout, an intentionally absent plug-in query, recent logs, and concurrent clients. Same-user requests exercise the post-connect identity path. Authentication should additionally be tested by launching the client under a different local account; the pipe DACL or post-connect SID check must reject it.

## Interpretation limits

- `visual_verified:true` proves that Double Commander's thumbnail grid paint callback drew the bitmap. It does not compare pixels; retain a screenshot or UI-automation assertion for visual-regression acceptance.
- SFTP connection internals are not fabricated when unavailable. The plug-in reports the observable on-demand enqueue stage as `sftp.fetch state=enqueued`.
- Per-test correlation uses registered path/UUID plus a call-chain ID. Keep one unique `test_id` per independent test and avoid concurrent tests targeting the same path unless call-level analysis is intended.
- Store machine paths, PIDs, pipe names, real WFX URIs, reports, JSONL logs, screenshots, and account-specific details in ignored `.artifacts/` or `*.local.*` files only.
