unit uDebugRpcDiagnostics;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

function DebugRpcBeginPreview(const APath: String): QWord;
procedure DebugRpcEndPreview(const APath, AResult, AError: String;
  ADurationMs: QWord = 0);
procedure DebugRpcRecord(const AComponent, AOperation, APath, AResult,
  AError: String; ADurationMs: QWord = 0; ACode: Int64 = 0;
  const ADetail: String = ''; const APhotoUuid: String = '');
procedure DebugRpcRecordPluginLog(AMessageType: Integer; const AMessage: String);
procedure DebugRpcRegisterTest(const ATestId, APath, APhotoUuid: String);
procedure DebugRpcClearTest(const ATestId: String);
function DebugRpcGetStats(const ATestId, APath, APhotoUuid: String): TJSONObject;
function DebugRpcGetEvents(const ATestId, APath, APhotoUuid,
  AComponent: String; ALimit: Integer; AErrorsOnly: Boolean = False): TJSONArray;
function DebugRpcGetPending(const ATestId, APath, APhotoUuid: String): TJSONArray;
function DebugRpcGetCompletionState(const ATestId, APath, APhotoUuid: String;
  ARequireDraw: Boolean; out ASource, AError: String): String;
function DebugRpcCurrentCallId: QWord;
function DebugRpcCurrentTestId: String;

implementation

uses
  Contnrs, SyncObjs, DateUtils, StrUtils, uDebugRpcLogger;

const
  MaxDiagnosticEvents = 8192;
  MaxTestRegistrations = 2048;
  DiagnosticsPrefix = 'RemoteThumbnailWFX.Diagnostics ';

type
  { TDebugRpcDiagnosticEvent }

  TDebugRpcDiagnosticEvent = class
  public
    Sequence: QWord;
    Timestamp: String;
    TestId: String;
    CallId: QWord;
    Component: String;
    Operation: String;
    Path: String;
    PhotoUuid: String;
    ResultText: String;
    ErrorText: String;
    Detail: String;
    DurationMs: QWord;
    Code: Int64;
    function ToJson: TJSONObject;
  end;

  { TDebugRpcTestRegistration }

  TDebugRpcTestRegistration = class
  public
    TestId: String;
    Path: String;
    PhotoUuid: String;
  end;

  { TTimingAccumulator }

  TTimingAccumulator = record
    Count: Int64;
    Total: QWord;
    Maximum: QWord;
  end;

var
  DiagnosticLock: TCriticalSection;
  DiagnosticEvents: TObjectList;
  TestRegistrations: TObjectList;
  NextSequence: QWord = 0;
  NextCallId: QWord = 0;

threadvar
  CurrentCallId: QWord;
  CurrentTestId: String;
  CurrentPath: String;
  CurrentPhotoUuid: String;
  CurrentPreviewSource: String;

function TimestampNow: String;
begin
  Result:= DateToISO8601(LocalTimeToUniversal(Now), True);
end;

function TDebugRpcDiagnosticEvent.ToJson: TJSONObject;
begin
  Result:= TJSONObject.Create;
  Result.Add('sequence', Int64(Sequence));
  Result.Add('timestamp', Timestamp);
  Result.Add('test_id', TestId);
  Result.Add('call_id', Int64(CallId));
  Result.Add('component', Component);
  Result.Add('operation', Operation);
  Result.Add('path', Path);
  Result.Add('photo_uuid', PhotoUuid);
  Result.Add('duration_ms', Int64(DurationMs));
  Result.Add('result', ResultText);
  Result.Add('error', ErrorText);
  Result.Add('code', Code);
  if Detail <> EmptyStr then Result.Add('detail', Detail);
end;

function PathMatches(const ARegisteredPath, APath: String): Boolean;
var
  PrefixLength: Integer;
