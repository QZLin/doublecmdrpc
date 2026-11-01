unit uWfxPluginFileSource;

{$mode objfpc}{$H+}
{$include calling.inc}

interface

uses
  Classes, SysUtils, Types, URIParser, {$IFDEF MSWINDOWS}Windows, {$ENDIF}SyncObjs, Graphics, uWFXModule, WfxPlugin,
  uFile, uFileSourceProperty, uFileSourceOperationTypes,
  uFileProperty, uFileSource, uFileSourceOperation;

type

  TUpdateProgress = function(SourceName, TargetName: PAnsiChar; PercentDone: Integer): Integer of object;

  { IWfxPluginFileSource }

  IWfxPluginFileSource = interface(IFileSource)
    ['{F1F728C6-F718-4B17-8DE2-BE0134134ED8}']

    procedure FillAndCount(Files: TFiles; CountDirs: Boolean; ExcludeRootDir: Boolean;
                           out NewFiles: TFiles; out FilesCount: Int64; out FilesSize: Int64);
    function FillSingleFile(const FullPath: String; out aFile: TFile): Boolean;
    function WfxCopyMove(sSourceFile, sTargetFile: String; Flags: LongInt;
                         RemoteInfo: PRemoteInfo; Internal, CopyMoveIn: Boolean): LongInt;

    function GetPluginNumber: LongInt;
    function GetWfxModule: TWfxModule;
    function GetPluginRootName: String;
    function GetPendingPreviewPaths: TStringArray;

    property PluginNumber: LongInt read GetPluginNumber;
    property WfxModule: TWfxModule read GetWfxModule;
    property PluginRootName: String read GetPluginRootName;
  end;

  { TWfxPluginFileSource }

  TWfxPluginFileSource = class;

  { TCallbackDataClass }

  TCallbackDataClass = class
  public
    // Must use class here instead of interface because of circular reference
    // between TWfxPluginFileSource and TCallbackDataClass, which would cause
    // the file source never to be destroyed.
    // TWfxPluginFileSource controls the lifetime of TCallbackDataClass though,
    // so it should be fine.
    FileSource: TWfxPluginFileSource;
    UpdateProgressFunction: TUpdateProgress;
    constructor Create(aFileSource: TWfxPluginFileSource);
  end;

  { TWfxPluginFileSource }

  TWfxPluginFileSource = class(TFileSource, IWfxPluginFileSource)
  private
    FModuleFileName,
    FPluginRootName: String;
    FWFXModule: TWFXModule;
    FPluginNumber: LongInt;
    FCallbackDataClass: TCallbackDataClass;

    FPreviewLock: SyncObjs.TCriticalSection;
    FPendingPreviewPaths: TStringList;
    FPreviewNotificationQueued: Boolean;
    FInvalidateAllPreviews: Boolean;
    FPreviewRegistered: Boolean;

    procedure RememberPreviewMiss(const APath: String);
    procedure ForgetPreviewMiss(const APath: String);
    procedure QueuePreviewInvalidation(AInvalidateAll: Boolean);
    procedure DeliverPreviewInvalidation(Data: PtrInt);

    function GetPluginNumber: LongInt;
    function GetWfxModule: TWfxModule;
    function GetPluginRootName: String;
    function GetPendingPreviewPaths: TStringArray;

    function CreateConnection: TFileSourceConnection;
    procedure CreateConnections;

    procedure AddToConnectionQueue(Operation: TFileSourceOperation);
    procedure RemoveFromConnectionQueue(Operation: TFileSourceOperation);
    procedure AddConnection(Connection: TFileSourceConnection);
    procedure RemoveConnection(Connection: TFileSourceConnection);

    {en
       Searches connections list for a connection assigned to operation.
    }
    function FindConnectionByOperation(operation: TFileSourceOperation): TFileSourceConnection; virtual;

    procedure NotifyNextWaitingOperation(allowedOps: TFileSourceOperationTypes);

  protected
    function GetSupportedFileProperties: TFilePropertiesTypes; override;
    function GetRetrievableFileProperties: TFilePropertiesTypes; override;
    function GetCurrentAddress: String; override;
    procedure OperationFinished(Operation: TFileSourceOperation); override;
  public
    procedure FillAndCount(Files: TFiles; CountDirs: Boolean; ExcludeRootDir: Boolean;
                           out NewFiles: TFiles; out FilesCount: Int64; out FilesSize: Int64);
    function FillSingleFile(const FullPath: String; out aFile: TFile): Boolean;
    function WfxCopyMove(sSourceFile, sTargetFile: String; Flags: LongInt;
                         RemoteInfo: PRemoteInfo; Internal, CopyMoveIn: Boolean): LongInt;
  public
    constructor Create(const URI: TURI); override;
    constructor Create(aModuleFileName, aPluginRootName: String); reintroduce;
    destructor Destroy; override;

    function FileSystemEntryExists(const Path: String; const Options: TFileSourceExistsOptions): TFileSourceExistsResult; override;
    function SetCurrentWorkingDirectory(NewDir: String): Boolean; override;

    class function CreateFile(const APath: String): TFile; override;
    class function CreateFile(const APath: String; FindData: TWfxFindData): TFile; overload;

    procedure RetrieveProperties(AFile: TFile; PropertiesToSet: TFilePropertiesTypes; const AVariantProperties: array of String); override;

    // Retrieve operations permitted on the source.  = capabilities?
    function GetOperationsTypes: TFileSourceOperationTypes; override;

    // Retrieve some properties of the file source.
    function GetProperties: TFileSourceProperties; override;

    function GetFileSystem: String; override;

    // These functions create an operation object specific to the file source.
    function CreateListOperation(TargetPath: String): TFileSourceOperation; override;
    function CreateCopyOperation(var SourceFiles: TFiles;
                                 TargetPath: String): TFileSourceOperation; override;
    function CreateCopyInOperation(SourceFileSource: IFileSource;
                                   var SourceFiles: TFiles;
                                   TargetPath: String): TFileSourceOperation; override;
    function CreateCopyOutOperation(TargetFileSource: IFileSource;
                                    var SourceFiles: TFiles;
                                    TargetPath: String): TFileSourceOperation; override;
    function CreateMoveOperation(var SourceFiles: TFiles;
                                 TargetPath: String): TFileSourceOperation; override;
    function CreateDeleteOperation(var FilesToDelete: TFiles): TFileSourceOperation; override;
    function CreateCreateDirectoryOperation(BasePath: String; DirectoryPath: String): TFileSourceOperation; override;
    function CreateExecuteOperation(var ExecutableFile: TFile; BasePath, Verb: String): TFileSourceOperation; override;
    function CreateSetFilePropertyOperation(var theTargetFiles: TFiles;
                                            var theNewProperties: TFileProperties): TFileSourceOperation; override;
    function CreateCalcStatisticsOperation(var theFiles: TFiles): TFileSourceOperation; override;

    function GetLocalName(var aFile: TFile): Boolean; override;
    function CreateDirectory(const Path: String): Boolean; override;
    function GetDefaultView(out DefaultView: TFileSourceFields): Boolean; override;

    function SupportsPreviewBitmap: Boolean; override;
    function GetPreviewBitmap(aFile: TFile; const ASize: TSize;
      out ABitmap: TBitmap; out ACacheKey: String; out ACacheable: Boolean): Boolean; override;

    function GetCustomIcon(aFile: TFile; AIconSize: Integer; out AIcon: TBitmap): PtrInt; override;
    function GetCustomIcon(const path: String; const iconSize: Integer): TBitmap; override;

    class function IsSupportedPath(const Path: String): Boolean; override;
    class function CreateByRootName(aRootName: String): IWfxPluginFileSource;

    function GetConnection(Operation: TFileSourceOperation): TFileSourceConnection; override;
    procedure RemoveOperationFromQueue(Operation: TFileSourceOperation); override;

    property PluginNumber: LongInt read FPluginNumber;
    property WfxModule: TWfxModule read FWfxModule;

  end;

  { TWfxPluginFileSourceConnection }

  TWfxPluginFileSourceConnection = class(TFileSourceConnection)
  private
    FWfxModule: TWfxModule;

  public
    constructor Create(aWfxModule: TWfxModule); reintroduce;

    property WfxModule: TWfxModule read FWfxModule;
  end;

