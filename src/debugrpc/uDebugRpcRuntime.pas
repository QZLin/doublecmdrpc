unit uDebugRpcRuntime;

{$mode objfpc}{$H+}

interface

procedure DebugRpcSetRuntime(const APipeName: String; AEnabled: Boolean);
function DebugRpcRuntimePipeName: String;
function DebugRpcRuntimeEnabled: Boolean;
function DebugRpcRuntimeUptimeMs: QWord;

implementation

uses
  SysUtils, SyncObjs;

var
  RuntimeLock: TCriticalSection;
  RuntimePipeName: String = '';
  RuntimeEnabled: Boolean = False;
  RuntimeStartedAt: QWord = 0;

procedure DebugRpcSetRuntime(const APipeName: String; AEnabled: Boolean);
begin
  RuntimeLock.Acquire;
  try
    RuntimePipeName:= APipeName;
    RuntimeEnabled:= AEnabled;
    if AEnabled then RuntimeStartedAt:= GetTickCount64 else RuntimeStartedAt:= 0;
  finally
    RuntimeLock.Release;
  end;
end;

function DebugRpcRuntimePipeName: String;
begin
  RuntimeLock.Acquire;
  try
    Result:= RuntimePipeName;
  finally
    RuntimeLock.Release;
  end;
end;

function DebugRpcRuntimeEnabled: Boolean;
begin
  RuntimeLock.Acquire;
  try
    Result:= RuntimeEnabled;
  finally
    RuntimeLock.Release;
  end;
end;

function DebugRpcRuntimeUptimeMs: QWord;
begin
  RuntimeLock.Acquire;
  try
    if RuntimeEnabled then Result:= GetTickCount64 - RuntimeStartedAt else Result:= 0;
  finally
    RuntimeLock.Release;
  end;
end;

initialization
  RuntimeLock:= TCriticalSection.Create;

finalization
  FreeAndNil(RuntimeLock);

end.
