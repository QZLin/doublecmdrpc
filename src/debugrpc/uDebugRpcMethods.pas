unit uDebugRpcMethods;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson;

type
  { EDebugRpcMethodError }

  EDebugRpcMethodError = class(Exception)
  private
    FCode: Integer;
  public
    constructor Create(ACode: Integer; const AMessage: String);
    property Code: Integer read FCode;
  end;

  { TDebugRpcMethods }

  TDebugRpcMethods = class
  private
    procedure ExecuteQueued(Data: PtrInt);
    function ExecuteGuiMethod(const AMethod: String; AParams: TJSONData): TJSONData;
    function InvokeGui(const AMethod: String; AParams: TJSONData;
      ATimeoutMs: Cardinal): TJSONData;
    function WaitForIdle(AParams: TJSONData; ATimeoutMs: Cardinal): TJSONData;
    function WaitForPreview(AParams: TJSONData; ATimeoutMs: Cardinal;
      ARequireDrawDefault: Boolean): TJSONData;
    function BuildTestReport(AParams: TJSONData): TJSONData;
    function AssertPreviewSource(AParams: TJSONData): TJSONData;
  public
    destructor Destroy; override;
    function Execute(const AMethod: String; AParams: TJSONData;
      ATimeoutMs: Cardinal): TJSONData;
  end;

implementation

uses
  Forms, Controls, DynLibs, DateUtils, StrUtils, LCLType,
  fMain, uFilePanelSelect, uFileView, uFileViewNotebook, uFile, uFileSource,
  uColumnsFileView, uBriefFileView, uThumbFileView, uFileSourceUtil, uDCUtils,
  uGlobs, uDCVersion, uWfxModule, uWfxPluginFileSource,
  uDebugRpcDiagnostics, uDebugRpcLogger, uDebugRpcRuntime;

const
  RpcInvalidParams = -32602;
  RpcExecutionTimeout = -32001;
  RpcUnavailable = -32002;
  RpcAssertionFailed = -32010;
  MaxRpcStringLength = 32768;

type
  { TDebugRpcGuiCall }

  TDebugRpcGuiCall = class
  private
    FReferences: LongInt;
  public
    Lock: SyncObjs.TCriticalSection;
    Event: TEvent;
    Method: String;
    Params: TJSONData;
    ResultData: TJSONData;
    ErrorCode: Integer;
    ErrorMessage: String;
    Cancelled: Boolean;
    constructor Create(const AMethod: String; AParams: TJSONData);
    destructor Destroy; override;
    procedure Release;
  end;

constructor EDebugRpcMethodError.Create(ACode: Integer;
  const AMessage: String);
begin
  FCode:= ACode;
  inherited Create(AMessage);
end;

constructor TDebugRpcGuiCall.Create(const AMethod: String;
  AParams: TJSONData);
begin
  inherited Create;
  FReferences:= 2;
  Lock:= SyncObjs.TCriticalSection.Create;
  Event:= TEvent.Create(nil, True, False, EmptyStr);
  Method:= AMethod;
  if Assigned(AParams) then Params:= AParams.Clone;
end;

destructor TDebugRpcGuiCall.Destroy;
begin
  FreeAndNil(ResultData);
  FreeAndNil(Params);
  FreeAndNil(Event);
  FreeAndNil(Lock);
  inherited Destroy;
end;

procedure TDebugRpcGuiCall.Release;
begin
  if InterlockedDecrement(FReferences) = 0 then Free;
end;

function ParamsObject(AParams: TJSONData): TJSONObject;
begin
  if not Assigned(AParams) then Exit(nil);
  if not (AParams is TJSONObject) then
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'params must be a JSON object');
  Result:= TJSONObject(AParams);
end;

function FindValue(AObject: TJSONObject; const AName: String): TJSONData;
var
  Index: Integer;
begin
  Result:= nil;
  if not Assigned(AObject) then Exit;
  Index:= AObject.IndexOfName(AName);
  if Index >= 0 then Result:= AObject.Items[Index];
end;

function ParamString(AObject: TJSONObject; const AName,
  ADefault: String; ARequired: Boolean = False): String;
var
  Data: TJSONData;
begin
  Data:= FindValue(AObject, AName);
  if not Assigned(Data) then
  begin
    if ARequired then
      raise EDebugRpcMethodError.Create(RpcInvalidParams,
        'missing string parameter: ' + AName);
    Exit(ADefault);
  end;
  if Data.JSONType <> jtString then
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'parameter must be a string: ' + AName);
  Result:= Data.AsString;
  if Length(Result) > MaxRpcStringLength then
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'parameter is too long: ' + AName);
  if ARequired and (Result = EmptyStr) then
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'parameter cannot be empty: ' + AName);
end;

function ParamBool(AObject: TJSONObject; const AName: String;
  ADefault: Boolean): Boolean;
var
  Data: TJSONData;
begin
  Data:= FindValue(AObject, AName);
  if not Assigned(Data) then Exit(ADefault);
  if Data.JSONType <> jtBoolean then
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'parameter must be boolean: ' + AName);
  Result:= Data.AsBoolean;
end;

function ParamInt(AObject: TJSONObject; const AName: String;
  ADefault, AMinimum, AMaximum: Int64): Int64;
var
  Data: TJSONData;
begin
  Data:= FindValue(AObject, AName);
  if not Assigned(Data) then Exit(ADefault);
  if Data.JSONType <> jtNumber then
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'parameter must be a number: ' + AName);
  Result:= Data.AsInt64;
  if (Result < AMinimum) or (Result > AMaximum) then
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'parameter out of range: ' + AName);
end;

function PanelName(APanel: TFilePanelSelect): String;
begin
  case APanel of
    fpLeft: Result:= 'left';
    fpRight: Result:= 'right';
    else Result:= 'unknown';
  end;
end;