var
  // Used in callback functions
  WfxOperationList: TStringList = nil;

threadvar
  // Main operation progress callback function
  // Declared as threadvar so each operation has it own callback function
  UpdateProgressFunction: TUpdateProgress;

implementation

uses
  LazUTF8, FileUtil, StrUtils, Forms, {} LCLType, uShowMsg, {} uGlobs, DCStrUtils, uDCUtils, uLog,
  uDebug, uLng, uCryptProc, DCFileAttributes, uConnectionManager, contnrs, fMain,
  uWfxPluginCopyInOperation, uWfxPluginCopyOutOperation,  uWfxPluginMoveOperation, uVfsModule,
  uWfxPluginExecuteOperation, uWfxPluginListOperation, uWfxPluginCreateDirectoryOperation,
  uWfxPluginDeleteOperation, uWfxPluginSetFilePropertyOperation, uWfxPluginCopyOperation,
  DCConvertEncoding, uWfxPluginCalcStatisticsOperation, uFileFunctions, uPixMapManager,
  uDebugRpcDiagnostics,
  uFileSourceUtil
  {$IFDEF MSWINDOWS}, uBitmap, DCClassesUtf8{$ENDIF};

const
  connCopyIn      = 0;
  connCopyOut     = 1;
  connDelete      = 2;
  connCopyMove    = 3;
  PreviewReadySelected = 'RemoteThumbnailWFX.PreviewReady=selected';
  PreviewReadyMetadata = 'RemoteThumbnailWFX.PreviewReady=metadata';
  PreviewReadyAll = 'RemoteThumbnailWFX.PreviewReady=all';

var
  // Always use appropriate lock to access these lists.
  WfxConnections: TObjectList; // store connections created by Wcx file sources
  WfxOperationsQueue: TObjectList; // store queued operations, use only under FOperationsQueueLock
  WfxConnectionsLock: SyncObjs.TCriticalSection; // used to synchronize access to connections
  WfxOperationsQueueLock: SyncObjs.TCriticalSection; // used to synchronize access to operations queue
  WfxPreviewSources: TFPList;
  WfxPreviewSourcesLock: SyncObjs.TCriticalSection;

procedure DispatchPreviewInvalidation(PluginNr: Integer; InvalidateAll: Boolean);
var
  Index: Integer;
  FileSource: TWfxPluginFileSource;
begin
  WfxPreviewSourcesLock.Acquire;
  try
    for Index:= 0 to WfxPreviewSources.Count - 1 do
    begin
      FileSource:= TWfxPluginFileSource(WfxPreviewSources[Index]);
      if FileSource.FPluginNumber = PluginNr then
        FileSource.QueuePreviewInvalidation(InvalidateAll);
    end;
  finally
    WfxPreviewSourcesLock.Release;
  end;
end;

{ CallBack functions }

function MainProgressProc(PluginNr: Integer; SourceName, TargetName: PAnsiChar; PercentDone: Integer): Integer;
var
  CallbackDataClass: TCallbackDataClass;
begin
  Result:= 0;

  // DCDebug('MainProgressProc ('+IntToStr(PluginNr)+','+SourceName+','+TargetName+','+IntToStr(PercentDone)+')=' ,IntTostr(Result));

  if Assigned(UpdateProgressFunction) then
    // Call operation progress function
    Result:= UpdateProgressFunction(SourceName, TargetName, PercentDone)
  else
    begin
      // Operation callback function not found, may be plugin call progress function
      // from non operation thread, call global progress function in this case
      DCDebug('Warning UpdateProgressFunction does not found for thread ' + hexStr(Pointer(GetCurrentThreadId)));
      CallbackDataClass:= TCallbackDataClass(WfxOperationList.Objects[PluginNr]);
      if Assigned(CallbackDataClass) and Assigned(CallbackDataClass.UpdateProgressFunction) then
        Result:= CallbackDataClass.UpdateProgressFunction(SourceName, TargetName, PercentDone)
      else
        // Global callback function not found, incorrect
        // FileSourceOperation implementation, notify about it
        DCDebug('Warning UpdateProgressFunction does not found for plugin number %d', [PluginNr]);
    end;
end;

function MainProgressProcA(PluginNr: Integer; SourceName, TargetName: PAnsiChar; PercentDone: Integer): Integer; dcpcall;
var
  sSourceName, sTargetName: String;
begin
  if Assigned(SourceName) then
  begin
    sSourceName:= CeSysToUtf8(StrPas(SourceName));
    SourceName:= PAnsiChar(sSourceName);
  end;
  if Assigned(TargetName) then
  begin
    sTargetName:= CeSysToUtf8(StrPas(TargetName));
    TargetName:= PAnsiChar(sTargetName);
  end;
  Result:= MainProgressProc(PluginNr, SourceName, TargetName, PercentDone);
end;

function MainProgressProcW(PluginNr: Integer; SourceName, TargetName: PWideChar; PercentDone: Integer): Integer; dcpcall;
var
  sSourceName, sTargetName: String;
begin
  if Assigned(SourceName) then
  begin
    sSourceName:= UTF16ToUTF8(UnicodeString(SourceName));
    SourceName:= Pointer(PAnsiChar(sSourceName));
  end;
  if Assigned(TargetName) then
  begin
    sTargetName:= UTF16ToUTF8(UnicodeString(TargetName));
    TargetName:= Pointer(PAnsiChar(sTargetName));
  end;
  Result:= MainProgressProc(PluginNr, Pointer(SourceName), Pointer(TargetName), PercentDone);
end;

procedure MainLogProc(PluginNr, MsgType: Integer; LogString: String);
var
  I: Integer;
  bLogFile: Boolean;
  bLogWindow: Boolean;
  sMsg, sName, sPath: String;
  LogMsgType: TLogMsgType = lmtInfo;
  CallbackDataClass: TCallbackDataClass;
