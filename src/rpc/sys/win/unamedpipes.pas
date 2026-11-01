unit uNamedPipes;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  PTrustee = ^TTrustee;
  TTrustee = record
    pMultipleTrustee: PTrustee;
    MultipleTrusteeOperation: DWORD;
    TrusteeForm: DWORD;
    TrusteeType: DWORD;
    ptstrName: PAnsiChar;
  end;

  TExplicitAccess = record
    grfAccessPermissions: DWORD;
    grfAccessMode: DWORD;
    grfInheritance: DWORD;
    Trustee: TTrustee;
  end;

function VerifyChild(hPipe: THandle): Boolean;
function VerifyParent(hPipe: THandle): Boolean;
function VerifySameUser(hPipe: THandle): Boolean;
function GetAdministratorsSID(out SID: TBytes): Boolean;

implementation

uses
  Windows, uProcessInfo, uDebug;

var
  GetNamedPipeClientProcessId: function(Pipe: HANDLE; ClientProcessId: PULONG): BOOL; stdcall;

function VerifyChild(hPipe: HANDLE): Boolean;
var
  ClientProcessId: ULONG;
begin
  if GetNamedPipeClientProcessId(hPipe, @ClientProcessId) then
  begin
    // Allow to connect from child process and same executable only
    if GetCurrentProcessId = GetParentProcessId(ClientProcessId) then
    begin
      DCDebug('My: ', GetProcessFileName(GetCurrentProcess));
      DCDebug('Client: ', GetProcessFileNameEx(ClientProcessId));

      if UnicodeSameText(GetProcessFileName(GetCurrentProcess), GetProcessFileNameEx(ClientProcessId)) then
        Exit(True);
    end;
  end;
  Result:= False;
end;

function VerifyParent(hPipe: HANDLE): Boolean;
var
  ClientProcessId: ULONG;
begin
  if GetNamedPipeClientProcessId(hPipe, @ClientProcessId) then
  begin
    // Allow to connect from parent process and same executable only
    if ClientProcessId = GetParentProcessId(GetCurrentProcessId) then
    begin
      DCDebug('My: ', GetProcessFileName(GetCurrentProcess));
      DCDebug('Client: ', GetProcessFileNameEx(ClientProcessId));

      if UnicodeSameText(GetProcessFileName(GetCurrentProcess), GetProcessFileNameEx(ClientProcessId)) then
        Exit(True);
    end;
  end;
  Result:= False;
end;

function VerifySameUser(hPipe: THandle): Boolean;
const
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
var
  ClientProcessId: ULONG;
  ClientProcess: THandle;
  ServerSID, ClientSID: TBytes;
begin
  Result:= False;
  if not Assigned(GetNamedPipeClientProcessId) or
     not GetNamedPipeClientProcessId(hPipe, @ClientProcessId) then Exit;
  ClientProcess:= OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False,
    ClientProcessId);
  if ClientProcess = 0 then Exit;
  try
    if not GetProcessUserSID(GetCurrentProcess, ServerSID) or
       not GetProcessUserSID(ClientProcess, ClientSID) or
       (Length(ServerSID) = 0) or (Length(ClientSID) = 0) then Exit;
    Result:= EqualSid(PSID(@ServerSID[0]), PSID(@ClientSID[0]));
  finally
    CloseHandle(ClientProcess);
  end;
end;

function GetAdministratorsSID(out SID: TBytes): Boolean;
const
  SECURITY_NT_AUTHORITY: TSidIdentifierAuthority = (Value: (0, 0, 0, 0, 0, 5));
var
  AdministratorsGroup: PSID = nil;
begin
  Result:= AllocateAndInitializeSid(SECURITY_NT_AUTHORITY,
                                    2,
                                    SECURITY_BUILTIN_DOMAIN_RID,
                                    DOMAIN_ALIAS_RID_ADMINS,
                                    0, 0, 0, 0, 0, 0,
                                    AdministratorsGroup);
  if Result then
  begin
    SetLength(SID, GetLengthSid(AdministratorsGroup));
    CopySid(Length(SID), PSID(@SID[0]), AdministratorsGroup);
    FreeSid(AdministratorsGroup);
  end;
end;

initialization
  Pointer(GetNamedPipeClientProcessId):= GetProcAddress(GetModuleHandleW(kernel32),
                                                        'GetNamedPipeClientProcessId');

end.