begin
  if (ARegisteredPath = EmptyStr) or (APath = EmptyStr) then Exit(False);
  if ARegisteredPath = APath then Exit(True);
  PrefixLength:= Length(ARegisteredPath);
  Result:= (Length(APath) > PrefixLength) and
    (Copy(APath, 1, PrefixLength) = ARegisteredPath) and
    ((ARegisteredPath[PrefixLength] in ['\', '/']) or
     (APath[PrefixLength + 1] in ['\', '/']));
end;

procedure ResolveRegistrationLocked(const APath: String; out ATestId,
  APhotoUuid: String);
var
  Index, BestLength: Integer;
  Registration: TDebugRpcTestRegistration;
begin
  ATestId:= EmptyStr;
  APhotoUuid:= EmptyStr;
  BestLength:= -1;
  for Index:= 0 to TestRegistrations.Count - 1 do
  begin
    Registration:= TDebugRpcTestRegistration(TestRegistrations[Index]);
    if PathMatches(Registration.Path, APath) and
       (Length(Registration.Path) >= BestLength) then
    begin
      ATestId:= Registration.TestId;
      APhotoUuid:= Registration.PhotoUuid;
      BestLength:= Length(Registration.Path);
    end;
  end;
end;

function FindLatestCallLocked(const APath: String): QWord;
var
  Index: Integer;
  Event: TDebugRpcDiagnosticEvent;
begin
  Result:= 0;
  if APath = EmptyStr then Exit;
  for Index:= DiagnosticEvents.Count - 1 downto 0 do
  begin
    Event:= TDebugRpcDiagnosticEvent(DiagnosticEvents[Index]);
    if (Event.Path = APath) and (Event.CallId <> 0) then Exit(Event.CallId);
  end;
end;

procedure AddEventLocked(AEvent: TDebugRpcDiagnosticEvent);
begin
  Inc(NextSequence);
  AEvent.Sequence:= NextSequence;
  DiagnosticEvents.Add(AEvent);
  while DiagnosticEvents.Count > MaxDiagnosticEvents do DiagnosticEvents.Delete(0);
end;

procedure DebugRpcRecord(const AComponent, AOperation, APath, AResult,
  AError: String; ADurationMs: QWord; ACode: Int64; const ADetail,
  APhotoUuid: String);
var
  Event: TDebugRpcDiagnosticEvent;
  EffectivePath, EffectiveTest, EffectiveUuid, RegisteredUuid: String;
  EffectiveCall: QWord;
begin
  EffectivePath:= APath;
  if EffectivePath = EmptyStr then EffectivePath:= CurrentPath;
  EffectiveCall:= CurrentCallId;
  EffectiveTest:= CurrentTestId;
  EffectiveUuid:= CurrentPhotoUuid;
  if APhotoUuid <> EmptyStr then EffectiveUuid:= APhotoUuid;
  if (AComponent = 'thumbnail') and (AOperation = 'host.receive') and
     (AResult <> EmptyStr) then CurrentPreviewSource:= AResult
  else if (AComponent = 'thumbnail') and (AOperation = 'cache.hit') then
    CurrentPreviewSource:= 'host_native_cache';

  Event:= TDebugRpcDiagnosticEvent.Create;
  Event.Timestamp:= TimestampNow;
  Event.Component:= AComponent;
  Event.Operation:= AOperation;
  Event.Path:= EffectivePath;
  Event.ResultText:= AResult;
  Event.ErrorText:= AError;
  Event.Detail:= ADetail;
  Event.DurationMs:= ADurationMs;
  Event.Code:= ACode;

  DiagnosticLock.Acquire;
  try
    if EffectiveTest = EmptyStr then
    begin
      ResolveRegistrationLocked(EffectivePath, EffectiveTest, RegisteredUuid);
      if EffectiveUuid = EmptyStr then EffectiveUuid:= RegisteredUuid;
    end;
    if EffectiveCall = 0 then EffectiveCall:= FindLatestCallLocked(EffectivePath);
    Event.TestId:= EffectiveTest;
    Event.PhotoUuid:= EffectiveUuid;
    Event.CallId:= EffectiveCall;
    AddEventLocked(Event);
  finally
    DiagnosticLock.Release;
  end;

  DebugRpcLog(IntToStr(EffectiveCall), EffectiveTest, AComponent, AOperation,
    ADurationMs, AResult, AError, ADetail);
end;

function DebugRpcBeginPreview(const APath: String): QWord;
begin
  DiagnosticLock.Acquire;
  try
    Inc(NextCallId);
    Result:= NextCallId;
    ResolveRegistrationLocked(APath, CurrentTestId, CurrentPhotoUuid);
  finally
    DiagnosticLock.Release;
  end;
  CurrentCallId:= Result;
  CurrentPath:= APath;
  CurrentPreviewSource:= EmptyStr;
  DebugRpcRecord('thumbnail', 'preview.begin', APath, 'started', EmptyStr);
end;

procedure DebugRpcEndPreview(const APath, AResult, AError: String;
  ADurationMs: QWord);
var
  EffectiveResult: String;
begin
  EffectiveResult:= AResult;
  if (AError = EmptyStr) and (AResult <> 'miss') and
     (CurrentPreviewSource <> EmptyStr) then
    EffectiveResult:= CurrentPreviewSource;
  if AError <> EmptyStr then
    DebugRpcRecord('thumbnail', 'preview.error', APath, EffectiveResult, AError,
      ADurationMs)
  else if AResult = 'miss' then
    DebugRpcRecord('thumbnail', 'preview.miss', APath, AResult, EmptyStr,
      ADurationMs)
  else
    DebugRpcRecord('thumbnail', 'preview.success', APath, EffectiveResult,
      EmptyStr, ADurationMs, 0, EffectiveResult);
  CurrentCallId:= 0;
  CurrentTestId:= EmptyStr;
  CurrentPath:= EmptyStr;
  CurrentPhotoUuid:= EmptyStr;
  CurrentPreviewSource:= EmptyStr;
end;

procedure UpdateRegistrationPhotoUuid(const ATestId, APath,
  APhotoUuid: String);
var
  Index: Integer;
  Registration: TDebugRpcTestRegistration;
begin
  if (ATestId = EmptyStr) or (APath = EmptyStr) or
     (APhotoUuid = EmptyStr) then Exit;
  DiagnosticLock.Acquire;
  try
    for Index:= TestRegistrations.Count - 1 downto 0 do
    begin
      Registration:= TDebugRpcTestRegistration(TestRegistrations[Index]);
      if (Registration.TestId = ATestId) and
         (Registration.Path = APath) then
      begin
        Registration.PhotoUuid:= APhotoUuid;
        Break;
      end;
    end;
  finally
    DiagnosticLock.Release;
  end;
end;

procedure DebugRpcRecordPluginLog(AMessageType: Integer;
  const AMessage: String);
var
  Payload, Operation, Detail, PhotoUuid: String;
  SpacePosition, MarkerPosition, EndPosition: Integer;
begin
  if StartsText(DiagnosticsPrefix, AMessage) then
  begin
    Payload:= Copy(AMessage, Length(DiagnosticsPrefix) + 1, MaxInt);
    SpacePosition:= Pos(' ', Payload);
    if SpacePosition > 0 then
    begin
      Operation:= Copy(Payload, 1, SpacePosition - 1);
      Detail:= Copy(Payload, SpacePosition + 1, MaxInt);
    end
    else begin
      Operation:= Payload;
      Detail:= EmptyStr;
    end;
    PhotoUuid:= EmptyStr;
    MarkerPosition:= Pos('photo_uuid=', Detail);
    if MarkerPosition > 0 then
    begin
      PhotoUuid:= Copy(Detail, MarkerPosition + Length('photo_uuid='), MaxInt);
      EndPosition:= Pos(' ', PhotoUuid);
      if EndPosition > 0 then SetLength(PhotoUuid, EndPosition - 1);
      if Operation = 'resolver.hit' then
      begin
        CurrentPhotoUuid:= PhotoUuid;
        UpdateRegistrationPhotoUuid(CurrentTestId, CurrentPath, PhotoUuid);
      end;
    end;
    DebugRpcRecord('wfx', Operation, EmptyStr, 'observed', EmptyStr, 0, 0,
      Detail, PhotoUuid);
  end
  else if AMessageType = 6 then
    DebugRpcRecord('wfx', 'plugin.error', EmptyStr, 'error', AMessage, 0,
      AMessageType);
end;

procedure DebugRpcRegisterTest(const ATestId, APath, APhotoUuid: String);
var
  Index: Integer;
  Registration: TDebugRpcTestRegistration;
begin
  if ATestId = EmptyStr then Exit;
  DiagnosticLock.Acquire;
  try
    for Index:= TestRegistrations.Count - 1 downto 0 do
    begin
      Registration:= TDebugRpcTestRegistration(TestRegistrations[Index]);
      if (Registration.TestId = ATestId) and (Registration.Path = APath) then
        TestRegistrations.Delete(Index);
    end;
    Registration:= TDebugRpcTestRegistration.Create;
    Registration.TestId:= ATestId;
    Registration.Path:= APath;
    Registration.PhotoUuid:= APhotoUuid;
    TestRegistrations.Add(Registration);
    while TestRegistrations.Count > MaxTestRegistrations do
      TestRegistrations.Delete(0);
  finally
    DiagnosticLock.Release;
  end;
  DebugRpcRecord('test', 'register', APath, 'registered', EmptyStr, 0, 0,
    ATestId);
end;

procedure DebugRpcClearTest(const ATestId: String);
var
  Index: Integer;
  Event: TDebugRpcDiagnosticEvent;
  Registration: TDebugRpcTestRegistration;
begin
  DiagnosticLock.Acquire;
  try
    for Index:= DiagnosticEvents.Count - 1 downto 0 do
    begin
      Event:= TDebugRpcDiagnosticEvent(DiagnosticEvents[Index]);
      if (ATestId = EmptyStr) or (Event.TestId = ATestId) then
        DiagnosticEvents.Delete(Index);
    end;
    for Index:= TestRegistrations.Count - 1 downto 0 do
    begin
      Registration:= TDebugRpcTestRegistration(TestRegistrations[Index]);
      if (ATestId = EmptyStr) or (Registration.TestId = ATestId) then
        TestRegistrations.Delete(Index);
    end;
  finally
    DiagnosticLock.Release;
  end;
end;

function EventMatches(AEvent: TDebugRpcDiagnosticEvent; const ATestId,
  APath, APhotoUuid, AComponent: String; AErrorsOnly: Boolean): Boolean;
begin
  Result:= ((ATestId = EmptyStr) or (AEvent.TestId = ATestId)) and
    ((APath = EmptyStr) or PathMatches(APath, AEvent.Path)) and
    ((APhotoUuid = EmptyStr) or (AEvent.PhotoUuid = APhotoUuid)) and
    ((AComponent = EmptyStr) or (AEvent.Component = AComponent)) and
    (not AErrorsOnly or (AEvent.ErrorText <> EmptyStr));
end;

procedure AddTiming(var AAccumulator: TTimingAccumulator; ADuration: QWord);
begin
  Inc(AAccumulator.Count);
  Inc(AAccumulator.Total, ADuration);
  if ADuration > AAccumulator.Maximum then AAccumulator.Maximum:= ADuration;
end;

function TimingJson(const AAccumulator: TTimingAccumulator): TJSONObject;
begin
  Result:= TJSONObject.Create;
  Result.Add('count', AAccumulator.Count);
  Result.Add('total_ms', Int64(AAccumulator.Total));
  Result.Add('max_ms', Int64(AAccumulator.Maximum));
  if AAccumulator.Count > 0 then
    Result.Add('average_ms', Double(AAccumulator.Total) / AAccumulator.Count)
  else
    Result.Add('average_ms', 0.0);
end;

function DebugRpcGetStats(const ATestId, APath,
  APhotoUuid: String): TJSONObject;
var
  Index: Integer;
  Event: TDebugRpcDiagnosticEvent;
  CallbackCalls, UnicodeCalls, AnsiCalls: Int64;
  ResolverQueries, ResolverHits, ResolverMisses: Int64;
  LocalCacheHits, LocalCacheMisses, SftpFetches: Int64;
  MissingFiles, InvalidFiles, HashMismatches: Int64;
  DecodeSuccesses, DecodeFailures, BitmapReturns, BitmapReturnFailures: Int64;
  HostReceives, UiDraws: Int64;
  Invalidations, Errors: Int64;
  CallbackTiming, DecodeTiming, TotalTiming: TTimingAccumulator;
  LatestError, LatestSource: String;
  Timings: TJSONObject;
begin
  CallbackCalls:= 0;
  UnicodeCalls:= 0;
  AnsiCalls:= 0;
  ResolverQueries:= 0;
  ResolverHits:= 0;
  ResolverMisses:= 0;
  LocalCacheHits:= 0;
  LocalCacheMisses:= 0;
  SftpFetches:= 0;
  MissingFiles:= 0;
  InvalidFiles:= 0;
  HashMismatches:= 0;
  DecodeSuccesses:= 0;
  DecodeFailures:= 0;
  BitmapReturns:= 0;
  BitmapReturnFailures:= 0;
  HostReceives:= 0;
  UiDraws:= 0;
  Invalidations:= 0;
  Errors:= 0;
  CallbackTiming:= Default(TTimingAccumulator);
  DecodeTiming:= Default(TTimingAccumulator);
  TotalTiming:= Default(TTimingAccumulator);
  LatestError:= EmptyStr;
  LatestSource:= EmptyStr;

  DiagnosticLock.Acquire;
  try
    for Index:= 0 to DiagnosticEvents.Count - 1 do
    begin
      Event:= TDebugRpcDiagnosticEvent(DiagnosticEvents[Index]);
      if not EventMatches(Event, ATestId, APath, APhotoUuid, EmptyStr, False) then
        Continue;
      if Event.ErrorText <> EmptyStr then
      begin
        Inc(Errors);
        LatestError:= Event.ErrorText;
      end;
      if (Event.Component = 'wfx') and (Event.Operation = 'callback') then
      begin
        Inc(CallbackCalls);
        AddTiming(CallbackTiming, Event.DurationMs);
        if Pos('FsGetPreviewBitmapW', Event.Detail) > 0 then Inc(UnicodeCalls)
        else if Pos('FsGetPreviewBitmap', Event.Detail) > 0 then Inc(AnsiCalls);
      end
      else if (Event.Component = 'wfx') and (Event.Operation = 'resolver.query') then Inc(ResolverQueries)
      else if (Event.Component = 'wfx') and (Event.Operation = 'resolver.hit') then Inc(ResolverHits)
      else if (Event.Component = 'wfx') and (Event.Operation = 'resolver.miss') then Inc(ResolverMisses)
      else if (Event.Component = 'wfx') and (Event.Operation = 'cache.hit') then Inc(LocalCacheHits)
      else if (Event.Component = 'wfx') and (Event.Operation = 'cache.miss') then
      begin
        Inc(LocalCacheMisses);
        if Pos('reason=missing_file', Event.Detail) > 0 then Inc(MissingFiles)
        else if Pos('reason=invalid_file', Event.Detail) > 0 then Inc(InvalidFiles)
        else if Pos('reason=hash_mismatch', Event.Detail) > 0 then Inc(HashMismatches);
      end
      else if (Event.Component = 'wfx') and (Event.Operation = 'sftp.fetch') then Inc(SftpFetches)
      else if (Event.Component = 'wfx') and (Event.Operation = 'bitmap.decode') then
      begin
        if Event.ErrorText = EmptyStr then Inc(DecodeSuccesses)
        else Inc(DecodeFailures);
        AddTiming(DecodeTiming, Event.DurationMs);
      end
      else if (Event.Component = 'wfx') and (Event.Operation = 'bitmap.return') then
      begin
        if Event.ErrorText = EmptyStr then Inc(BitmapReturns)
        else Inc(BitmapReturnFailures);
      end
      else if (Event.Component = 'thumbnail') and (Event.Operation = 'host.receive') then
      begin
        Inc(HostReceives);
        if Event.ResultText <> EmptyStr then LatestSource:= Event.ResultText;
      end
      else if (Event.Component = 'thumbnail') and (Event.Operation = 'cache.hit') then
        LatestSource:= 'host_native_cache'
      else if (Event.Component = 'thumbnail') and (Event.Operation = 'ui.draw') then Inc(UiDraws)
      else if (Event.Component = 'thumbnail') and (Event.Operation = 'invalidate') then Inc(Invalidations);
      if (Event.Component = 'thumbnail') and (Event.Operation = 'preview.success') then
      begin
        LatestSource:= Event.Detail;
        AddTiming(TotalTiming, Event.DurationMs);
      end
      else if (Event.Component = 'thumbnail') and
        ((Event.Operation = 'preview.error') or
         (Event.Operation = 'preview.miss')) then
        AddTiming(TotalTiming, Event.DurationMs);
    end;
  finally
    DiagnosticLock.Release;
  end;

  Result:= TJSONObject.Create;
  Result.Add('test_id', ATestId);
  Result.Add('path', APath);
  Result.Add('photo_uuid', APhotoUuid);
  Result.Add('fs_get_preview_bitmap_calls', CallbackCalls);
  Result.Add('unicode_calls', UnicodeCalls);
  Result.Add('ansi_calls', AnsiCalls);
  Result.Add('resolver_queries', ResolverQueries);
  Result.Add('resolver_hits', ResolverHits);
  Result.Add('resolver_misses', ResolverMisses);
  Result.Add('local_cache_hits', LocalCacheHits);
  Result.Add('local_cache_misses', LocalCacheMisses);
  Result.Add('webp_missing_files', MissingFiles);
  Result.Add('webp_invalid_files', InvalidFiles);
  Result.Add('webp_hash_mismatches', HashMismatches);
  Result.Add('sftp_thumbnail_fetches', SftpFetches);
  Result.Add('bitmap_decode_successes', DecodeSuccesses);
  Result.Add('bitmap_decode_failures', DecodeFailures);
  Result.Add('bitmap_returns', BitmapReturns);
  Result.Add('bitmap_return_failures', BitmapReturnFailures);
  Result.Add('host_receives', HostReceives);
  Result.Add('ui_draws', UiDraws);
  Result.Add('invalidations', Invalidations);
  Result.Add('error_count', Errors);
  Result.Add('latest_error', LatestError);
  Result.Add('latest_source', LatestSource);
  Timings:= TJSONObject.Create;
  Timings.Add('callback', TimingJson(CallbackTiming));
  Timings.Add('decode', TimingJson(DecodeTiming));
  Timings.Add('total', TimingJson(TotalTiming));
  Result.Add('timings', Timings);
end;

function DebugRpcGetEvents(const ATestId, APath, APhotoUuid,
  AComponent: String; ALimit: Integer; AErrorsOnly: Boolean): TJSONArray;
var
  Index, Added: Integer;
  Event: TDebugRpcDiagnosticEvent;
begin
  Result:= TJSONArray.Create;
  if ALimit < 1 then Exit;
  if ALimit > MaxDiagnosticEvents then ALimit:= MaxDiagnosticEvents;
  DiagnosticLock.Acquire;
  try
    Added:= 0;
    for Index:= DiagnosticEvents.Count - 1 downto 0 do
    begin
      Event:= TDebugRpcDiagnosticEvent(DiagnosticEvents[Index]);
      if not EventMatches(Event, ATestId, APath, APhotoUuid, AComponent,
        AErrorsOnly) then Continue;
      Result.Add(Event.ToJson);
      Inc(Added);
      if Added >= ALimit then Break;
    end;
  finally
    DiagnosticLock.Release;
  end;
end;

function DebugRpcGetPending(const ATestId, APath,
  APhotoUuid: String): TJSONArray;
var
  Index, StateIndex: Integer;
  Event: TDebugRpcDiagnosticEvent;
  States: TStringList;
  State: PtrInt;
  Item: TJSONObject;
begin
  Result:= TJSONArray.Create;
  States:= TStringList.Create;
  try
    States.Sorted:= True;
    States.CaseSensitive:= True;
    DiagnosticLock.Acquire;
    try
      for Index:= 0 to DiagnosticEvents.Count - 1 do
      begin
        Event:= TDebugRpcDiagnosticEvent(DiagnosticEvents[Index]);
        if not EventMatches(Event, ATestId, APath, APhotoUuid, EmptyStr, False) or
           (Event.Path = EmptyStr) then Continue;
        State:= 0;
        if (Event.Component = 'thumbnail') and
           ((Event.Operation = 'preview.begin') or
            (Event.Operation = 'preview.miss')) then State:= 1
        else if (Event.Component = 'thumbnail') and
          ((Event.Operation = 'preview.success') or
           (Event.Operation = 'ui.draw')) then State:= 2
        else if Event.ErrorText <> EmptyStr then State:= 3;
        if State = 0 then Continue;
        StateIndex:= States.IndexOf(Event.Path);
        if StateIndex < 0 then
          States.AddObject(Event.Path, TObject(State))
        else
          States.Objects[StateIndex]:= TObject(State);
      end;
    finally
      DiagnosticLock.Release;
    end;
    for Index:= 0 to States.Count - 1 do
    begin
      if PtrInt(States.Objects[Index]) <> 1 then Continue;
      Item:= TJSONObject.Create;
      Item.Add('path', States[Index]);
      Item.Add('state', 'pending');
      Result.Add(Item);
    end;
  finally
    States.Free;
  end;
end;

function DebugRpcGetCompletionState(const ATestId, APath,
  APhotoUuid: String; ARequireDraw: Boolean; out ASource, AError: String): String;
var
  Index: Integer;
  Event: TDebugRpcDiagnosticEvent;
  Started, Succeeded, Drawn: Boolean;
begin
  ASource:= EmptyStr;
  AError:= EmptyStr;
  Started:= False;
  Succeeded:= False;
  Drawn:= False;
  DiagnosticLock.Acquire;
  try
    for Index:= 0 to DiagnosticEvents.Count - 1 do
    begin
      Event:= TDebugRpcDiagnosticEvent(DiagnosticEvents[Index]);
      if not EventMatches(Event, ATestId, APath, APhotoUuid, EmptyStr, False) then Continue;
      if Event.Operation = 'preview.begin' then
      begin
        Started:= True;
        Succeeded:= False;
        Drawn:= False;
        ASource:= EmptyStr;
        AError:= EmptyStr;
      end;
      if (Event.Component = 'thumbnail') and (Event.Operation = 'preview.success') then
      begin
        Succeeded:= True;
        ASource:= Event.Detail;
        AError:= EmptyStr;
      end;
      if (Event.Component = 'thumbnail') and (Event.Operation = 'ui.draw') then
        Drawn:= True;
      if Started and (Event.ErrorText <> EmptyStr) then
        AError:= Event.ErrorText;
    end;
  finally
    DiagnosticLock.Release;
  end;
  if AError <> EmptyStr then Exit('error');
  if Succeeded and (not ARequireDraw or Drawn) then Exit('completed');
  if Started then Exit('pending');
  Result:= 'not_started';
end;

function DebugRpcCurrentCallId: QWord;
begin
  Result:= CurrentCallId;
end;

function DebugRpcCurrentTestId: String;
begin
  Result:= CurrentTestId;
end;

initialization
  DiagnosticLock:= TCriticalSection.Create;
  DiagnosticEvents:= TObjectList.Create(True);
  TestRegistrations:= TObjectList.Create(True);

finalization
  FreeAndNil(TestRegistrations);
  FreeAndNil(DiagnosticEvents);
  FreeAndNil(DiagnosticLock);

end.