Begin
  DebugRpcRecordPluginLog(MsgType, LogString);
  if LogString = PreviewReadySelected then
  begin
    DebugRpcRecord('wfx', 'preview.ready', EmptyStr, 'selected', EmptyStr,
      0, PluginNr, LogString);
    DispatchPreviewInvalidation(PluginNr, False);
    DCDebug(['RemoteThumbnailHostBridge completion=', LogString]);
    Exit;
  end
  else if (LogString = PreviewReadyMetadata) or (LogString = PreviewReadyAll) then
  begin
    DebugRpcRecord('wfx', 'preview.ready', EmptyStr, 'all', EmptyStr,
      0, PluginNr, LogString);
    DispatchPreviewInvalidation(PluginNr, True);
    DCDebug(['RemoteThumbnailHostBridge completion=', LogString]);
    Exit;
  end;
  sMsg:= rsMsgLogInfo;
  bLogWindow:= frmMain.seLogWindow.Visible;
  bLogFile:= ((log_vfs_op in gLogOptions) and (log_info in gLogOptions));
  CallbackDataClass:= TCallbackDataClass(WfxOperationList.Objects[PluginNr]);
  case MsgType of
    msgtype_connect:
      begin
        bLogWindow:= True;
        if Assigned(CallbackDataClass) then
        begin
          if Length(LogString) > 0 then
          begin
            I:= Pos(#32, LogString);
            sName:= WfxOperationList[PluginNr];
            sPath:= Copy(LogString, I + 1, MaxInt);
            AddNetworkConnection(sName, sPath, CallbackDataClass.FileSource);
          end;
        end;
        sMsg:= sMsg + '[' + IntToStr(MsgType) + ']';
      end;
    msgtype_disconnect:
      begin
        if Assigned(CallbackDataClass) then
        begin
          bLogWindow:= False;
          I:= Pos(#32, LogString);
          sName:= WfxOperationList[PluginNr];
          sPath:= Copy(LogString, I + 1, MaxInt);
          RemoveNetworkConnection(sName, sPath);
        end;
        sMsg:= sMsg + '[' + IntToStr(MsgType) + ']';
      end;
    msgtype_details,
    msgtype_operationcomplete,
    msgtype_transfercomplete,
    msgtype_connectcomplete:
      sMsg:= sMsg + '[' + IntToStr(MsgType) + ']';
    msgtype_importanterror:
      begin
        LogMsgType:= lmtError;
        sMsg:= rsMsgLogError + '[' + IntToStr(MsgType) + ']';
        bLogFile:= (log_vfs_op in gLogOptions) and (log_errors in gLogOptions);
      end;
  end;
  // write log info
  logWrite(sMsg + ', ' + logString, LogMsgType, bLogWindow, bLogFile);

  // DCDebug('MainLogProc ('+ sMsg + ',' + logString + ')');
end;

procedure MainLogProcA(PluginNr, MsgType: Integer; LogString: PAnsiChar); dcpcall;
begin
  MainLogProc(PluginNr, MsgType, CeSysToUtf8(StrPas(LogString)));
end;

procedure MainLogProcW(PluginNr, MsgType: Integer; LogString: PWideChar); dcpcall;
begin
  MainLogProc(PluginNr, MsgType, UTF16ToUTF8(UnicodeString(LogString)));
end;

function MainRequestProc(PluginNr, RequestType: Integer; CustomTitle, CustomText: String; var ReturnedText: String): Bool;
begin
  if CustomTitle = '' then CustomTitle:= 'Double Commander';

  case RequestType of
    RT_Other:
      Result:= ShowInputQuery(CustomTitle, CustomText, ReturnedText);
    RT_UserName:
      Result:= ShowInputQuery(CustomTitle, IfThen(CustomText = EmptyStr, rsMsgUserName, CustomText), ReturnedText);
    RT_Password:
      Result:= ShowInputQuery(CustomTitle, IfThen(CustomText = EmptyStr, rsMsgPassword, CustomText), True, ReturnedText);
    RT_Account:
      Result:= ShowInputQuery(CustomTitle, IfThen(CustomText = EmptyStr, rsMsgAccount, CustomText), ReturnedText);
    RT_UserNameFirewall:
      Result:= ShowInputQuery(CustomTitle, IfThen(CustomText = EmptyStr, rsMsgUserNameFirewall, CustomText), ReturnedText);
    RT_PasswordFirewall:
      Result:= ShowInputQuery(CustomTitle, IfThen(CustomText = EmptyStr, rsMsgPasswordFirewall, CustomText), True, ReturnedText);
    RT_TargetDir:
      Result:= ShowInputQuery(CustomTitle, IfThen(CustomText = EmptyStr, rsMsgTargetDir, CustomText), ReturnedText);
    RT_URL:
      Result:= ShowInputQuery(CustomTitle, IfThen(CustomText = EmptyStr, rsMsgURL, CustomText), ReturnedText);
    RT_MsgOK:
      Result:= (ShowMessageBox(CustomText, CustomTitle, MB_OK) = IDOK);
    RT_MsgYesNo:
      Result:= (ShowMessageBox(CustomText, CustomTitle, MB_YESNO) = IDYES);
    RT_MsgOKCancel:
      Result:= (ShowMessageBox(CustomText, CustomTitle, MB_OKCANCEL) = IDOK);
    else begin
      Result:= False;
    end;
  end;

  // DCDebug('MainRequestProc ('+IntToStr(PluginNr)+','+IntToStr(RequestType)+','+CustomTitle+','+CustomText+','+ReturnedText+')', BoolToStr(Result, True));
end;

function MainRequestProcA(PluginNr, RequestType: Integer; CustomTitle, CustomText, ReturnedText: PAnsiChar; MaxLen: Integer): Bool; dcpcall;
var
  sCustomTitle,
  sCustomText,
  sReturnedText: String;
begin
  sCustomTitle:= CeSysToUtf8(StrPas(CustomTitle));
  sCustomText:=  CeSysToUtf8(StrPas(CustomText));
  sReturnedText:= CeSysToUtf8(StrPas(ReturnedText));
  Result:= MainRequestProc(PluginNr, RequestType, sCustomTitle, sCustomText, sReturnedText);
  if Result then
    begin
      if ReturnedText <> nil then
        StrPLCopy(ReturnedText, CeUtf8ToSys(sReturnedText), MaxLen);
    end;
end;

function MainRequestProcW(PluginNr, RequestType: Integer; CustomTitle, CustomText, ReturnedText: PWideChar; MaxLen: Integer): Bool; dcpcall;
var
  sCustomTitle,
  sCustomText,
  sReturnedText: String;
begin
  sCustomTitle:= UTF16ToUTF8(UnicodeString(CustomTitle));
  sCustomText:=  UTF16ToUTF8(UnicodeString(CustomText));
  sReturnedText:= UTF16ToUTF8(UnicodeString(ReturnedText));
  Result:= MainRequestProc(PluginNr, RequestType, sCustomTitle, sCustomText, sReturnedText);
  if Result then
    begin
      if ReturnedText <> nil then
        StrPLCopyW(ReturnedText, CeUtf8ToUtf16(sReturnedText), MaxLen);
    end;
end;

function CryptProc({%H-}PluginNr, CryptoNumber: Integer; Mode: Integer; ConnectionName: String; var Password: String): Integer;
const
  cPrefix = 'wfx';
  cResult: array[TCryptStoreResult] of Integer = (FS_FILE_OK, FS_FILE_NOTSUPPORTED, FS_FILE_WRITEERROR, FS_FILE_READERROR, FS_FILE_NOTFOUND);
var
  sGroup,
  sPassword: AnsiString;
  MyResult: TCryptStoreResult;
begin
  MyResult:= csrSuccess;
  sGroup:= WfxOperationList[CryptoNumber];
  case Mode of
  FS_CRYPT_SAVE_PASSWORD:
    begin
      MyResult:= PasswordStore.WritePassword(cPrefix, sGroup, ConnectionName, Password);
    end;
  FS_CRYPT_LOAD_PASSWORD,
  FS_CRYPT_LOAD_PASSWORD_NO_UI:
    begin
      if (Mode = FS_CRYPT_LOAD_PASSWORD_NO_UI) and (PasswordStore.HasMasterKey = False) then
        Exit(FS_FILE_NOTFOUND);
      MyResult:= PasswordStore.ReadPassword(cPrefix, sGroup, ConnectionName, Password);
    end;
  FS_CRYPT_COPY_PASSWORD,
  FS_CRYPT_MOVE_PASSWORD:
    begin
      MyResult:= PasswordStore.ReadPassword(cPrefix, sGroup, ConnectionName, sPassword);
      if MyResult = csrSuccess then
      begin
        MyResult:= PasswordStore.WritePassword(cPrefix, sGroup, Password, sPassword);
        if (MyResult = csrSuccess) and (Mode = FS_CRYPT_MOVE_PASSWORD) then
        begin
          if not PasswordStore.DeletePassword(cPrefix, sGroup, ConnectionName) then
            MyResult:= csrWriteError;
        end;
      end;
    end;
  FS_CRYPT_DELETE_PASSWORD:
    begin
      if not PasswordStore.DeletePassword(cPrefix, sGroup, ConnectionName) then
        MyResult:= csrWriteError;
    end;
  end;
  Result:= cResult[MyResult];
end;

function CryptProcA(PluginNr, CryptoNumber: Integer; Mode: Integer; ConnectionName, Password: PAnsiChar; MaxLen: Integer): Integer; dcpcall;
var
  sConnectionName,
  sPassword: String;
begin
  sConnectionName:= CeSysToUtf8(StrPas(ConnectionName));
  sPassword:= CeSysToUtf8(StrPas(Password));
  Result:= CryptProc(PluginNr, CryptoNumber, Mode, sConnectionName, sPassword);
  if Result = FS_FILE_OK then
    begin
      if Password <> nil then
        StrPLCopy(Password, CeUtf8ToSys(sPassword), MaxLen);
    end;
end;

function CryptProcW(PluginNr, CryptoNumber: Integer; Mode: Integer; ConnectionName, Password: PWideChar; MaxLen: Integer): Integer; dcpcall;
var
  sConnectionName,
  sPassword: String;
begin
  sConnectionName:= UTF16ToUTF8(UnicodeString(ConnectionName));
  sPassword:= UTF16ToUTF8(UnicodeString(Password));
  Result:= CryptProc(PluginNr, CryptoNumber, Mode, sConnectionName, sPassword);
  if Result = FS_FILE_OK then
    begin
      if Password <> nil then
        StrPLCopyW(Password, CeUtf8ToUtf16(sPassword), MaxLen);
    end;
end;

{ TWfxPluginFileSource }

constructor TWfxPluginFileSource.Create(aModuleFileName, aPluginRootName: String);
var
  AFlags: Integer;
begin
  inherited Create;
  FPreviewLock:= SyncObjs.TCriticalSection.Create;
  FPendingPreviewPaths:= TStringList.Create;
  FPendingPreviewPaths.Sorted:= True;
  FPendingPreviewPaths.CaseSensitive:= True;
  FPendingPreviewPaths.Duplicates:= dupIgnore;
  FPreviewNotificationQueued:= False;
  FInvalidateAllPreviews:= False;
  FPreviewRegistered:= False;
  FPluginNumber:= -1;
  FCallbackDataClass:= nil;
  FModuleFileName:= aModuleFileName;
  FPluginRootName:= aPluginRootName;
  FWfxModule:= gWFXPlugins.LoadModule(FModuleFileName);

  if not Assigned(FWfxModule) then
    raise EFileSourceException.Create('Cannot load WFX module ' + FModuleFileName);

  with FWfxModule do
  begin
    FPluginNumber:= WfxOperationList.IndexOf(FPluginRootName);
    if FPluginNumber >= 0 then
    begin
      FCallbackDataClass:= TCallbackDataClass.Create(Self);
      WfxOperationList.Objects[FPluginNumber]:= FCallbackDataClass;
    end
    else begin
      FCallbackDataClass:= TCallbackDataClass.Create(Self);
      FPluginNumber:= WfxOperationList.AddObject(FPluginRootName, FCallbackDataClass);
      if Assigned(FsInit) then
        FsInit(FPluginNumber, @MainProgressProcA, @MainLogProcA, @MainRequestProcA);
      if Assigned(FsInitW) then
        FsInitW(FPluginNumber, @MainProgressProcW, @MainLogProcW, @MainRequestProcW);

      VFSInit;

      if not PasswordStore.MasterKeySet then
        AFlags:= 0
      else begin
        AFlags:= FS_CRYPTOPT_MASTERPASS_SET;
      end;

      if Assigned(FsSetCryptCallbackW) then
        FsSetCryptCallbackW(@CryptProcW, FPluginNumber, AFlags);
      if Assigned(FsSetCryptCallback) then
        FsSetCryptCallback(@CryptProcA, FPluginNumber, AFlags);
    end;
  end;

  FOperationsClasses[fsoList]            := TWfxPluginListOperation.GetOperationClass;
  FOperationsClasses[fsoCopy]            := TWfxPluginCopyOperation.GetOperationClass;
  FOperationsClasses[fsoCopyIn]          := TWfxPluginCopyInOperation.GetOperationClass;
  FOperationsClasses[fsoCopyOut]         := TWfxPluginCopyOutOperation.GetOperationClass;
  FOperationsClasses[fsoMove]            := TWfxPluginMoveOperation.GetOperationClass;
  FOperationsClasses[fsoDelete]          := TWfxPluginDeleteOperation.GetOperationClass;
  FOperationsClasses[fsoCreateDirectory] := TWfxPluginCreateDirectoryOperation.GetOperationClass;
  FOperationsClasses[fsoSetFileProperty] := TWfxPluginSetFilePropertyOperation.GetOperationClass;
  FOperationsClasses[fsoExecute]         := TWfxPluginExecuteOperation.GetOperationClass;

  CreateConnections;
  WfxPreviewSourcesLock.Acquire;
  try
    WfxPreviewSources.Add(Self);
    FPreviewRegistered:= True;
  finally
    WfxPreviewSourcesLock.Release;
  end;
end;

destructor TWfxPluginFileSource.Destroy;
begin
  if FPreviewRegistered then
  begin
    WfxPreviewSourcesLock.Acquire;
    try
      WfxPreviewSources.Remove(Self);
      FPreviewRegistered:= False;
    finally
      WfxPreviewSourcesLock.Release;
    end;
  end;
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FPendingPreviewPaths);
  FreeAndNil(FPreviewLock);
  if (FPluginNumber >= 0) and (FPluginNumber < WfxOperationList.Count) and
     (WfxOperationList.Objects[FPluginNumber] = FCallbackDataClass) then
    WfxOperationList.Objects[FPluginNumber]:= nil;
  FreeAndNil(FCallbackDataClass);
  inherited Destroy;
end;

function TWfxPluginFileSource.FileSystemEntryExists(
  const Path: String;
  const Options: TFileSourceExistsOptions ): TFileSourceExistsResult;

  // faster
  // return True: the directory exists and it's not empty directories
  // return False: no entry / empty directory / regular file
  function notEmptyDirExists: Boolean;
  var
    findData: TWfxFindData;
    handle: THandle;
  begin
    Result:= False;
    handle:= WfxModule.WfxFindFirst(Path, findData);
    if handle = wfxInvalidHandle then
      Exit;
    WfxModule.FsFindClose(handle);
    Result:= True;
  end;

  // slower
  function getFile: TFile;
  var
    parentDir: String;
    filename: String;
    findData: TWfxFindData;
    handle: THandle;
  begin
    Result:= nil;
    parentDir:= DCStrUtils.GetParentDir(Path);
    filename:= DCStrUtils.ExtractFileNameEx(ExcludeTrailingPathDelimiter(Path));
    handle:= WfxModule.WfxFindFirst(parentDir, findData);
    if handle = wfxInvalidHandle then
      Exit;
    try
      repeat
        if findData.FileName <> filename then
          continue;
        Result:= self.CreateFile(Path, findData);
        Exit;
      until (not WfxModule.WfxFindNext(handle, findData));
    finally
      WfxModule.FsFindClose(handle);
    end;
  end;

var
  exists: Boolean;
  f: TFile = nil;
begin
  Result:= TFileSourceExistsResult.notExist;
  if Options = [] then
    Exit;
  if Path = EmptyStr then
    Exit;

  if Path = PathDelim then begin
    if TFileSourceExistsOption.needDir in Options then
      Result:= TFileSourceExistsResult.exists;
    Exit;
  end;

  // note: notEmptyDirExists() should run much faster than getFile()
  exists:= False;
  if TFileSourceExistsOption.needDir in Options then
    exists:= notEmptyDirExists();

  if NOT exists then
    f:= getFile;

  if NOT exists and Assigned(f) then begin
    if TFileSourceExistsOption.needDir in Options then
      exists:= f.IsDirectory;
  end;

  if NOT exists and Assigned(f) then begin
    if TFileSourceExistsOption.needFile in Options then
      exists:= NOT f.IsDirectory;
  end;

  f.Free;

  if exists then
    Result:= TFileSourceExistsResult.exists;
end;

function TWfxPluginFileSource.SetCurrentWorkingDirectory(NewDir: String): Boolean;
begin
  Result := False;
  if Length(NewDir) > 0 then
    Result:= DirectoryExists(self, NewDir);
end;

class function TWfxPluginFileSource.CreateFile(const APath: String): TFile;
begin
  Result := TFile.Create(APath);

  with Result do
  begin
    AttributesProperty := TFileAttributesProperty.CreateOSAttributes;
    SizeProperty := TFileSizeProperty.Create;
    ModificationTimeProperty := TFileModificationDateTimeProperty.Create;
    LastAccessTimeProperty := TFileLastAccessDateTimeProperty.Create;
    CreationTimeProperty := TFileCreationDateTimeProperty.Create;
    LinkProperty := TFileLinkProperty.Create;
  end;
end;

class function TWfxPluginFileSource.CreateFile(const APath: String; FindData: TWfxFindData): TFile;
begin
  Result := TFile.Create(APath);

  with Result do
  begin
    // Check that attributes is used
    if (FindData.FileAttributes and FILE_ATTRIBUTE_UNIX_MODE) = 0 then // Windows attributes
      begin
        LinkProperty := TFileLinkProperty.Create;
        LinkProperty.IsLinkToDirectory :=
            ((FindData.FileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
            ((FindData.FileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0);
        AttributesProperty := TNtfsFileAttributesProperty.Create(FindData.FileAttributes);
      end
    else  // Unix attributes
      begin
        LinkProperty := TFileLinkProperty.Create;
        LinkProperty.IsLinkToDirectory :=
            (((FindData.FileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) or
             ((FindData.FileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0)) and
            ((FindData.Reserved0 and S_IFMT) = S_IFLNK);
        if ((FindData.FileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
           ((FindData.Reserved0 and S_IFMT) <> S_IFDIR) and (not LinkProperty.IsLinkToDirectory) then
          FindData.Reserved0:= FindData.Reserved0 or S_IFDIR;
        AttributesProperty := TUnixFileAttributesProperty.Create(FindData.Reserved0);
      end;

    SizeProperty := TFileSizeProperty.Create(FindData.FileSize);
    SizeProperty.IsValid := (FindData.FileSize >= 0);
    ModificationTimeProperty := TFileModificationDateTimeProperty.Create(FindData.LastWriteTime);
    LastAccessTimeProperty := TFileLastAccessDateTimeProperty.Create(FindData.LastAccessTime);
    CreationTimeProperty := TFileCreationDateTimeProperty.Create(FindData.CreationTime);

    // Set name after assigning Attributes property, because it is used to get extension.
    Name := FindData.FileName;
  end;
end;

procedure TWfxPluginFileSource.RetrieveProperties(AFile: TFile;
  PropertiesToSet: TFilePropertiesTypes; const AVariantProperties: array of String);
var
  AIndex: Integer;
  AProp: TFilePropertyType;
  AVariant: TFileVariantProperty;
begin
  if WfxModule.ContentPlugin then
  begin
    PropertiesToSet:= PropertiesToSet * fpVariantAll;
    for AProp in PropertiesToSet do
    begin
      AIndex:= Ord(AProp) - Ord(fpVariant);
      if (AIndex >= 0) and (AIndex <= High(AVariantProperties)) then
      begin
        AVariant:= TFileVariantProperty.Create(AVariantProperties[AIndex]);
        AVariant.Value:= GetVariantFileProperty(AVariantProperties[AIndex], AFile, Self);
        AFile.Properties[AProp]:= AVariant;
      end;
    end;
  end;
end;

function TWfxPluginFileSource.GetOperationsTypes: TFileSourceOperationTypes;
begin
  with WfxModule do
  begin
    Result := [fsoList, fsoCalcStatistics]; // supports by any plugin
    if Assigned(FsPutFile) or Assigned(FsPutFileW) then
      Result:= Result + [fsoCopyIn];
    if Assigned(FsGetFile) or Assigned(FsGetFileW) then
      Result:= Result + [fsoCopyOut];
    if Assigned(FsRenMovFile) or Assigned(FsRenMovFileW) then
      Result:= Result + [fsoCopy, fsoMove];
    if Assigned(FsDeleteFile) or Assigned(FsDeleteFileW) then
        Result:= Result + [fsoDelete];
    if Assigned(FsMkDir) or Assigned(FsMkDirW) then
        Result:= Result + [fsoCreateDirectory];
    if Assigned(FsExecuteFile) or Assigned(FsExecuteFileW) then
        Result:= Result + [fsoExecute];
    if Assigned(FsSetAttr) or Assigned(FsSetAttrW) or
       Assigned(FsExecuteFile) or Assigned(FsExecuteFileW) or
       Assigned(FsRenMovFile) or Assigned(FsRenMovFileW) then
        Result:= Result + [fsoSetFileProperty];
  end;
end;

function TWfxPluginFileSource.GetProperties: TFileSourceProperties;
begin
  Result := [fspUsesConnections, fspListOnMainThread, fspSynchronizable];
  with FWfxModule do
  begin
    if Assigned(FsLinksToLocalFiles) and FsLinksToLocalFiles() then
      Result:= Result + [fspLinksToLocalFiles];
    if (BackgroundFlags = 0) or (BackgroundFlags and BG_ASK_USER <> 0) then
      Result:= Result + [fspCopyInOnMainThread, fspCopyOutOnMainThread]
    else begin
      if (BackgroundFlags and BG_UPLOAD = 0) then
        Result:= Result + [fspCopyInOnMainThread];
      if (BackgroundFlags and BG_DOWNLOAD = 0) then
        Result:= Result + [fspCopyOutOnMainThread];
    end;
    if Assigned(FsExtractCustomIcon) or Assigned(FsExtractCustomIconW) then
      Result := Result + [fspCustomIcon];
    if Assigned(FsContentGetDefaultView) or Assigned(FsContentGetDefaultViewW) then
      Result := Result + [fspDefaultView];
  end;
end;

function TWfxPluginFileSource.GetFileSystem: String;
begin
  Result:= FPluginRootName;
end;

function TWfxPluginFileSource.GetSupportedFileProperties: TFilePropertiesTypes;
begin
  Result := inherited GetSupportedFileProperties
          + [fpSize, fpAttributes, fpModificationTime, fpCreationTime,
             fpLastAccessTime, fpLink];
end;

function TWfxPluginFileSource.GetRetrievableFileProperties: TFilePropertiesTypes;
begin
  Result:= inherited GetRetrievableFileProperties;
  if WfxModule.ContentPlugin then Result += fpVariantAll;
end;

function TWfxPluginFileSource.GetCurrentAddress: String;
begin
  Result:= 'wfx://' + FPluginRootName;
end;

function TWfxPluginFileSource.GetPluginNumber: LongInt;
begin
  Result := FPluginNumber;
end;

function TWfxPluginFileSource.GetWfxModule: TWfxModule;
begin
  Result := FWFXModule;
end;

function TWfxPluginFileSource.GetPluginRootName: String;
begin
  Result:= FPluginRootName;
end;

function TWfxPluginFileSource.GetPendingPreviewPaths: TStringArray;
var
  Index: Integer;
begin
  Result:= nil;
  FPreviewLock.Acquire;
  try
    SetLength(Result, FPendingPreviewPaths.Count);
    for Index:= 0 to FPendingPreviewPaths.Count - 1 do
      Result[Index]:= FPendingPreviewPaths[Index];
  finally
    FPreviewLock.Release;
  end;
end;

procedure TWfxPluginFileSource.FillAndCount(Files: TFiles; CountDirs: Boolean;
  ExcludeRootDir: Boolean; out NewFiles: TFiles; out FilesCount: Int64; out FilesSize: Int64);

  procedure FillAndCountRec(const srcPath: String);
  var
    FindData: TWfxFindData;
    Handle: THandle;
    aFile: TFile;
  begin
    with FWfxModule do
    begin
      Handle := WfxFindFirst(srcPath, FindData);
      if Handle = wfxInvalidHandle then Exit;

      repeat
        if (FindData.FileName = '.') or (FindData.FileName = '..') then Continue;
        aFile:= TWfxPluginFileSource.CreateFile(srcPath, FindData);
        NewFiles.Add(aFile);

        if aFile.IsDirectory then
          begin
            if CountDirs then
              Inc(FilesCount);
            FillAndCountRec(srcPath + FindData.FileName + PathDelim);
          end
        else
          begin
            Inc(FilesSize, aFile.Size);
            Inc(FilesCount);
          end;
      until not WfxFindNext(Handle, FindData);

      FsFindClose(Handle);
    end;
  end;

var
  I: Integer;
  aFile: TFile;
begin
  FilesCount:= 0;
  FilesSize:= 0;

  if ExcludeRootDir then
  begin
    if Files.Count <> 1 then
      raise Exception.Create('Only a single directory can be set with ExcludeRootDir=True');
    NewFiles := TFiles.Create(Files[0].FullPath);
    FillAndCountRec(Files[0].FullPath + DirectorySeparator);
  end
  else
  begin
    NewFiles := TFiles.Create(Files.Path);
    for I := 0 to Files.Count - 1 do
    begin
      aFile := Files[I];

      NewFiles.Add(aFile.Clone);

      if aFile.AttributesProperty.IsDirectory and (not aFile.LinkProperty.IsLinkToDirectory) then
        begin
          if CountDirs then
            Inc(FilesCount);
          FillAndCountRec(aFile.Path + aFile.Name + DirectorySeparator);  // recursive browse child dir
        end
      else
        begin
          Inc(FilesCount);
          Inc(FilesSize, aFile.Size); // in first level we know file size -> use it
        end;
    end;
  end;
end;

function TWfxPluginFileSource.FillSingleFile(const FullPath: String; out aFile: TFile): Boolean;
var
  FilePath, ExpectedFileName: String;
  FindData: TWfxFindData;
  Handle: THandle;
begin
  Result := False;
  aFile := nil;
  FilePath := ExtractFilePath(FullPath);
  ExpectedFileName := ExtractFileName(FullPath);
  with FWfxModule do
  begin
    Handle := WfxFindFirst(FilePath, FindData);
    if Handle = wfxInvalidHandle then Exit;

    repeat
      if (FindData.FileName = ExpectedFileName) then
      begin
        aFile := TWfxPluginFileSource.CreateFile(FilePath, FindData);
        Result := True;
        Break;
      end;
    until not WfxFindNext(Handle, FindData);

    FsFindClose(Handle);
  end;
end;

function TWfxPluginFileSource.WfxCopyMove(sSourceFile, sTargetFile: String;
                                          Flags: LongInt; RemoteInfo: PRemoteInfo;
                                          Internal, CopyMoveIn: Boolean): LongInt;
var
  bMove,
  bOverWrite: Boolean;
begin
  with FWfxModule do
  begin
    if Internal then
      begin
        bMove:= ((Flags and FS_COPYFLAGS_MOVE) <> 0);
        bOverWrite:= ((Flags and FS_COPYFLAGS_OVERWRITE) <> 0);
        Result:= WfxRenMovFile(sSourceFile, sTargetFile, bMove, bOverWrite, RemoteInfo);
      end
    else
      begin
        if CopyMoveIn then
          Result:= WfxPutFile(sSourceFile, sTargetFile, Flags)
        else
          Result:= WfxGetFile(sSourceFile, sTargetFile, Flags, RemoteInfo);
      end;
  end;
end;

constructor TWfxPluginFileSource.Create(const URI: TURI);
var
  Index: Integer;
begin
  // Check if there is a registered plugin for the name of the file system plugin.
  Index:= gWFXPlugins.FindFirstEnabledByName(URI.Host);
  if Index < 0 then begin
    raise EFileSourceException.Create('Cannot find Wfx module ' + URI.Host);
  end;
  Create(gWFXPlugins.FileName[Index], URI.Host);
  DCDebug('Found registered plugin ' + gWFXPlugins.FileName[Index] + ' for file system ' + URI.Host);
end;

function TWfxPluginFileSource.CreateListOperation(TargetPath: String): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWfxPluginListOperation.Create(TargetFileSource, TargetPath);
end;

function TWfxPluginFileSource.CreateCopyOperation(var SourceFiles: TFiles;
                                                  TargetPath: String): TFileSourceOperation;
var
  FileSource: IFileSource;
begin
  FileSource := Self;
  Result := TWfxPluginCopyOperation.Create(FileSource, FileSource, SourceFiles, TargetPath);
end;

function TWfxPluginFileSource.CreateCopyInOperation(
           SourceFileSource: IFileSource;
           var SourceFiles: TFiles;
           TargetPath: String): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWfxPluginCopyInOperation.Create(SourceFileSource,
                                              TargetFileSource,
                                              SourceFiles, TargetPath);
end;

function TWfxPluginFileSource.CreateCopyOutOperation(
            TargetFileSource: IFileSource;
            var SourceFiles: TFiles;
            TargetPath: String): TFileSourceOperation;
var
  SourceFileSource: IFileSource;
begin
  SourceFileSource := Self;
  Result := TWfxPluginCopyOutOperation.Create(SourceFileSource,
                                              TargetFileSource,
                                              SourceFiles, TargetPath);
end;

function TWfxPluginFileSource.CreateMoveOperation(var SourceFiles: TFiles;
                                                      TargetPath: String): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWfxPluginMoveOperation.Create(TargetFileSource, SourceFiles, TargetPath);
end;

function TWfxPluginFileSource.CreateDeleteOperation(var FilesToDelete: TFiles): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWfxPluginDeleteOperation.Create(TargetFileSource, FilesToDelete);
end;

function TWfxPluginFileSource.CreateCreateDirectoryOperation(BasePath: String; DirectoryPath: String): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWfxPluginCreateDirectoryOperation.Create(TargetFileSource, BasePath, DirectoryPath);
end;

function TWfxPluginFileSource.CreateExecuteOperation(var ExecutableFile: TFile; BasePath, Verb: String): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result:=  TWfxPluginExecuteOperation.Create(TargetFileSource, ExecutableFile, BasePath, Verb);
end;

function TWfxPluginFileSource.CreateSetFilePropertyOperation(
             var theTargetFiles: TFiles;
             var theNewProperties: TFileProperties): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWfxPluginSetFilePropertyOperation.Create(
                TargetFileSource,
                theTargetFiles,
                theNewProperties);
end;

function TWfxPluginFileSource.CreateCalcStatisticsOperation(var theFiles: TFiles): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWfxPluginCalcStatisticsOperation.Create(TargetFileSource, theFiles);
end;

function TWfxPluginFileSource.GetLocalName(var aFile: TFile): Boolean;
var
  sFileName: String;
begin
  Result:= False;
  sFileName:= aFile.FullPath;
  if FWfxModule.WfxGetLocalName(sFileName) then
    begin
      aFile.FullPath:= sFileName;
      Result:= True;
    end;
end;

function TWfxPluginFileSource.CreateDirectory(const Path: String): Boolean;
var
  parentPath: String;
begin
  parentPath:= ExtractFilePath(Path);
  Result:= WfxModule.WfxMkDir(parentPath, Path) = WFX_SUCCESS;
  if Result then
  begin
    if (log_vfs_op in gLogOptions) and (log_success in gLogOptions) then
      logWrite(Format(rsMsgLogSuccess + rsMsgLogMkDir, [Path]), lmtSuccess);
    self.Reload(parentPath);
  end
  else begin
    if (log_vfs_op in gLogOptions) and (log_errors in gLogOptions) then
      logWrite(Format(rsMsgLogError + rsMsgLogMkDir, [Path]), lmtError);
  end;
end;

function TWfxPluginFileSource.GetDefaultView(out DefaultView: TFileSourceFields): Boolean;
begin
  Result:= FWFXModule.WfxContentGetDefaultView(DefaultView);
end;

procedure TWfxPluginFileSource.RememberPreviewMiss(const APath: String);
begin
  if APath = EmptyStr then Exit;
  FPreviewLock.Acquire;
  try
    if FPendingPreviewPaths.IndexOf(APath) < 0 then
      FPendingPreviewPaths.Add(APath);
  finally
    FPreviewLock.Release;
  end;
end;

procedure TWfxPluginFileSource.ForgetPreviewMiss(const APath: String);
var
  Index: Integer;
begin
  FPreviewLock.Acquire;
  try
    Index:= FPendingPreviewPaths.IndexOf(APath);
    if Index >= 0 then FPendingPreviewPaths.Delete(Index);
  finally
    FPreviewLock.Release;
  end;
end;

procedure TWfxPluginFileSource.QueuePreviewInvalidation(AInvalidateAll: Boolean);
var
  QueueCall: Boolean;
begin
  QueueCall:= False;
  FPreviewLock.Acquire;
  try
    if AInvalidateAll then FInvalidateAllPreviews:= True;
    if (FInvalidateAllPreviews or (FPendingPreviewPaths.Count > 0)) and
       not FPreviewNotificationQueued then
    begin
      FPreviewNotificationQueued:= True;
      QueueCall:= True;
    end;
  finally
    FPreviewLock.Release;
  end;
  if QueueCall then
    Application.QueueAsyncCall(@DeliverPreviewInvalidation, 0);
end;

procedure TWfxPluginFileSource.DeliverPreviewInvalidation({%H-}Data: PtrInt);
var
  Index: Integer;
  InvalidateAll: Boolean;
  Paths: TPathsArray;
  Params: TFileSourceEventParams;
begin
  FPreviewLock.Acquire;
  try
    InvalidateAll:= FInvalidateAllPreviews;
    if not InvalidateAll then
    begin
      SetLength(Paths, FPendingPreviewPaths.Count);
      for Index:= 0 to FPendingPreviewPaths.Count - 1 do
        Paths[Index]:= FPendingPreviewPaths[Index];
    end;
    FPendingPreviewPaths.Clear;
    FInvalidateAllPreviews:= False;
    FPreviewNotificationQueued:= False;
  finally
    FPreviewLock.Release;
  end;
  if not InvalidateAll and (Length(Paths) = 0) then Exit;
  Params.eventType:= TFileSourceEventType.previewInvalidated;
  Params.fs:= Self;
  Params.paths:= Paths;
  eventNotify(Params);
  if Length(Paths) = 0 then
    DebugRpcRecord('thumbnail', 'invalidate', EmptyStr, 'all', EmptyStr, 0,
      Length(Paths), 'plugin preview-ready')
  else
    for Index:= 0 to High(Paths) do
      DebugRpcRecord('thumbnail', 'invalidate', Paths[Index], 'path',
        EmptyStr, 0, Length(Paths), 'plugin preview-ready');
  DCDebug(['RemoteThumbnailHostBridge invalidated previews=', Length(Paths),
    ' all=', InvalidateAll]);
end;

function TWfxPluginFileSource.SupportsPreviewBitmap: Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result:= Assigned(FWfxModule.FsGetPreviewBitmapW) or
           Assigned(FWfxModule.FsGetPreviewBitmap);
  {$ELSE}
  Result:= False;
  {$ENDIF}
end;

function TWfxPluginFileSource.GetPreviewBitmap(aFile: TFile; const ASize: TSize;
  out ABitmap: TBitmap; out ACacheKey: String; out ACacheable: Boolean): Boolean;
{$IFDEF MSWINDOWS}
var
  NativeBitmap: WfxPlugin.HBITMAP;
  RemoteName, Drive: String;
  Status, DriveKind: Integer;
  Picture: TPicture;
  Stream: TFileStreamEx;
  DecodeStarted: QWord;
  PreviewSource: String;
{$ENDIF}
begin
  ABitmap:= nil;
  ACacheKey:= EmptyStr;
  ACacheable:= False;
  Result:= SupportsPreviewBitmap;
  if not Result then Exit;
  {$IFDEF MSWINDOWS}
  if aFile.IsDirectory then Exit;
  NativeBitmap:= 0;
  Status:= FS_BITMAP_NONE;
  PreviewSource:= 'wfx_provider';
  RemoteName:= aFile.FullPath;
  try
    try
    Status:= FWfxModule.WfxGetPreviewBitmap(RemoteName, ASize.cx, ASize.cy, NativeBitmap);
    PreviewSource:= EmptyStr;
    case Status and $FF of
      FS_BITMAP_NONE:
        begin
          RememberPreviewMiss(aFile.FullPath);
          DebugRpcRecord('thumbnail', 'preview.miss', aFile.FullPath,
            'wfx_none', EmptyStr, 0, Status);
          Exit;
        end;
      FS_BITMAP_EXTRACTED:
        begin
          if NativeBitmap = 0 then
          begin
            DebugRpcRecord('wfx', 'bitmap.return', aFile.FullPath, 'invalid',
              'plugin returned a null HBITMAP', 0, Status);
            Exit;
          end;
          DecodeStarted:= GetTickCount64;
          ABitmap:= BitmapCreateFromHBITMAP(NativeBitmap);
          PreviewSource:= 'wfx_hbitmap';
          {$IFDEF LCLWIN32}
          { The Win32 wrapper takes ownership; its TBitmap will DeleteObject. }
          NativeBitmap:= 0;
          {$ENDIF}
          if not Assigned(ABitmap) then
          begin
            DebugRpcRecord('wfx', 'bitmap.decode', aFile.FullPath, 'error',
              'host could not wrap HBITMAP', GetTickCount64 - DecodeStarted,
              Status, PreviewSource);
            Exit;
          end;
          if (ABitmap.Width <= 0) or (ABitmap.Height <= 0) or
             (ABitmap.Width > 8192) or (ABitmap.Height > 8192) then
          begin
            DebugRpcRecord('wfx', 'bitmap.decode', aFile.FullPath, 'error',
              'HBITMAP dimensions are invalid', GetTickCount64 - DecodeStarted,
              Status, PreviewSource);
            FreeAndNil(ABitmap);
            Exit;
          end;
        end;
      FS_BITMAP_EXTRACT_YOURSELF:
        begin
          PreviewSource:= 'wfx_local_file';
          DecodeStarted:= GetTickCount64;
          { This path is a plugin-selected local preview, never the remote
            original. Reject UNC/relative paths and mapped network drives. }
          Drive:= ExtractFileDrive(RemoteName);
          if (Length(Drive) <> 2) or (Drive[2] <> ':') or
             (Length(RemoteName) < 3) or not (RemoteName[3] in ['\', '/']) then Exit;
          DriveKind:= Windows.GetDriveTypeW(PWideChar(UTF8ToUTF16(Drive + '\')));
          if not (DriveKind in [DRIVE_FIXED, DRIVE_REMOVABLE, DRIVE_RAMDISK, DRIVE_CDROM]) then Exit;
          Stream:= TFileStreamEx.Create(RemoteName, fmOpenRead or fmShareDenyNone);
          try
            if (Stream.Size <= 0) or (Stream.Size > 16 * 1024 * 1024) then Exit;
            Picture:= TPicture.Create;
            try
              Picture.LoadFromStreamWithFileExt(Stream, ExtractFileExt(RemoteName));
              if (Picture.Width <= 0) or (Picture.Height <= 0) or
                 (Picture.Width > 4096) or (Picture.Height > 4096) then Exit;
              ABitmap:= TBitmap.Create;
              ABitmap.Assign(Picture.Graphic);
            finally
              Picture.Free;
            end;
          finally
            Stream.Free;
          end;
        end;
      { ANDDELETE and unknown values are deliberately not decoded/deleted. This
        read-only bridge never unlinks a shared PC cache object. }
      else Exit;
    end;
    if Assigned(ABitmap) then
    begin
      ForgetPreviewMiss(aFile.FullPath);
      ACacheable:= (Status and FS_BITMAP_CACHE) <> 0;
      { Qualify plugin-provided device/UUID/profile/hash identity, not mtime. }
      ACacheKey:= FModuleFileName + #0 + FPluginRootName + #0 + RemoteName;
      DebugRpcRecord('wfx', 'bitmap.decode', aFile.FullPath, 'success',
        EmptyStr, GetTickCount64 - DecodeStarted, Status, PreviewSource);
      if PreviewSource = 'wfx_local_file' then
        DebugRpcRecord('wfx', 'bitmap.return', aFile.FullPath,
          'host_bitmap', EmptyStr, 0, Status, PreviewSource);
      DebugRpcRecord('thumbnail', 'host.receive', aFile.FullPath,
        PreviewSource, EmptyStr, 0, Status, 'cacheable=' +
        BoolToStr(ACacheable, True));
    end;
  except
    on E: Exception do
    begin
      DebugRpcRecord('wfx', 'bitmap.decode', aFile.FullPath, 'error',
        E.Message, 0, Status, PreviewSource);
      FreeAndNil(ABitmap);
      ACacheKey:= EmptyStr;
      ACacheable:= False;
    end;
  end;
  { Other Windows widgetsets copied pixels; rejected/exceptional handles
    remain owned here. Never use both a wrapper destructor and DeleteObject. }
  finally
    if NativeBitmap <> 0 then Windows.DeleteObject(NativeBitmap);
  end;
  {$ENDIF}
end;

function TWfxPluginFileSource.GetCustomIcon(aFile: TFile; AIconSize: Integer;
  out AIcon: TBitmap): PtrInt;
var
  Status: Integer;
  TheIcon: TWfxIcon;
  AIconName: String;
  UniqueName: String;
begin
  AIconName:= aFile.FullPath;
  if aFile.IsDirectory then AIconName+= PathDelim;
  Status:= FWfxModule.WfxExtractCustomIcon(AIconName, AIconSize, TheIcon);

  if Status in [FS_ICON_EXTRACTED, FS_ICON_EXTRACTED_DESTROY] then
  begin
    if AIconName <> aFile.FullPath then
    begin
      case TheIcon.Format of
        FS_ICON_FORMAT_HICON,
        FS_ICON_FORMAT_BINARY:
        begin
          UniqueName:= FPluginRootName + AIconName;
        end
        else begin
          UniqueName:= AIconName
        end;
      end;
    end
    else begin
      UniqueName:= EmptyStr;
    end;
    Result:= PixmapManager.CheckAddPixmap(UniqueName, AIconSize, (Status = FS_ICON_EXTRACTED_DESTROY), @TheIcon, AIcon);
  end
  else begin
    Result:= -1;
    AIcon:= nil;
  end;
end;

function TWfxPluginFileSource.GetCustomIcon(const path: String; const iconSize: Integer): TBitmap;
var
  aFile: TFile;
  index: Integer;
begin
  aFile:= TFile.Create( path );
  index:= self.GetCustomIcon( aFile, iconSize, Result );
  aFile.Free;
  if Assigned(result) then
    Exit;
  if index >= 0 then
    Result:= PixMapManager.GetBitmap( index );
end;

class function TWfxPluginFileSource.IsSupportedPath(const Path: String): Boolean;
begin
  Result:= Pos('wfx://', Path) = 1;
end;

class function TWfxPluginFileSource.CreateByRootName(aRootName: String): IWfxPluginFileSource;
var
  Index: Integer;
begin
  Result:= nil;
  if gWFXPlugins.Count = 0 then Exit;

  // Check if there is a registered plugin for the name of the file system plugin.
  Index:= gWFXPlugins.FindFirstEnabledByName(aRootName);
  if Index >= 0 then
  begin
    Result:= TWfxPluginFileSource.Create(gWFXPlugins.FileName[Index], aRootName);
    DCDebug('Found registered plugin ' + gWFXPlugins.FileName[Index] + ' for file system ' + aRootName);
  end;
end;

procedure TWfxPluginFileSource.AddToConnectionQueue(Operation: TFileSourceOperation);
begin
  WfxOperationsQueueLock.Acquire;
  try
    if WfxOperationsQueue.IndexOf(Operation) < 0 then
      WfxOperationsQueue.Add(Operation);
  finally
    WfxOperationsQueueLock.Release;
  end;
end;

procedure TWfxPluginFileSource.RemoveFromConnectionQueue(Operation: TFileSourceOperation);
begin
  WfxOperationsQueueLock.Acquire;
  try
    WfxOperationsQueue.Remove(Operation);
  finally
    WfxOperationsQueueLock.Release;
  end;
end;

procedure TWfxPluginFileSource.AddConnection(Connection: TFileSourceConnection);
begin
  WfxConnectionsLock.Acquire;
  try
    if WfxConnections.IndexOf(Connection) < 0 then
      WfxConnections.Add(Connection);
  finally
    WfxConnectionsLock.Release;
  end;
end;

procedure TWfxPluginFileSource.RemoveConnection(Connection: TFileSourceConnection);
begin
  WfxConnectionsLock.Acquire;
  try
    WfxConnections.Remove(Connection);
  finally
    WfxConnectionsLock.Release;
  end;
end;

function TWfxPluginFileSource.GetConnection(Operation: TFileSourceOperation): TFileSourceConnection;
begin
  Result := nil;
  case Operation.ID of
    fsoCopy,
    fsoMove:
      Result := WfxConnections[connCopyMove] as TFileSourceConnection;
    fsoCopyIn:
      Result := WfxConnections[connCopyIn] as TFileSourceConnection;
    fsoCopyOut:
      Result := WfxConnections[connCopyOut] as TFileSourceConnection;
    fsoDelete:
      Result := WfxConnections[connDelete] as TFileSourceConnection;
    else
      begin
        Result := CreateConnection;
        if Assigned(Result) then
          AddConnection(Result);
      end;
  end;

  if Assigned(Result) then
    Result := TryAcquireConnection(Result, Operation);

  // No available connection - wait.
  if not Assigned(Result) then
    AddToConnectionQueue(Operation)
  else
    // Connection acquired.
    // The operation may have been waiting in the queue
    // for the connection, so remove it from the queue.
    RemoveFromConnectionQueue(Operation);
end;

procedure TWfxPluginFileSource.RemoveOperationFromQueue(Operation: TFileSourceOperation);
begin
  RemoveFromConnectionQueue(Operation);
end;

function TWfxPluginFileSource.CreateConnection: TFileSourceConnection;
begin
  Result := TWfxPluginFileSourceConnection.Create(FWfxModule);
end;

procedure TWfxPluginFileSource.CreateConnections;
begin
  WfxConnectionsLock.Acquire;
  try
    if WfxConnections.Count = 0 then
    begin
      // Reserve some connections (only once).
      WfxConnections.Add(CreateConnection); // connCopyIn
      WfxConnections.Add(CreateConnection); // connCopyOut
      WfxConnections.Add(CreateConnection); // connDelete
      WfxConnections.Add(CreateConnection); // connCopyMove
    end;
  finally
    WfxConnectionsLock.Release;
  end;
end;

function TWfxPluginFileSource.FindConnectionByOperation(operation: TFileSourceOperation): TFileSourceConnection;
var
  i: Integer;
  connection: TFileSourceConnection;
begin
  Result := nil;
  WfxConnectionsLock.Acquire;
  try
    for i := 0 to WfxConnections.Count - 1 do
    begin
      connection := WfxConnections[i] as TFileSourceConnection;
      if connection.AssignedOperation = operation then
        Exit(connection);
    end;
  finally
    WfxConnectionsLock.Release;
  end;
end;

procedure TWfxPluginFileSource.OperationFinished(Operation: TFileSourceOperation);
var
  allowedIDs: TFileSourceOperationTypes = [];
  connection: TFileSourceConnection;
begin
  connection := FindConnectionByOperation(Operation);
  if Assigned(connection) then
  begin
    connection.Release; // unassign operation

    WfxConnectionsLock.Acquire;
    try
      // If there are operations waiting, take the first one and notify
      // that a connection is available.
      // Only check operation types for which there are reserved connections.
      if Operation.ID in [fsoCopyIn, fsoCopyOut, fsoDelete, fsoCopy, fsoMove] then
      begin
        Include(allowedIDs, Operation.ID);
        NotifyNextWaitingOperation(allowedIDs);
      end
      else
      begin
        WfxConnections.Remove(connection);
      end;

    finally
      WfxConnectionsLock.Release;
    end;
  end;
end;

procedure TWfxPluginFileSource.NotifyNextWaitingOperation(allowedOps: TFileSourceOperationTypes);
var
  i: Integer;
  operation: TFileSourceOperation;
begin
  WfxOperationsQueueLock.Acquire;
  try
    for i := 0 to WfxOperationsQueue.Count - 1 do
    begin
      operation := WfxOperationsQueue.Items[i] as TFileSourceOperation;
      if (operation.State = fsosWaitingForConnection) and
         (operation.ID in allowedOps) then
      begin
        operation.ConnectionAvailableNotify;
        Exit;
      end;
    end;
  finally
    WfxOperationsQueueLock.Release;
  end;
end;

{ TWfxPluginFileSourceConnection }

constructor TWfxPluginFileSourceConnection.Create(aWfxModule: TWfxModule);
begin
  FWfxModule := aWfxModule;
  inherited Create;
end;

{ TCallbackDataClass }

constructor TCallbackDataClass.Create(aFileSource: TWfxPluginFileSource);
begin
  inherited Create;
  FileSource:= aFileSource;
  UpdateProgressFunction:= nil;
end;

initialization
  WfxPreviewSources:= TFPList.Create;
  WfxPreviewSourcesLock:= SyncObjs.TCriticalSection.Create;
  WfxOperationList:= TStringList.Create;
  WfxConnections := TObjectList.Create(True); // True = destroy objects when destroying list
  WfxConnectionsLock := SyncObjs.TCriticalSection.Create;
  WfxOperationsQueue := TObjectList.Create(False); // False = don't destroy operations (only store references)
  WfxOperationsQueueLock := SyncObjs.TCriticalSection.Create;
  RegisterVirtualFileSource('WfxPlugin', '', TWfxPluginFileSource, False);

finalization
  FreeAndNil(WfxOperationList);
  FreeAndNil(WfxPreviewSources);
  FreeAndNil(WfxPreviewSourcesLock);
  FreeAndNil(WfxConnections);
  FreeAndNil(WfxConnectionsLock);
  FreeAndNil(WfxOperationsQueue);
  FreeAndNil(WfxOperationsQueueLock);

end.