function ResolvePanel(AParams: TJSONObject; out APanel: TFilePanelSelect;
  AActivate: Boolean): TFileView;
var
  Requested: String;
begin
  if not Assigned(frmMain) then
    raise EDebugRpcMethodError.Create(RpcUnavailable,
      'Double Commander main form is unavailable');
  Requested:= LowerCase(ParamString(AParams, 'panel', 'active'));
  if Requested = 'active' then APanel:= frmMain.SelectedPanel
  else if Requested = 'left' then APanel:= fpLeft
  else if Requested = 'right' then APanel:= fpRight
  else
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'panel must be active, left, or right');
  if AActivate then frmMain.SetActiveFrame(APanel);
  case APanel of
    fpLeft: Result:= frmMain.FrameLeft;
    fpRight: Result:= frmMain.FrameRight;
    else Result:= nil;
  end;
  if not Assigned(Result) then
    raise EDebugRpcMethodError.Create(RpcUnavailable,
      'requested file panel is unavailable');
end;

function ResolveNotebook(APanel: TFilePanelSelect): TFileViewNotebook;
begin
  case APanel of
    fpLeft: Result:= frmMain.LeftTabs;
    fpRight: Result:= frmMain.RightTabs;
    else Result:= nil;
  end;
end;

function ViewMode(AView: TFileView): String;
begin
  if AView is TThumbFileView then Result:= 'thumbnails'
  else if AView is TBriefFileView then Result:= 'brief'
  else if AView is TColumnsFileView then Result:= 'details'
  else Result:= LowerCase(AView.ClassName);
end;

function FileJson(AFile: TFile): TJSONObject;
begin
  Result:= TJSONObject.Create;
  if not Assigned(AFile) then Exit;
  Result.Add('name', AFile.Name);
  Result.Add('path', AFile.Path);
  Result.Add('full_path', AFile.FullPath);
  Result.Add('is_directory', AFile.IsDirectory);
  Result.Add('size', AFile.Size);
end;

function PanelState(AView: TFileView; ANotebook: TFileViewNotebook;
  const APanelName: String): TJSONObject;
var
  ActiveFile: TFile;
  Selected: TFiles;
  SelectedArray: TJSONArray;
  Index: Integer;
  Stage: String;
  IsIdle: Boolean;
begin
  Result:= TJSONObject.Create;
  Stage:= 'panel';
  try
    Result.Add('panel', APanelName);
    Stage:= 'directory';
    Result.Add('directory', AView.CurrentPath);
    Stage:= 'real_directory';
    Result.Add('real_directory', AView.CurrentRealPath);
    Stage:= 'view_mode';
    Result.Add('view_mode', ViewMode(AView));
    Stage:= 'file_source';
    Result.Add('file_source', AView.FileSource.GetClassName);
    Stage:= 'preview_support';
    Result.Add('supports_preview_bitmap', AView.FileSource.SupportsPreviewBitmap);
    Stage:= 'idle';
    IsIdle:= AView.DebugIsIdle;
    Result.Add('directory_loading_status', IfThen(IsIdle, 'idle', 'loading'));
    Result.Add('idle', IsIdle);
    Stage:= 'notebook';
    if Assigned(ANotebook) then
    begin
      Result.Add('current_tab', ANotebook.PageIndex);
      Result.Add('tab_count', ANotebook.PageCount);
    end;
    Stage:= 'active_file';
    ActiveFile:= AView.CloneActiveFile;
    try
      if Assigned(ActiveFile) and ActiveFile.IsNameValid then
        Result.Add('selected_item', FileJson(ActiveFile))
      else
        Result.Add('selected_item', TJSONNull.Create);
    finally
      ActiveFile.Free;
    end;
    Stage:= 'selected_files';
    SelectedArray:= TJSONArray.Create;
    Result.Add('selected_files', SelectedArray);
    Selected:= AView.CloneSelectedFiles;
    try
      for Index:= 0 to Selected.Count - 1 do
        SelectedArray.Add(FileJson(Selected[Index]));
    finally
      Selected.Free;
    end;
  except
    on E: Exception do
    begin
      Result.Free;
      Result:= nil;
      raise Exception.CreateFmt('panel %s state failed at %s: %s',
        [APanelName, Stage, E.Message]);
    end;
  end;
end;

function DiagnosticFilter(AParams: TJSONObject; out ATestId, APath,
  APhotoUuid: String): Boolean;
begin
  ATestId:= ParamString(AParams, 'test_id', EmptyStr);
  APath:= ParamString(AParams, 'path', EmptyStr);
  if APath = EmptyStr then APath:= ParamString(AParams, 'remote_path', EmptyStr);
  APhotoUuid:= ParamString(AParams, 'photo_uuid', EmptyStr);
  Result:= (ATestId <> EmptyStr) or (APath <> EmptyStr) or
    (APhotoUuid <> EmptyStr);
end;

procedure TDebugRpcMethods.ExecuteQueued(Data: PtrInt);
var
  Call: TDebugRpcGuiCall;
  LocalResult: TJSONData;
  LocalErrorCode: Integer;
  LocalError: String;
  WasCancelled: Boolean;
begin
  Call:= TDebugRpcGuiCall(Data);
  LocalResult:= nil;
  LocalErrorCode:= 0;
  LocalError:= EmptyStr;
  WasCancelled:= False;
  Call.Lock.Acquire;
  try
    if Call.Cancelled then
    begin
      Call.Event.SetEvent;
      WasCancelled:= True;
    end;
  finally
    Call.Lock.Release;
  end;
  if WasCancelled then
  begin
    Call.Release;
    Exit;
  end;
  try
    LocalResult:= ExecuteGuiMethod(Call.Method, Call.Params);
  except
    on E: EDebugRpcMethodError do
    begin
      LocalErrorCode:= E.Code;
      LocalError:= E.Message;
    end;
    on E: Exception do
    begin
      LocalErrorCode:= -32603;
      LocalError:= E.Message;
    end;
  end;
  Call.Lock.Acquire;
  try
    if not Call.Cancelled then
    begin
      Call.ResultData:= LocalResult;
      LocalResult:= nil;
      Call.ErrorCode:= LocalErrorCode;
      Call.ErrorMessage:= LocalError;
    end;
    Call.Event.SetEvent;
  finally
    Call.Lock.Release;
    LocalResult.Free;
    Call.Release;
  end;
