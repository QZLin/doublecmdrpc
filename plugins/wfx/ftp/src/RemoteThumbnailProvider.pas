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
  AReturnedNameCapacity: Integer; AReturnedBitmap: PWfxBitmapHandle;
  const AConnectionJson: UnicodeString = ''): Integer;
function RequestRemoteDirectoryIndex(const AProviderPath, AConfigPath,
  AConnectionJson, AAction, ADirectory, AVolumeId, ACatalogPath, ARequestId: UnicodeString;
  APluginNumber: Integer; ALogProc: TLogProcW): Boolean;
function ResumeRemoteDirectoryIndex(const AProviderPath, AConfigPath, AConnectionJson, ARequestId: UnicodeString;
  APluginNumber: Integer; ALogProc: TLogProcW): Boolean;
function GetRemoteDirectoryStatus(const AProviderPath, AConfigPath, ARequestId: UnicodeString;
  APluginNumber: Integer; ALogProc: TLogProcW): UnicodeString;
function ConfigureRemoteThumbnailProvider(const AProviderPath, AConfigPath: UnicodeString;
  APluginNumber: Integer; ALogProc: TLogProcW; AParent: THandle): Integer;
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
  TProviderGetConnectionPreviewW = function(ConnectionJson, VolumeId, CatalogFilePath: PWideChar;
    Width, Height: Integer; ReturnedName: PWideChar; ReturnedNameCapacity: Integer;
    ReturnedBitmap: PWfxBitmapHandle): Integer; stdcall;
  TProviderDirectoryRequestW = function(ConnectionJson, Action, Directory, VolumeId,
    CatalogPath, RequestId: PWideChar): Integer; stdcall;
  TProviderDirectoryResumeW = function(ConnectionJson, RequestId: PWideChar): Integer; stdcall;
  TProviderDirectoryStatusW = function(RequestId, ReturnedJson: PWideChar; Capacity: Integer): Integer; stdcall;
  TProviderConfigureW = function(Parent: THandle): Integer; stdcall;

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
  ProviderConnectionPreview: TProviderGetConnectionPreviewW = nil;
  ProviderDirectoryRequest: TProviderDirectoryRequestW = nil;
  ProviderDirectoryResume: TProviderDirectoryResumeW = nil;
  ProviderDirectoryStatus: TProviderDirectoryStatusW = nil;
  ProviderConfigure: TProviderConfigureW = nil;
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
  ProviderConnectionPreview:= nil;
  ProviderDirectoryRequest:= nil;
  ProviderDirectoryResume:= nil;
  ProviderDirectoryStatus:= nil;
  ProviderConfigure:= nil;
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
  Pointer(ProviderConnectionPreview):= GetProcAddress(ProviderModule, 'RemoteThumbnailProviderGetPreviewForConnectionW');
  Pointer(ProviderDirectoryRequest):= GetProcAddress(ProviderModule, 'RemoteThumbnailProviderDirectoryRequestW');
  Pointer(ProviderDirectoryResume):= GetProcAddress(ProviderModule, 'RemoteThumbnailProviderDirectoryResumeW');
  Pointer(ProviderDirectoryStatus):= GetProcAddress(ProviderModule, 'RemoteThumbnailProviderDirectoryStatusW');
  Pointer(ProviderConfigure):= GetProcAddress(ProviderModule, 'RemoteThumbnailProviderConfigureW');
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
  AReturnedNameCapacity: Integer; AReturnedBitmap: PWfxBitmapHandle;
  const AConnectionJson: UnicodeString): Integer;
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
      if AConnectionJson <> '' then
      begin
        if not Assigned(ProviderConnectionPreview) then
        begin
          ReportError(ALogProc, APluginNumber, 'upgrade provider for connection-isolated thumbnail previews');
          Exit;
        end;
        Result:= ProviderConnectionPreview(PWideChar(AConnectionJson), PWideChar(AVolumeId),
          PWideChar(ACatalogPath), AWidth, AHeight, AReturnedName, AReturnedNameCapacity, AReturnedBitmap);
      end
      else Result:= ProviderGetPreview(PWideChar(AVolumeId), PWideChar(ACatalogPath),
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

function RequestRemoteDirectoryIndex(const AProviderPath, AConfigPath,
  AConnectionJson, AAction, ADirectory, AVolumeId, ACatalogPath, ARequestId: UnicodeString;
  APluginNumber: Integer; ALogProc: TLogProcW): Boolean;
begin
  Result:= False;
  {$IFDEF MSWINDOWS}
  ProviderLock.Acquire;
  try
    if not EnsureProvider(AProviderPath, AConfigPath, APluginNumber, ALogProc) then Exit;
    if not Assigned(ProviderDirectoryRequest) then
    begin
      ReportError(ALogProc, APluginNumber, 'upgrade provider to enable directory index control');
      Exit;
    end;
    try
      Result:= ProviderDirectoryRequest(PWideChar(AConnectionJson), PWideChar(AAction),
        PWideChar(ADirectory), PWideChar(AVolumeId), PWideChar(ACatalogPath), PWideChar(ARequestId)) = 1;
    except
      on E: Exception do ReportError(ALogProc, APluginNumber, UnicodeString(E.Message));
    end;
  finally
    ProviderLock.Release;
  end;
  {$ENDIF}
end;

function ResumeRemoteDirectoryIndex(const AProviderPath, AConfigPath, AConnectionJson, ARequestId: UnicodeString;
  APluginNumber: Integer; ALogProc: TLogProcW): Boolean;
begin
  Result:= False;
  {$IFDEF MSWINDOWS}
  ProviderLock.Acquire;
  try
    if not EnsureProvider(AProviderPath, AConfigPath, APluginNumber, ALogProc) then Exit;
    if not Assigned(ProviderDirectoryResume) then
    begin
      ReportError(ALogProc, APluginNumber, 'upgrade provider for read-only original-request recovery');
      Exit;
    end;
    try
      Result:= ProviderDirectoryResume(PWideChar(AConnectionJson), PWideChar(ARequestId)) = 1;
    except
      on E: Exception do ReportError(ALogProc, APluginNumber, UnicodeString(E.Message));
    end;
  finally
    ProviderLock.Release;
  end;
  {$ENDIF}
end;

function GetRemoteDirectoryStatus(const AProviderPath, AConfigPath, ARequestId: UnicodeString;
  APluginNumber: Integer; ALogProc: TLogProcW): UnicodeString;
{$IFDEF MSWINDOWS}
var Buffer: array[0..65535] of WideChar;
{$ENDIF}
begin
  Result:= '{"ok":false,"status":"unavailable"}';
  {$IFDEF MSWINDOWS}
  ProviderLock.Acquire;
  try
    if not EnsureProvider(AProviderPath, AConfigPath, APluginNumber, ALogProc) or
       not Assigned(ProviderDirectoryStatus) then Exit;
    FillChar(Buffer, SizeOf(Buffer), 0);
    if ProviderDirectoryStatus(PWideChar(ARequestId), @Buffer[0], Length(Buffer)) = 1 then
      Result:= UnicodeString(PWideChar(@Buffer[0]));
  finally
    ProviderLock.Release;
  end;
  {$ENDIF}
end;

function ConfigureRemoteThumbnailProvider(const AProviderPath, AConfigPath: UnicodeString;
  APluginNumber: Integer; ALogProc: TLogProcW; AParent: THandle): Integer;
begin
  Result:= FS_EXEC_ERROR;
  {$IFDEF MSWINDOWS}
  ProviderLock.Acquire;
  try
    if EnsureProvider(AProviderPath, AConfigPath, APluginNumber, ALogProc) and Assigned(ProviderConfigure) then
      Result:= ProviderConfigure(AParent);
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
  { Worker shutdown must happen through FsContentPluginUnloading before the
    FTP DLL enters loader-lock finalization. Never join a thread here. }
  FreeAndNil(ProviderLock);
  {$ENDIF}

end.
