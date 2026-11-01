#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$TargetPid,

    [Parameter(Mandatory)]
    [string]$Client,

    [ValidateRange(2, 32)]
    [int]$ConcurrentClients = 8
)

$ErrorActionPreference = 'Stop'
$clientPath = [IO.Path]::GetFullPath($Client)
if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf)) {
    throw "dc-debugctl does not exist: $clientPath"
}

if (-not ('DoubleCmdRpcPipeAcl' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DoubleCmdRpcPipeAcl
{
    private const uint ReadControl = 0x00020000;
    private const uint FileShareRead = 1;
    private const uint FileShareWrite = 2;
    private const uint OpenExisting = 3;
    private const uint DaclSecurityInformation = 4;
    private const int SeKernelObject = 6;
    private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string name, uint access, uint share,
        IntPtr securityAttributes, uint creationDisposition, uint flags,
        IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint GetSecurityInfo(IntPtr handle, int objectType,
        uint securityInfo, out IntPtr owner, out IntPtr group, out IntPtr dacl,
        out IntPtr sacl, out IntPtr securityDescriptor);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
        IntPtr securityDescriptor, uint revision, uint securityInfo,
        out IntPtr text, out uint textLength);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string ReadDacl(string path)
    {
        IntPtr handle = CreateFileW(path, ReadControl,
            FileShareRead | FileShareWrite, IntPtr.Zero, OpenExisting, 0,
            IntPtr.Zero);
        if (handle == InvalidHandleValue)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetSecurityInfo(handle, SeKernelObject,
                DaclSecurityInformation, out owner, out group, out dacl,
                out sacl, out descriptor);
            if (error != 0) throw new Win32Exception((int)error);
            try
            {
                IntPtr text;
                uint length;
                if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(
                        descriptor, 1, DaclSecurityInformation,
                        out text, out length))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                try { return Marshal.PtrToStringUni(text); }
                finally { LocalFree(text); }
            }
            finally { LocalFree(descriptor); }
        }
        finally { CloseHandle(handle); }
    }
}
'@
}

function Get-DebugRpcPipeDacl([int]$ProcessId) {
    $pipePath = "\\.\pipe\doublecmd-debug-$ProcessId"
    return [DoubleCmdRpcPipeAcl]::ReadDacl($pipePath)
}