end;

function TDebugRpcMethods.InvokeGui(const AMethod: String; AParams: TJSONData;
  ATimeoutMs: Cardinal): TJSONData;
var
  Call: TDebugRpcGuiCall;
  WaitResult: TWaitResult;
  ErrorCode: Integer;
  ErrorMessage: String;
  Started, Elapsed: QWord;
  WaitSlice: Cardinal;
  Stopping: Boolean;
begin
  if GetCurrentThreadId = MainThreadID then
    Exit(ExecuteGuiMethod(AMethod, AParams));
  Call:= TDebugRpcGuiCall.Create(AMethod, AParams);
  Application.QueueAsyncCall(@ExecuteQueued, PtrInt(Call));
  Started:= GetTickCount64;
  Stopping:= False;
  repeat
    Elapsed:= GetTickCount64 - Started;
    if Elapsed >= ATimeoutMs then
    begin
      WaitResult:= wrTimeout;
      Break;
    end;
    WaitSlice:= ATimeoutMs - Cardinal(Elapsed);
    if WaitSlice > 50 then WaitSlice:= 50;
    WaitResult:= Call.Event.WaitFor(WaitSlice);
    if WaitResult = wrSignaled then Break;
    if not DebugRpcRuntimeEnabled then
    begin
      Stopping:= True;
      Break;
    end;
  until False;
  if WaitResult <> wrSignaled then
  begin
    Call.Lock.Acquire;
    try
      Call.Cancelled:= True;
    finally
      Call.Lock.Release;
    end;
    Call.Release;
    if Stopping then
      raise EDebugRpcMethodError.Create(RpcUnavailable,
        'RPC server is stopping')
    else
      raise EDebugRpcMethodError.Create(RpcExecutionTimeout,
        'GUI operation timed out');
  end;
  Call.Lock.Acquire;
  try
    Result:= Call.ResultData;
    Call.ResultData:= nil;
    ErrorCode:= Call.ErrorCode;
    ErrorMessage:= Call.ErrorMessage;
  finally
    Call.Lock.Release;
    Call.Release;
  end;
  if ErrorCode <> 0 then
  begin
    Result.Free;
    raise EDebugRpcMethodError.Create(ErrorCode, ErrorMessage);
  end;
end;

function TDebugRpcMethods.ExecuteGuiMethod(const AMethod: String;
  AParams: TJSONData): TJSONData;
var
  Params: TJSONObject;
  Obj, Panels, ExportMap, Entry: TJSONObject;
  Arr, FilesArray, PendingArray: TJSONArray;
  View, NewView: TFileView;
  Notebook: TFileViewNotebook;
  Page: TFileViewPage;
  Panel: TFilePanelSelect;
  Path, Mode, TestId, PhotoUuid, TargetPath, ModuleName: String;
  Files: TFiles;
  ActiveFile: TFile;
  Paths: TPathsArray;
  Index, ViewIndex, Invalidated: Integer;
  Module: TWfxModule;
  WfxSource: IWfxPluginFileSource;
  Pending: TStringArray;
  ExportName: String;
  Loaded, LeftIdle, RightIdle: Boolean;
  ConfigPath: String;
const
  KnownExports: array[0..31] of String = (
    'FsInit', 'FsInitW', 'FsFindFirst', 'FsFindFirstW', 'FsFindNext',
    'FsFindNextW', 'FsFindClose', 'FsGetFile', 'FsGetFileW', 'FsPutFile',
    'FsPutFileW', 'FsDisconnect', 'FsDisconnectW', 'FsGetDefRootName',
    'FsSetDefaultParams', 'FsGetBackgroundFlags', 'FsGetPreviewBitmap',
    'FsGetPreviewBitmapW', 'FsContentGetSupportedField', 'FsContentGetValue',
    'FsContentGetValueW', 'FsContentStopGetValue', 'FsContentStopGetValueW',
    'FsContentPluginUnloading', 'RemoteThumbnailDebugGetSnapshot',
    'RemoteThumbnailDebugGetEvents', 'RemoteThumbnailDebugReset',
    'RemoteThumbnailDebugSetTestId', 'FsExtractCustomIcon',
    'FsExtractCustomIconW', 'FsGetLocalName', 'FsGetLocalNameW');
