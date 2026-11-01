# DoubleCmdRPC

DoubleCmdRPC is an **opt-in, host-integrated debug interface** for developing and testing RemoteThumbnailWFX. It is not a WFX/WDX/WLX plug-in and it does not add a network listener or an arbitrary command-execution API.

## Enabling the server

Release builds keep the server disabled unless Double Commander is started with:

```powershell
.\doublecmd.exe --debug-rpc
```

Debug builds enable it automatically. The server starts only after `TfrmMain` exists and stops before application teardown.

For process ID `1234`, the endpoint is:

```text
\\.\pipe\doublecmd-debug-1234
```

Each request and response is one UTF-8 JSON value followed by LF. The maximum request size is 1 MiB. Multiple clients can connect concurrently; requests on one connection are processed in order. Every request must carry a JSON-RPC `id` (notifications are intentionally rejected).

## Security model

- Windows Named Pipe transport only; no TCP listener.
- Pipe DACL grants access only to the current user's SID.
- After connection, the server obtains the client process ID and compares the client process token SID with the server process token SID.
- `PIPE_REJECT_REMOTE_CLIENTS` rejects remote-machine pipe access.
- There is no method for shell execution, loading arbitrary DLLs, reading arbitrary files, or writing arbitrary files.
- `plugin.getExports` checks only a fixed allow-list of symbols in an already loaded WFX module.
- GUI state changes are queued to the Lazarus main thread and bounded by a timeout.

The endpoint is a development facility, not a production remote-control boundary. Do not enable it in an untrusted interactive session.

## Command-line client

Build `tools/dc-debugctl/dc-debugctl.lpi`, then call methods by PID:

```powershell
.\tools\dc-debugctl\dc-debugctl.exe --pid 1234 dc.ping '{}'
.\tools\dc-debugctl\dc-debugctl.exe --pid 1234 --pretty dc.getState '{}'
.\tools\dc-debugctl\dc-debugctl.exe --pid 1234 dc.navigate `
  '{"panel":"left","path":"wfx://RemoteThumbnail/Pictures","timeout_ms":10000}'
```

A full request can be supplied with `--request`. For PowerShell automation, `--request-file <utf8-json-file>` is recommended because it preserves malformed parser-test input and avoids Windows native-argument quote rewriting. Exit code 0 means a JSON-RPC result, 4 means the response contained a JSON-RPC error, 2 is a command-line error, and 3 is a transport/client failure.

## Logging

The server writes JSON Lines to:

```text
<DC configuration directory>\logs\debug-rpc.jsonl
```

Entries contain `timestamp`, `request_id`, `test_id`, `component`, `operation`, `duration_ms`, `result`, and `error`; diagnostic events may add `detail` and `thread_id`. The in-memory recent ring is available through `log.getRecent`.

Do not place secrets in `test_id`. RemoteThumbnail structured diagnostics contain stage names, outcome labels, and photo UUIDs—not credentials or remote file contents.

## Build

Use the same pinned Double Commander commit and Lazarus/FPC toolchain as the RemoteThumbnail host bridge. Add `src/debugrpc` to every project build-mode unit path (already done in `src/doublecmd.lpi`). A typical invocation is:

```powershell
$laz = '<portable-lazarus>'
$fpc = Join-Path $laz 'fpc\3.2.2\bin\x86_64-win64\ppcx64.exe'
& (Join-Path $laz 'lazbuild.exe') `
  "--lazarusdir=$laz" "--compiler=$fpc" `
  --os=win64 --cpu=x86_64 --ws=win32 --bm=Release `
  .\src\doublecmd.lpi
& (Join-Path $laz 'lazbuild.exe') `
  "--lazarusdir=$laz" "--compiler=$fpc" `
  --os=win64 --cpu=x86_64 --bm=Release `
  .\tools\dc-debugctl\dc-debugctl.lpi
```

See [RPC_API.md](RPC_API.md) for method contracts and [TEST_AUTOMATION.md](TEST_AUTOMATION.md) for an end-to-end RemoteThumbnail test sequence.
