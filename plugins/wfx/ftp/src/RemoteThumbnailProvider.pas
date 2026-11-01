unit RemoteThumbnailProvider;

{$mode objfpc}{$H+}

interface

uses
  WfxPlugin;

type
  PWfxBitmapHandle = ^HBITMAP;

function GetRemoteThumbnailPreview(const AProviderPath, AConfigPath,
  AVolumeId, ACatalogPath: UnicodeString; APluginNumber: Integer;
  ALogProc: TLogProcW; AWidth, AHeight: Integer; AReturnedName: PWideChar;
  AReturnedNameCapacity: Integer; AReturnedBitmap: PWfxBitmapHandle): Integer;
procedure ShutdownRemoteThumbnailProvider;

implementation

uses
  SysUtils, SyncObjs
  {$IFDEF MSWINDOWS}, Windows{$ENDIF};

{$IFDEF MSWINDOWS}

type
  TProviderInitializeW = function(AbiVersion, PluginNumber: Integer;
    LogProc: TLogProcW; ConfigurationPath: PWideChar): Integer; stdcall;
  TProviderGetPreviewW = function(VolumeId, CatalogFilePath: PWideChar;
    Width, Height: Integer; ReturnedName: PWideChar;
    ReturnedNameCapacity: Integer; ReturnedBitmap: PWfxBitmapHandle): Integer; stdcall;
  TProviderShutdown = procedure; stdcall;

const
  ProviderAbiVersion = 1;
  ProviderFileName = 'RemoteThumbnailProvider.dll';
  ProviderRetryMilliseconds = 5000;

var
  ProviderLock: SyncObjs.TCriticalSection;
  ProviderModule: HMODULE = 0;
  ProviderInitialize: TProviderInitializeW = nil;
  ProviderGetPreview: TProviderGetPreviewW = nil;
  ProviderShutdown: TProviderShutdown = nil;
  LoadedProviderPath: UnicodeString = '';
  LoadedConfigPath: UnicodeString = '';
  LastError: UnicodeString = '';
  NextRetryAt: QWord = 0;

function ModuleDirectory: UnicodeString;
var
  Count: DWORD;
  Buffer: array[0..32767] of WideChar;
begin
  Result:= '';
  FillChar(Buffer, SizeOf(Buffer), 0);
  Count:= GetModuleFileNameW(HInstance, @Buffer[0], Length(Buffer));
  if (Count > 0) and (Count < DWORD(Length(Buffer))) then
    Result:= IncludeTrailingPathDelimiter(ExtractFilePath(UnicodeString(Buffer)));
end;