begin
  Params:= ParamsObject(AParams);

  if AMethod = 'internal.wfxInfo' then
  begin
    View:= ResolvePanel(Params, Panel, False);
    Obj:= TJSONObject.Create;
    Obj.Add('panel', PanelName(Panel));
    if Supports(View.FileSource, IWfxPluginFileSource, WfxSource) then
    begin
      Obj.Add('is_wfx', True);
      Obj.Add('module_path', WfxSource.WfxModule.ModulePath);
      Obj.Add('unicode_preview_export_loaded',
        Assigned(WfxSource.WfxModule.FsGetPreviewBitmapW));
      Obj.Add('ansi_preview_export_loaded',
        Assigned(WfxSource.WfxModule.FsGetPreviewBitmap));
    end
    else begin
      Obj.Add('is_wfx', False);
      Obj.Add('unicode_preview_export_loaded', False);
      Obj.Add('ansi_preview_export_loaded', False);
    end;
    Exit(Obj);
  end;

  if AMethod = 'internal.isIdle' then
  begin
    LeftIdle:= frmMain.FrameLeft.DebugIsIdle;
    RightIdle:= frmMain.FrameRight.DebugIsIdle;
    Obj:= TJSONObject.Create;
    Obj.Add('left', LeftIdle);
    Obj.Add('right', RightIdle);
    Obj.Add('idle', LeftIdle and RightIdle);
    Exit(Obj);
  end;

  if AMethod = 'dc.getInfo' then
  begin
    Obj:= TJSONObject.Create;
    Obj.Add('name', 'Double Commander');
    Obj.Add('version', DCVersion);
    Obj.Add('revision', dcRevision);
    Obj.Add('commit', dcCommit);
    Obj.Add('build_date', dcBuildDate);
    Obj.Add('target_cpu', TargetCPU);
    Obj.Add('target_os', TargetOS);
    Obj.Add('widgetset', TargetWS);
    Obj.Add('process_id', GetProcessID);
    Obj.Add('debug_rpc_enabled', DebugRpcRuntimeEnabled);
    Obj.Add('debug_rpc_pipe', DebugRpcRuntimePipeName);
    Obj.Add('debug_rpc_uptime_ms', Int64(DebugRpcRuntimeUptimeMs));
    Obj.Add('debug_rpc_log', DebugRpcLogFileName);
    Exit(Obj);
  end;

  if AMethod = 'dc.getState' then
  begin
    Obj:= TJSONObject.Create;
    try
      Obj.Add('build_commit', dcCommit);
      Obj.Add('dc_version', DCVersion);
      Obj.Add('active_panel', PanelName(frmMain.SelectedPanel));
      Panels:= TJSONObject.Create;
      Obj.Add('panels', Panels);
      Panels.Add('left', PanelState(frmMain.FrameLeft, frmMain.LeftTabs, 'left'));
      Panels.Add('right', PanelState(frmMain.FrameRight, frmMain.RightTabs, 'right'));
      View:= frmMain.ActiveFrame;
      Obj.Add('panel_directory', View.CurrentPath);
      Obj.Add('panel_view_mode', ViewMode(View));
      Obj.Add('current_tab', frmMain.ActiveNotebook.PageIndex);
      Obj.Add('directory_loading_status',
        IfThen(View.DebugIsIdle, 'idle', 'loading'));
      ActiveFile:= View.CloneActiveFile;
      try
        if Assigned(ActiveFile) and ActiveFile.IsNameValid then
          Obj.Add('selected_item', FileJson(ActiveFile))
        else
          Obj.Add('selected_item', TJSONNull.Create);
      finally
        ActiveFile.Free;
      end;
    except
      Obj.Free;
      raise;
    end;
    Exit(Obj);
  end;

  if (AMethod = 'dc.navigate') or (AMethod = 'test.openRemoteDirectory') then
  begin
    Path:= ParamString(Params, 'path', EmptyStr);
    if Path = EmptyStr then Path:= ParamString(Params, 'remote_path', EmptyStr,
      True);
    TestId:= ParamString(Params, 'test_id', EmptyStr,
      AMethod = 'test.openRemoteDirectory');
    PhotoUuid:= ParamString(Params, 'photo_uuid', EmptyStr);
    View:= ResolvePanel(Params, Panel, ParamBool(Params, 'activate', True));
    if TestId <> EmptyStr then DebugRpcRegisterTest(TestId, Path, PhotoUuid);
    Loaded:= ChooseFileSource(View, Path);
    if (TestId <> EmptyStr) and (View.CurrentPath <> Path) then
      DebugRpcRegisterTest(TestId, View.CurrentPath, PhotoUuid);
    Obj:= TJSONObject.Create;
    Obj.Add('accepted', Loaded);
    Obj.Add('panel', PanelName(Panel));
    Obj.Add('requested_path', Path);
    Obj.Add('current_path', View.CurrentPath);
    Obj.Add('test_id', TestId);
    Exit(Obj);
  end;

  if (AMethod = 'dc.setViewMode') or
     (AMethod = 'test.switchToThumbnailView') then
  begin
    if AMethod = 'test.switchToThumbnailView' then Mode:= 'thumbnails'
    else Mode:= LowerCase(ParamString(Params, 'mode', EmptyStr, True));
    View:= ResolvePanel(Params, Panel, ParamBool(Params, 'activate', True));
    Notebook:= ResolveNotebook(Panel);
    Page:= Notebook.ActivePage;
    NewView:= nil;
    if Mode = 'thumbnails' then
    begin
      if not (View is TThumbFileView) then
      begin
        Page.BackupViewClass:= TFileViewClass(View.ClassType);
        if View is TColumnsFileView then
          Page.BackupColumnSet:= TColumnsFileView(View).ActiveColm;
        NewView:= TThumbFileView.Create(Page, View);
      end;
    end
    else if Mode = 'brief' then
    begin
      if not (View is TBriefFileView) then
        NewView:= TBriefFileView.Create(Page, View);
    end
    else if (Mode = 'details') or (Mode = 'columns') then
    begin
      Mode:= 'details';
      if not (View is TColumnsFileView) then
        NewView:= TColumnsFileView.Create(Page, View);
    end
    else
      raise EDebugRpcMethodError.Create(RpcInvalidParams,
        'mode must be details, brief, or thumbnails');
    if Assigned(NewView) then
    begin
      Page.FileView:= NewView;
      View:= NewView;
    end;
    if ParamString(Params, 'test_id', EmptyStr) <> EmptyStr then
      DebugRpcRegisterTest(ParamString(Params, 'test_id', EmptyStr),
        View.CurrentPath, ParamString(Params, 'photo_uuid', EmptyStr));
    Obj:= TJSONObject.Create;
    Obj.Add('panel', PanelName(Panel));
    Obj.Add('view_mode', ViewMode(View));
    Obj.Add('changed', Assigned(NewView));
    Exit(Obj);
  end;

  if AMethod = 'dc.refresh' then
  begin
    View:= ResolvePanel(Params, Panel, False);
    View.Reload(True);
    Obj:= TJSONObject.Create;
    Obj.Add('panel', PanelName(Panel));
    Obj.Add('queued', True);
    Exit(Obj);
  end;

  if AMethod = 'dc.getSelectedFiles' then
  begin
    View:= ResolvePanel(Params, Panel, False);
    Files:= View.CloneSelectedFiles;
    FilesArray:= TJSONArray.Create;
    try
      for Index:= 0 to Files.Count - 1 do
        FilesArray.Add(FileJson(Files[Index]));
    finally
      Files.Free;
    end;
    Obj:= TJSONObject.Create;
    Obj.Add('panel', PanelName(Panel));
    Obj.Add('files', FilesArray);
    Obj.Add('count', FilesArray.Count);
    Exit(Obj);
  end;

  if AMethod = 'plugin.getLoaded' then
  begin
    Arr:= TJSONArray.Create;
    for Index:= 0 to gWFXPlugins.Count - 1 do
    begin
      Entry:= TJSONObject.Create;
      ConfigPath:= gWFXPlugins.FileName[Index];
      Entry.Add('type', 'wfx');
      Entry.Add('name', gWFXPlugins.Name[Index]);
      Entry.Add('path', ConfigPath);
      Entry.Add('enabled', gWFXPlugins.Enabled[Index]);
      Loaded:= False;
      for ViewIndex:= 0 to gWFXPlugins.LoadedCount - 1 do
      begin
        Module:= gWFXPlugins.LoadedModule(ViewIndex);
        if Assigned(Module) and (CompareText(Module.ModulePath,
          ExpandFileName(ReplaceEnvVars(ConfigPath))) = 0) then
        begin
          Loaded:= True;
          Break;
        end;
      end;
      Entry.Add('loaded', Loaded);
      Arr.Add(Entry);
    end;
    Obj:= TJSONObject.Create;
    Obj.Add('plugins', Arr);
    FilesArray:= TJSONArray.Create;
    for Index:= 0 to gWFXPlugins.LoadedCount - 1 do
    begin
      Module:= gWFXPlugins.LoadedModule(Index);
      if not Assigned(Module) then Continue;
      Entry:= TJSONObject.Create;
      Entry.Add('path', Module.ModulePath);
      Entry.Add('unicode_preview_export_loaded',
        Assigned(Module.FsGetPreviewBitmapW));
      Entry.Add('ansi_preview_export_loaded',
        Assigned(Module.FsGetPreviewBitmap));
      FilesArray.Add(Entry);
    end;
    Obj.Add('loaded_modules', FilesArray);
    Obj.Add('loaded_module_count', gWFXPlugins.LoadedCount);
    Exit(Obj);
  end;

  if AMethod = 'plugin.getExports' then
  begin
    ModuleName:= ParamString(Params, 'name', EmptyStr);
    Path:= ParamString(Params, 'path', EmptyStr);
    Module:= nil;
    for Index:= 0 to gWFXPlugins.LoadedCount - 1 do
    begin
      NewView:= nil;
      Module:= gWFXPlugins.LoadedModule(Index);
      if not Assigned(Module) then Continue;
      if ((Path <> EmptyStr) and
          (CompareText(ExpandFileName(Path), Module.ModulePath) = 0)) or
         ((ModuleName <> EmptyStr) and
          (Pos(LowerCase(ModuleName), LowerCase(Module.ModulePath)) > 0)) or
         ((Path = EmptyStr) and (ModuleName = EmptyStr) and (Index = 0)) then
        Break;
      Module:= nil;
    end;
    if not Assigned(Module) then
      raise EDebugRpcMethodError.Create(RpcUnavailable,
        'requested WFX plugin is not loaded');
    ExportMap:= TJSONObject.Create;
    for Index:= Low(KnownExports) to High(KnownExports) do
    begin
      ExportName:= KnownExports[Index];
      ExportMap.Add(ExportName,
        Assigned(GetProcAddress(Module.ModuleHandle, PChar(ExportName))));
    end;
    Obj:= TJSONObject.Create;
    Obj.Add('path', Module.ModulePath);
    Obj.Add('unicode_preview_loaded', Assigned(Module.FsGetPreviewBitmapW));
    Obj.Add('ansi_preview_loaded', Assigned(Module.FsGetPreviewBitmap));
    Obj.Add('exports', ExportMap);
    Exit(Obj);
  end;

  if AMethod = 'wfx.getConnectionState' then
  begin
    View:= ResolvePanel(Params, Panel, False);
    Obj:= TJSONObject.Create;
    Obj.Add('panel', PanelName(Panel));
    Obj.Add('path', View.CurrentPath);
    if Supports(View.FileSource, IWfxPluginFileSource, WfxSource) then
    begin
      Obj.Add('is_wfx', True);
      Obj.Add('plugin_number', WfxSource.PluginNumber);
      Obj.Add('plugin_root', WfxSource.PluginRootName);
      Obj.Add('module_path', WfxSource.WfxModule.ModulePath);
      Obj.Add('loaded', WfxSource.WfxModule.IsLoaded);
      Pending:= WfxSource.GetPendingPreviewPaths;
      PendingArray:= TJSONArray.Create;
      for Index:= 0 to High(Pending) do PendingArray.Add(Pending[Index]);
      Obj.Add('pending_previews', PendingArray);
    end
    else begin
      Obj.Add('is_wfx', False);
      Obj.Add('loaded', False);
      Obj.Add('pending_previews', TJSONArray.Create);
    end;
    Exit(Obj);
  end;

  if (AMethod = 'thumbnail.invalidate') or
     (AMethod = 'thumbnail.clearCache') then
  begin
    TargetPath:= ParamString(Params, 'path', EmptyStr);
    if TargetPath = EmptyStr then
      TargetPath:= ParamString(Params, 'remote_path', EmptyStr);
    if TargetPath <> EmptyStr then
    begin
      SetLength(Paths, 1);
      Paths[0]:= TargetPath;
    end
    else
      SetLength(Paths, 0);
    Invalidated:= 0;
    for Index:= 0 to frmMain.LeftTabs.PageCount - 1 do
      if frmMain.LeftTabs.View[Index] is TThumbFileView then
      begin
        TThumbFileView(frmMain.LeftTabs.View[Index]).DebugInvalidatePreviews(Paths);
        Inc(Invalidated);
      end;
    for Index:= 0 to frmMain.RightTabs.PageCount - 1 do
      if frmMain.RightTabs.View[Index] is TThumbFileView then
      begin
        TThumbFileView(frmMain.RightTabs.View[Index]).DebugInvalidatePreviews(Paths);
        Inc(Invalidated);
      end;
    Obj:= TJSONObject.Create;
    Obj.Add('views_invalidated', Invalidated);
    Obj.Add('path', TargetPath);
    Obj.Add('disk_cache_deleted', False);
    Exit(Obj);
  end;

  if AMethod = 'test.triggerPreview' then
  begin
    TestId:= ParamString(Params, 'test_id', EmptyStr, True);
    PhotoUuid:= ParamString(Params, 'photo_uuid', EmptyStr);
    View:= ResolvePanel(Params, Panel, True);
    if not (View is TThumbFileView) then
      raise EDebugRpcMethodError.Create(RpcInvalidParams,
        'panel must be in thumbnails view before triggering a preview');
    TargetPath:= ParamString(Params, 'path', EmptyStr);
    if TargetPath = EmptyStr then TargetPath:= ParamString(Params,
      'remote_path', EmptyStr);
    if TargetPath = EmptyStr then
    begin
      ActiveFile:= View.CloneActiveFile;
      try
        if Assigned(ActiveFile) and ActiveFile.IsNameValid then
          TargetPath:= ActiveFile.FullPath;
      finally
        ActiveFile.Free;
      end;
    end;
    if TargetPath = EmptyStr then
      raise EDebugRpcMethodError.Create(RpcInvalidParams,
        'no preview target was supplied or selected');
    DebugRpcRegisterTest(TestId, TargetPath, PhotoUuid);
    View.SetActiveFile(TargetPath);
    if ParamBool(Params, 'force', True) then
    begin
      SetLength(Paths, 1);
      Paths[0]:= TargetPath;
      TThumbFileView(View).DebugInvalidatePreviews(Paths);
    end;
    TThumbFileView(View).DebugRequestVisiblePreviews;
    Obj:= TJSONObject.Create;
    Obj.Add('test_id', TestId);
    Obj.Add('panel', PanelName(Panel));
    Obj.Add('path', TargetPath);
    Obj.Add('queued', True);
    Exit(Obj);
  end;

  raise EDebugRpcMethodError.Create(-32601,
    'method not found: ' + AMethod);