function Invoke-RpcRequest {
    param(
        [Parameter(Mandatory)][string]$Request,
        [int]$ExpectedExitCode = 0
    )
    $requestPath = Join-Path ([IO.Path]::GetTempPath()) ('doublecmd-rpc-request-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($requestPath, $Request, [Text.UTF8Encoding]::new($false))
        $output = @(& $clientPath --pid $TargetPid --request-file $requestPath 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne $ExpectedExitCode) {
        throw "RPC client exit code $exitCode, expected $ExpectedExitCode. Output: $($output -join [Environment]::NewLine)"
    }
    if ($output.Count -eq 0) { throw 'RPC client returned no JSON' }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function New-Request([int]$Id, [string]$Method, $Params = @{}, [int]$TimeoutMs = 5000) {
    return (@{
        jsonrpc = '2.0'
        id = $Id
        method = $Method
        params = $Params
        timeout_ms = $TimeoutMs
    } | ConvertTo-Json -Depth 12 -Compress)
}

$results = [ordered]@{}

$ping = Invoke-RpcRequest (New-Request 1 'dc.ping')
if (-not $ping.result.ok) { throw 'dc.ping did not return ok=true' }
if ([int]$ping.result.process_id -ne $TargetPid) { throw 'dc.ping returned an unexpected PID' }
$results.ping = 'passed'

$pipeDacl = Get-DebugRpcPipeDacl $TargetPid
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$aces = @([regex]::Matches($pipeDacl, '\([^)]*\)') | ForEach-Object { $_.Value })
$expectedAce = '^\(A;;(?:FA|GA);;;' + [regex]::Escape($currentSid) + '\)$'
if (($aces.Count -ne 1) -or ($aces[0] -notmatch $expectedAce)) {
    throw "Named Pipe DACL is not current-user-only: $pipeDacl"
}
$results.security_acl = 'passed (single current-user ACE)'

$info = Invoke-RpcRequest (New-Request 2 'dc.getInfo')
if (-not $info.result.debug_rpc_enabled) { throw 'dc.getInfo says RPC is disabled' }
$results.info = 'passed'

$state = Invoke-RpcRequest (New-Request 3 'dc.getState')
if (-not $state.result.panels.left -or -not $state.result.panels.right) {
    throw 'dc.getState did not return both GUI panels'
}
$results.gui_dispatch = 'passed'

$batch = @(
    @{jsonrpc='2.0'; id=4; method='dc.ping'; params=@{}},
    @{jsonrpc='2.0'; id=5; method='dc.getInfo'; params=@{}}
) | ConvertTo-Json -Depth 8 -Compress
$batchResponse = Invoke-RpcRequest $batch
if ($batchResponse.Count -ne 2) { throw 'JSON-RPC batch did not return two responses' }
$results.batch = 'passed'

$parseError = Invoke-RpcRequest '{not-json' 4
if ([int]$parseError.error.code -ne -32700) { throw 'Malformed JSON did not return -32700' }
$results.parse_error = 'passed'

$invalidParams = Invoke-RpcRequest (New-Request 6 'dc.navigate' @('not-an-object')) 4
if ([int]$invalidParams.error.code -ne -32602) { throw 'Array params did not return -32602' }
$results.invalid_params = 'passed'

$notification = Invoke-RpcRequest '{"jsonrpc":"2.0","method":"dc.ping","params":{}}' 4
if ([int]$notification.error.code -ne -32600 -or $null -ne $notification.id) {
    throw 'Notification without id did not return an id:null -32600 response'
}
$results.notification_rejected = 'passed'

$unknown = Invoke-RpcRequest (New-Request 7 'dc.thisMethodDoesNotExist') 4
if ([int]$unknown.error.code -ne -32601) { throw 'Unknown method did not return -32601' }
$results.unknown_method = 'passed'

$guiException = Invoke-RpcRequest (New-Request 71 'dc.setViewMode' @{mode='not-a-view-mode'}) 4
if ([int]$guiException.error.code -ne -32602) { throw 'GUI method exception did not return -32602' }
$results.gui_exception = 'passed'

$timeout = Invoke-RpcRequest (New-Request 72 'test.waitForPreview' @{
    test_id = 'rpc-smoke-timeout-never-completes'
    require_draw = $false
} 50) 4
if ([int]$timeout.error.code -ne -32001) { throw 'Timed wait did not return -32001' }
$results.timeout = 'passed'

$uncorrelatedWait = Invoke-RpcRequest (New-Request 73 'thumbnail.waitForCompletion' @{}) 4
if ([int]$uncorrelatedWait.error.code -ne -32602) { throw 'Uncorrelated preview wait did not return -32602' }
$results.wait_requires_filter = 'passed'

$missingPlugin = Invoke-RpcRequest (New-Request 8 'plugin.getExports' @{name='definitely-not-loaded-rpc-smoke'}) 4
if ([int]$missingPlugin.error.code -ne -32002) { throw 'Missing plug-in did not return -32002' }
$results.plugin_absence = 'passed'

$recent = Invoke-RpcRequest (New-Request 9 'log.getRecent' @{limit=20})
if ($null -eq $recent.result.entries) { throw 'log.getRecent has no entries member' }
$results.logging = 'passed'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('doublecmd-rpc-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $processes = @()
    for ($index = 0; $index -lt $ConcurrentClients; $index++) {
        $outputPath = Join-Path $tempRoot ("client-$index.out")
        $errorPath = Join-Path $tempRoot ("client-$index.err")
        $requestPath = Join-Path $tempRoot ("client-$index.json")
        [IO.File]::WriteAllText($requestPath, (New-Request (100 + $index) 'dc.ping'), [Text.UTF8Encoding]::new($false))
        $processes += Start-Process -FilePath $clientPath -ArgumentList @(
            '--pid', $TargetPid, '--request-file', $requestPath
        ) -NoNewWindow -PassThru -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
    }
    foreach ($process in $processes) {
        if (-not $process.WaitForExit(15000)) {
            try { $process.Kill() } catch {}
            throw "Concurrent client $($process.Id) timed out"
        }
        if ($process.ExitCode -ne 0) {
            throw "Concurrent client $($process.Id) failed with $($process.ExitCode)"
        }
    }
    $results.concurrent_clients = "passed ($ConcurrentClients)"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

[pscustomobject]$results