function IsAbsolutePath(const APath: UnicodeString): Boolean;
begin
  Result:= ((Length(APath) >= 3) and (APath[2] = ':') and
            (APath[3] in ['\', '/'])) or
           ((Length(APath) >= 2) and (APath[1] in ['\', '/']) and
            (APath[2] in ['\', '/']));
end;

function ResolvePath(const APath, ADefaultName: UnicodeString): UnicodeString;
var
  Candidate: UnicodeString;
begin
  Candidate:= Trim(APath);
  if Candidate = '' then Candidate:= ModuleDirectory + ADefaultName
  else if not IsAbsolutePath(Candidate) then Candidate:= ModuleDirectory + Candidate;
  Result:= Candidate;
end;

procedure ReportError(ALogProc: TLogProcW; APluginNumber: Integer;
  const AMessage: UnicodeString);
var
  MutableMessage: UnicodeString;
begin
  if AMessage = LastError then Exit;
  LastError:= AMessage;
  if Assigned(ALogProc) then
  begin
    MutableMessage:= 'RemoteThumbnail FTP provider: ' + AMessage;
    ALogProc(APluginNumber, msgtype_importanterror, PWideChar(MutableMessage));
  end;
end;

procedure ClearProvider;
begin
  if Assigned(ProviderShutdown) then
  begin
    try
      ProviderShutdown();
    except
      { Never let a provider failure escape plug-in unload/reconfiguration. }
    end;
  end;
  ProviderInitialize:= nil;
  ProviderGetPreview:= nil;
  ProviderShutdown:= nil;
  if ProviderModule <> 0 then FreeLibrary(ProviderModule);
  ProviderModule:= 0;
  LoadedProviderPath:= '';
  LoadedConfigPath:= '';
end;

function EnsureProvider(const AProviderPath, AConfigPath: UnicodeString;
  APluginNumber: Integer; ALogProc: TLogProcW): Boolean;
var
  ProviderPath, ConfigPath: UnicodeString;
  ConfigPointer: PWideChar;
begin
  Result:= False;
  ProviderPath:= ResolvePath(AProviderPath, ProviderFileName);
  if Trim(AConfigPath) = '' then ConfigPath:= ''
  else ConfigPath:= ResolvePath(AConfigPath, '');

  if (ProviderModule <> 0) and
     ((LoadedProviderPath <> ProviderPath) or
      (LoadedConfigPath <> ConfigPath)) then
    ClearProvider;

  if ProviderModule <> 0 then Exit(True);
  if GetTickCount64 < NextRetryAt then Exit(False);
  NextRetryAt:= GetTickCount64 + ProviderRetryMilliseconds;

  ProviderModule:= LoadLibraryW(PWideChar(ProviderPath));
  if ProviderModule = 0 then
  begin
    ReportError(ALogProc, APluginNumber,
      'cannot load ' + ProviderPath + ' (Win32 error ' +
      UnicodeString(IntToStr(GetLastError)) + ')');
    Exit;
  end;

  Pointer(ProviderInitialize):= GetProcAddress(ProviderModule,
    'RemoteThumbnailProviderInitializeW');
  Pointer(ProviderGetPreview):= GetProcAddress(ProviderModule,
    'RemoteThumbnailProviderGetPreviewW');
  Pointer(ProviderShutdown):= GetProcAddress(ProviderModule,
    'RemoteThumbnailProviderShutdown');
  if not Assigned(ProviderInitialize) or not Assigned(ProviderGetPreview) or
     not Assigned(ProviderShutdown) then
  begin
    ReportError(ALogProc, APluginNumber, 'provider ABI exports are missing');
    ClearProvider;
    Exit;
  end;

  if ConfigPath = '' then ConfigPointer:= nil
  else ConfigPointer:= PWideChar(ConfigPath);
  try
    if ProviderInitialize(ProviderAbiVersion, APluginNumber, ALogProc,
       ConfigPointer) <> ProviderAbiVersion then
    begin
      ReportError(ALogProc, APluginNumber, 'provider ABI initialization failed');
      ClearProvider;
      Exit;
    end;
  except
    on E: Exception do
    begin
      ReportError(ALogProc, APluginNumber,
        'provider initialization raised: ' + UnicodeString(E.Message));
      ClearProvider;
      Exit;
    end;
  end;

  LoadedProviderPath:= ProviderPath;
  LoadedConfigPath:= ConfigPath;
  LastError:= '';
  Result:= True;
end;

{$ENDIF}

function GetRemoteThumbnailPreview(const AProviderPath, AConfigPath,
  AVolumeId, ACatalogPath: UnicodeString; APluginNumber: Integer;
  ALogProc: TLogProcW; AWidth, AHeight: Integer; AReturnedName: PWideChar;
  AReturnedNameCapacity: Integer; AReturnedBitmap: PWfxBitmapHandle): Integer;
begin
  Result:= FS_BITMAP_NONE;
  if Assigned(AReturnedBitmap) then AReturnedBitmap^:= 0;
  {$IFDEF MSWINDOWS}
  if (AReturnedName = nil) or (AReturnedNameCapacity <= 0) or
     (AReturnedBitmap = nil) then Exit;
  ProviderLock.Acquire;
  try
    if not EnsureProvider(AProviderPath, AConfigPath, APluginNumber, ALogProc) then
      Exit;
    try
      Result:= ProviderGetPreview(PWideChar(AVolumeId), PWideChar(ACatalogPath),
        AWidth, AHeight, AReturnedName, AReturnedNameCapacity, AReturnedBitmap);
    except
      on E: Exception do
      begin
        ReportError(ALogProc, APluginNumber,
          'preview call raised: ' + UnicodeString(E.Message));
        Result:= FS_BITMAP_NONE;
        AReturnedBitmap^:= 0;
      end;
    end;
  finally
    ProviderLock.Release;
  end;
  {$ENDIF}
end;

procedure ShutdownRemoteThumbnailProvider;
begin
  {$IFDEF MSWINDOWS}
  ProviderLock.Acquire;
  try
    ClearProvider;
    LastError:= '';
    NextRetryAt:= 0;
  finally
    ProviderLock.Release;
  end;
  {$ENDIF}
end;

initialization
  {$IFDEF MSWINDOWS}
  ProviderLock:= SyncObjs.TCriticalSection.Create;
  {$ENDIF}

finalization
  {$IFDEF MSWINDOWS}
  ShutdownRemoteThumbnailProvider;
  FreeAndNil(ProviderLock);
  {$ENDIF}

end.