end;

function TDebugRpcMethods.WaitForIdle(AParams: TJSONData;
  ATimeoutMs: Cardinal): TJSONData;
var
  Started, NowTick: QWord;
  Slice: Cardinal;
  State: TJSONData;
  Obj: TJSONObject;
begin
  Started:= GetTickCount64;
  repeat
    if not DebugRpcRuntimeEnabled then
      raise EDebugRpcMethodError.Create(RpcUnavailable,
        'RPC server is stopping');
    NowTick:= GetTickCount64;
    if NowTick - Started >= ATimeoutMs then Break;
    Slice:= ATimeoutMs - Cardinal(NowTick - Started);
    if Slice > 1000 then Slice:= 1000;
    State:= InvokeGui('internal.isIdle', AParams, Slice);
    Obj:= TJSONObject(State);
    if Obj.Get('idle', False) then
    begin
      Obj.Add('waited_ms', Int64(GetTickCount64 - Started));
      Exit(Obj);
    end;
    State.Free;
    Sleep(25);
  until False;
  raise EDebugRpcMethodError.Create(RpcExecutionTimeout,
    'waitForIdle timed out');
end;

function TDebugRpcMethods.WaitForPreview(AParams: TJSONData;
  ATimeoutMs: Cardinal; ARequireDrawDefault: Boolean): TJSONData;
