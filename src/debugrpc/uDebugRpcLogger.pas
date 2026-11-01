unit uDebugRpcLogger;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson;

procedure InitializeDebugRpcLogger(const AFileName: String);
procedure FinalizeDebugRpcLogger;
procedure DebugRpcLog(const ARequestId, ATestId, AComponent, AOperation: String;
  ADurationMs: QWord; const AResult, AError: String; const ADetail: String = '');
function DebugRpcGetRecentLogs(ALimit: Integer; const ATestId: String = ''): TJSONArray;
function DebugRpcLogFileName: String;

implementation

uses
  DateUtils, jsonparser;

const
  MaxMemoryLogEntries = 2048;

type
  { TDebugRpcJsonlLogger }

  TDebugRpcJsonlLogger = class
  private
    FLock: TCriticalSection;
    FLines: TStringList;
    FFileName: String;
    FStream: TFileStream;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(const AFileName: String);
    procedure WriteEntry(const ARequestId, ATestId, AComponent, AOperation: String;
      ADurationMs: QWord; const AResult, AError, ADetail: String);
    function Recent(ALimit: Integer; const ATestId: String): TJSONArray;
    property FileName: String read FFileName;
  end;

var
  Logger: TDebugRpcJsonlLogger = nil;
  LoggerGuard: TRTLCriticalSection;

function UtcTimestamp: String;
begin
  Result:= DateToISO8601(LocalTimeToUniversal(Now), True);
end;

constructor TDebugRpcJsonlLogger.Create;
begin
  inherited Create;
  FLock:= TCriticalSection.Create;
  FLines:= TStringList.Create;
end;

destructor TDebugRpcJsonlLogger.Destroy;
begin
  FLock.Acquire;
  try
    FreeAndNil(FStream);
  finally
    FLock.Release;
  end;
  FreeAndNil(FLines);
  FreeAndNil(FLock);
  inherited Destroy;
end;

procedure TDebugRpcJsonlLogger.Configure(const AFileName: String);
var
  DirectoryName: String;
begin
  FLock.Acquire;
  try
    if FFileName = AFileName then Exit;
    FreeAndNil(FStream);
    FFileName:= AFileName;
    if FFileName = EmptyStr then Exit;
    DirectoryName:= ExtractFileDir(FFileName);
    if (DirectoryName <> EmptyStr) and not DirectoryExists(DirectoryName) then
      ForceDirectories(DirectoryName);
    if FileExists(FFileName) then
      FStream:= TFileStream.Create(FFileName, fmOpenReadWrite or fmShareDenyWrite)
    else
      FStream:= TFileStream.Create(FFileName, fmCreate or fmShareDenyWrite);
    FStream.Position:= FStream.Size;
  finally
    FLock.Release;
  end;
end;

procedure TDebugRpcJsonlLogger.WriteEntry(const ARequestId, ATestId,
  AComponent, AOperation: String; ADurationMs: QWord; const AResult, AError,
  ADetail: String);
var
  Entry: TJSONObject;
  Encoded: UTF8String;
begin
  Entry:= TJSONObject.Create;
  try
    Entry.Add('timestamp', UtcTimestamp);
    Entry.Add('request_id', ARequestId);
    Entry.Add('test_id', ATestId);
    Entry.Add('component', AComponent);
    Entry.Add('operation', AOperation);
    Entry.Add('duration_ms', Int64(ADurationMs));
    Entry.Add('result', AResult);
    Entry.Add('error', AError);
    if ADetail <> EmptyStr then Entry.Add('detail', ADetail);
    Entry.Add('thread_id', Int64(GetCurrentThreadId));
    Encoded:= UTF8String(Entry.AsJSON + LineEnding);
  finally
    Entry.Free;
  end;

  FLock.Acquire;
  try
    FLines.Add(String(Encoded));
    while FLines.Count > MaxMemoryLogEntries do FLines.Delete(0);
    if Assigned(FStream) and (Length(Encoded) > 0) then
    begin
      FStream.WriteBuffer(Encoded[1], Length(Encoded));
      FStream.Position:= FStream.Size;
    end;
  finally
    FLock.Release;
  end;
end;

function TDebugRpcJsonlLogger.Recent(ALimit: Integer;
  const ATestId: String): TJSONArray;
var
  Index, Added: Integer;
  Data: TJSONData;
  Entry: TJSONObject;
  Line: String;
begin
  Result:= TJSONArray.Create;
  if ALimit < 1 then Exit;
  if ALimit > MaxMemoryLogEntries then ALimit:= MaxMemoryLogEntries;
  FLock.Acquire;
  try
    Added:= 0;
    for Index:= FLines.Count - 1 downto 0 do
    begin
      Line:= TrimRight(FLines[Index]);
      try
        Data:= GetJSON(Line, True);
      except
        Continue;
      end;
      if not (Data is TJSONObject) then
      begin
        Data.Free;
        Continue;
      end;
      Entry:= TJSONObject(Data);
      if (ATestId <> EmptyStr) and
         (Entry.Get('test_id', EmptyStr) <> ATestId) then
      begin
        Entry.Free;
        Continue;
      end;
      Result.Add(Entry);
      Inc(Added);
      if Added >= ALimit then Break;
    end;
  finally
    FLock.Release;
  end;
end;

procedure InitializeDebugRpcLogger(const AFileName: String);
begin
  EnterCriticalSection(LoggerGuard);
  try
    if not Assigned(Logger) then Logger:= TDebugRpcJsonlLogger.Create;
    Logger.Configure(AFileName);
  finally
    LeaveCriticalSection(LoggerGuard);
  end;
end;

procedure FinalizeDebugRpcLogger;
begin
  EnterCriticalSection(LoggerGuard);
  try
    FreeAndNil(Logger);
  finally
    LeaveCriticalSection(LoggerGuard);
  end;
end;

procedure DebugRpcLog(const ARequestId, ATestId, AComponent,
  AOperation: String; ADurationMs: QWord; const AResult, AError: String;
  const ADetail: String);
var
  Current: TDebugRpcJsonlLogger;
begin
  EnterCriticalSection(LoggerGuard);
  try
    Current:= Logger;
    if Assigned(Current) then
      Current.WriteEntry(ARequestId, ATestId, AComponent, AOperation,
        ADurationMs, AResult, AError, ADetail);
  finally
    LeaveCriticalSection(LoggerGuard);
  end;
end;

function DebugRpcGetRecentLogs(ALimit: Integer;
  const ATestId: String): TJSONArray;
begin
  EnterCriticalSection(LoggerGuard);
  try
    if Assigned(Logger) then
      Result:= Logger.Recent(ALimit, ATestId)
    else
      Result:= TJSONArray.Create;
  finally
    LeaveCriticalSection(LoggerGuard);
  end;
end;

function DebugRpcLogFileName: String;
begin
  EnterCriticalSection(LoggerGuard);
  try
    if Assigned(Logger) then Result:= Logger.FileName else Result:= EmptyStr;
  finally
    LeaveCriticalSection(LoggerGuard);
  end;
end;

initialization
  InitCriticalSection(LoggerGuard);

finalization
  FinalizeDebugRpcLogger;
  DoneCriticalSection(LoggerGuard);

end.