var
  Params: TJSONObject;
  TestId, Path, PhotoUuid, Source, ErrorText, State: String;
  RequireDraw: Boolean;
  Started: QWord;
  Obj: TJSONObject;
begin
  Params:= ParamsObject(AParams);
  if not DiagnosticFilter(Params, TestId, Path, PhotoUuid) then
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'at least one of test_id, path, or photo_uuid is required');
  if ARequireDrawDefault and (TestId = EmptyStr) then
    raise EDebugRpcMethodError.Create(RpcInvalidParams,
      'test_id is required for test.waitForPreview');
  RequireDraw:= ParamBool(Params, 'require_draw', ARequireDrawDefault);
  Started:= GetTickCount64;
  repeat
    if not DebugRpcRuntimeEnabled then
      raise EDebugRpcMethodError.Create(RpcUnavailable,
        'RPC server is stopping');
    State:= DebugRpcGetCompletionState(TestId, Path, PhotoUuid, RequireDraw,
      Source, ErrorText);
    if (State = 'completed') or (State = 'error') then
    begin
      Obj:= TJSONObject.Create;
      Obj.Add('state', State);
      Obj.Add('completed', State = 'completed');
      Obj.Add('source', Source);
      Obj.Add('error', ErrorText);
      Obj.Add('require_draw', RequireDraw);
      Obj.Add('waited_ms', Int64(GetTickCount64 - Started));
      Exit(Obj);
    end;
    Sleep(25);
  until GetTickCount64 - Started >= ATimeoutMs;
  raise EDebugRpcMethodError.Create(RpcExecutionTimeout,
    'preview completion timed out');
end;

function StageJson(const AName: String; APassed: Boolean; AObserved: Int64;
  const AConclusion: String): TJSONObject;
begin
  Result:= TJSONObject.Create;
  Result.Add('stage', AName);
  Result.Add('passed', APassed);
  Result.Add('observed', AObserved);
  Result.Add('conclusion', AConclusion);
end;

function TDebugRpcMethods.BuildTestReport(AParams: TJSONData): TJSONData;
var
  Params: TJSONObject;
  TestId, Path, PhotoUuid, Failure: String;
  Stats, Report: TJSONObject;
  Stages: TJSONArray;
  CallbackCalls, ResolverHits, ResolverMisses, CacheHits, CacheMisses: Int64;
  MissingFiles, InvalidFiles, HashMismatches: Int64;
  DecodeSuccesses, DecodeFailures, BitmapReturns, BitmapReturnFailures: Int64;
  HostReceives, UiDraws, Invalidations: Int64;
begin
  Params:= ParamsObject(AParams);
  TestId:= ParamString(Params, 'test_id', EmptyStr, True);
  Path:= ParamString(Params, 'path', EmptyStr);
  if Path = EmptyStr then Path:= ParamString(Params, 'remote_path', EmptyStr);
  PhotoUuid:= ParamString(Params, 'photo_uuid', EmptyStr);
  Stats:= DebugRpcGetStats(TestId, Path, PhotoUuid);
  CallbackCalls:= Stats.Get('fs_get_preview_bitmap_calls', Int64(0));
  ResolverHits:= Stats.Get('resolver_hits', Int64(0));
  ResolverMisses:= Stats.Get('resolver_misses', Int64(0));
  CacheHits:= Stats.Get('local_cache_hits', Int64(0));
  CacheMisses:= Stats.Get('local_cache_misses', Int64(0));
  MissingFiles:= Stats.Get('webp_missing_files', Int64(0));
  InvalidFiles:= Stats.Get('webp_invalid_files', Int64(0));
  HashMismatches:= Stats.Get('webp_hash_mismatches', Int64(0));
  DecodeSuccesses:= Stats.Get('bitmap_decode_successes', Int64(0));
  DecodeFailures:= Stats.Get('bitmap_decode_failures', Int64(0));
  BitmapReturns:= Stats.Get('bitmap_returns', Int64(0));
  BitmapReturnFailures:= Stats.Get('bitmap_return_failures', Int64(0));
  HostReceives:= Stats.Get('host_receives', Int64(0));
  UiDraws:= Stats.Get('ui_draws', Int64(0));
  Invalidations:= Stats.Get('invalidations', Int64(0));

  Failure:= EmptyStr;
  if CallbackCalls = 0 then Failure:= 'wfx_callback_not_triggered'
  else if (ResolverHits = 0) and (ResolverMisses > 0) then Failure:= 'resolver_lookup_failed'
  else if (MissingFiles > 0) and (CacheHits = 0) then Failure:= 'webp_file_missing'
  else if ((InvalidFiles > 0) or (HashMismatches > 0)) and
          (CacheHits = 0) then Failure:= 'webp_file_invalid'
  else if (CacheHits = 0) and (CacheMisses > 0) then Failure:= 'webp_file_not_cached'
  else if (BitmapReturnFailures > 0) and (BitmapReturns = 0) then Failure:= 'hbitmap_return_failed'
  else if (DecodeFailures > 0) and (DecodeSuccesses = 0) then Failure:= 'bitmap_decode_failed'
  else if (DecodeSuccesses = 0) and (BitmapReturns = 0) then Failure:= 'bitmap_decode_failed'
  else if BitmapReturns = 0 then Failure:= 'hbitmap_return_failed'
  else if HostReceives = 0 then Failure:= 'dc_host_not_received'
  else if UiDraws = 0 then Failure:= 'host_received_not_displayed'
  else if (Invalidations > 0) and (CacheHits = 0) then Failure:= 'thumbnail_cache_not_updated';

  Stages:= TJSONArray.Create;
  Stages.Add(StageJson('wfx_callback', CallbackCalls > 0, CallbackCalls,
    IfThen(CallbackCalls > 0, 'observed', 'not observed')));
  Stages.Add(StageJson('resolver_lookup', ResolverHits > 0, ResolverHits,
    IfThen(ResolverHits > 0, 'resolved', IfThen(ResolverMisses > 0,
      'lookup failed', 'not observable'))));
  Stages.Add(StageJson('webp_cache_file', CacheHits > 0, CacheHits,
    IfThen(CacheHits > 0, 'cache hit', IfThen(CacheMisses > 0,
      'missing or invalid', 'not observable'))));
  Stages.Add(StageJson('bitmap_decode', DecodeSuccesses > 0,
    DecodeSuccesses, IfThen(DecodeSuccesses > 0, 'decoded', 'not observed')));
  Stages.Add(StageJson('hbitmap_return', BitmapReturns > 0, BitmapReturns,
    IfThen(BitmapReturns > 0, 'returned', 'not observed')));
  Stages.Add(StageJson('dc_host_receive', HostReceives > 0, HostReceives,
    IfThen(HostReceives > 0, 'received', 'not observed')));
  Stages.Add(StageJson('ui_draw', UiDraws > 0, UiDraws,
    IfThen(UiDraws > 0, 'paint callback observed',
      'not proven; screenshot or UI automation remains required')));
  Stages.Add(StageJson('thumbnail_cache_update',
    (Invalidations = 0) or (CacheHits > 0), CacheHits,
    IfThen(Invalidations = 0, 'not exercised', IfThen(CacheHits > 0,
      'updated', 'not observed'))));

  Report:= TJSONObject.Create;
  Report.Add('test_id', TestId);
  Report.Add('path', Path);
  Report.Add('photo_uuid', PhotoUuid);
  Report.Add('passed', (Failure = EmptyStr) and (UiDraws > 0));
  Report.Add('failure_code', Failure);
  Report.Add('visual_verified', UiDraws > 0);
  Report.Add('visual_verification_note',
    'ui_draw means the thumbnail paint callback drew a bitmap; external screenshot/UI automation is still recommended');
  Report.Add('stages', Stages);
  Report.Add('stats', Stats);
  Report.Add('events', DebugRpcGetEvents(TestId, Path, PhotoUuid, EmptyStr,
    Integer(ParamInt(Params, 'event_limit', 100, 1, 1000)), False));
  Result:= Report;
end;

function TDebugRpcMethods.AssertPreviewSource(AParams: TJSONData): TJSONData;
var
  Params: TJSONObject;
  TestId, Path, PhotoUuid, Expected, Actual: String;
  Stats, Obj: TJSONObject;
  Passed: Boolean;
begin
  Params:= ParamsObject(AParams);
  TestId:= ParamString(Params, 'test_id', EmptyStr, True);
  Path:= ParamString(Params, 'path', EmptyStr);
  if Path = EmptyStr then Path:= ParamString(Params, 'remote_path', EmptyStr);
  PhotoUuid:= ParamString(Params, 'photo_uuid', EmptyStr);
  Expected:= LowerCase(ParamString(Params, 'source', EmptyStr, True));
  Stats:= DebugRpcGetStats(TestId, Path, PhotoUuid);
  try
    Actual:= LowerCase(Stats.Get('latest_source', EmptyStr));
  finally
    Stats.Free;
  end;
  Passed:= (Actual = Expected) or
    ((Expected = 'wfx') and StartsText('wfx', Actual));
  Obj:= TJSONObject.Create;
  Obj.Add('passed', Passed);
  Obj.Add('expected', Expected);
  Obj.Add('actual', Actual);
  Obj.Add('test_id', TestId);
  if not Passed then Obj.Add('failure_code', 'preview_source_mismatch');
  Result:= Obj;
end;

function TDebugRpcMethods.Execute(const AMethod: String; AParams: TJSONData;
  ATimeoutMs: Cardinal): TJSONData;
var
  Params: TJSONObject;
  TestId, Path, PhotoUuid: String;
  Limit: Integer;
  Obj: TJSONObject;
  PluginInfo: TJSONData;
begin
  if AMethod = 'dc.ping' then
  begin
    Obj:= TJSONObject.Create;
    Obj.Add('ok', True);
    Obj.Add('service', 'DoubleCmdRPC');
    Obj.Add('process_id', GetProcessID);
    Obj.Add('pipe', DebugRpcRuntimePipeName);
    Obj.Add('timestamp', DateToISO8601(LocalTimeToUniversal(Now), True));
    Exit(Obj);
  end;

  if AMethod = 'dc.waitForIdle' then Exit(WaitForIdle(AParams, ATimeoutMs));
  if (AMethod = 'thumbnail.waitForCompletion') then
    Exit(WaitForPreview(AParams, ATimeoutMs, False));
  if (AMethod = 'test.waitForPreview') then
    Exit(WaitForPreview(AParams, ATimeoutMs, True));

  if (AMethod = 'wfx.getStats') or (AMethod = 'thumbnail.getStats') then
  begin
    Params:= ParamsObject(AParams);
    DiagnosticFilter(Params, TestId, Path, PhotoUuid);
    Obj:= DebugRpcGetStats(TestId, Path, PhotoUuid);
    if AMethod = 'wfx.getStats' then
    begin
      try
        PluginInfo:= InvokeGui('internal.wfxInfo', AParams, ATimeoutMs);
        Obj.Add('plugin', PluginInfo);
      except
        Obj.Free;
        raise;
      end;
    end;
    Exit(Obj);
  end;

  if (AMethod = 'wfx.getLastCalls') then
  begin
    Params:= ParamsObject(AParams);
    DiagnosticFilter(Params, TestId, Path, PhotoUuid);
    Limit:= Integer(ParamInt(Params, 'limit', 50, 1, 1000));
    Obj:= TJSONObject.Create;
    Obj.Add('calls', DebugRpcGetEvents(TestId, Path, PhotoUuid, 'wfx',
      Limit, False));
    Exit(Obj);
  end;

  if AMethod = 'wfx.getErrors' then
  begin
    Params:= ParamsObject(AParams);
    DiagnosticFilter(Params, TestId, Path, PhotoUuid);
    Limit:= Integer(ParamInt(Params, 'limit', 50, 1, 1000));
    Obj:= TJSONObject.Create;
    Obj.Add('errors', DebugRpcGetEvents(TestId, Path, PhotoUuid, EmptyStr,
      Limit, True));
    Exit(Obj);
  end;

  if AMethod = 'thumbnail.getPending' then
  begin
    Params:= ParamsObject(AParams);
    DiagnosticFilter(Params, TestId, Path, PhotoUuid);
    Obj:= TJSONObject.Create;
    Obj.Add('pending', DebugRpcGetPending(TestId, Path, PhotoUuid));
    Exit(Obj);
  end;

  if AMethod = 'log.getRecent' then
  begin
    Params:= ParamsObject(AParams);
    Limit:= Integer(ParamInt(Params, 'limit', 100, 1, 2000));
    TestId:= ParamString(Params, 'test_id', EmptyStr);
    Obj:= TJSONObject.Create;
    Obj.Add('entries', DebugRpcGetRecentLogs(Limit, TestId));
    Obj.Add('file', DebugRpcLogFileName);
    Exit(Obj);
  end;

  if AMethod = 'test.getReport' then Exit(BuildTestReport(AParams));
  if AMethod = 'test.assertPreviewSource' then Exit(AssertPreviewSource(AParams));

  Result:= InvokeGui(AMethod, AParams, ATimeoutMs);
end;

destructor TDebugRpcMethods.Destroy;
begin
  if Assigned(Application) then Application.RemoveAsyncCalls(Self);
  inherited Destroy;
end;

end.
