unit uRemoteThumbnailDirectory;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, LCLType, uFileView;

const
  RemoteThumbnailCanConfigure = 1;
  RemoteThumbnailCanReadStatus = 2;
  RemoteThumbnailCanMutate = 4;
  RemoteThumbnailCanResume = 8;

function RemoteThumbnailDirectoryCapabilities(AView: TFileView): Integer;
function CanControlRemoteThumbnailDirectory(AView: TFileView): Boolean;
function RequestRemoteThumbnailDirectory(AView: TFileView; const AAction: String;
  var ARequestId: String; AParent: HWND): Boolean;
function ResumeRemoteThumbnailDirectory(AView: TFileView; const ARequestId: String;
  AParent: HWND): Boolean;
function LastRemoteThumbnailDirectoryRequestId: String;
function RemoteThumbnailDirectoryStatus(AView: TFileView; const ARequestId: String): String;
function ConfigureRemoteThumbnailDirectory(AView: TFileView; AParent: HWND): Boolean;

implementation

uses
  DynLibs, LazUTF8, WfxPlugin, uWfxPluginFileSource, uWfxModule;

type
  TDirectoryStatusW = function(RequestId, ReturnedJson: PWideChar; Capacity: Integer): Integer;
    {$IFDEF MSWINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
  TDirectoryCapabilitiesW = function(RemoteName: PWideChar): Integer;
    {$IFDEF MSWINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}

var
  LatestRequestId: String = '';

function CanonicalRequestId(const AValue: String): Boolean;
var Index: Integer;
begin
  Result:= False;
  if Length(AValue) <> 36 then Exit;
  for Index:= 1 to Length(AValue) do
    if Index in [9, 14, 19, 24] then
    begin
      if AValue[Index] <> '-' then Exit;
    end
    else if not (AValue[Index] in ['0'..'9', 'a'..'f']) then Exit;
  Result:= True;
end;

function Source(AView: TFileView): IWfxPluginFileSource;
begin
  if not Assigned(AView) or not Supports(AView.FileSource, IWfxPluginFileSource, Result) or
     not Assigned(Result.WfxModule) then
    raise Exception.Create('Remote thumbnail directory control requires an active WFX/SFTP panel');
end;

function RemoteThumbnailDirectoryCapabilities(AView: TFileView): Integer;
var
  Wfx: IWfxPluginFileSource;
  Callback: TDirectoryCapabilitiesW;
  Directory: UnicodeString;
begin
  Result:= 0;
  if not Assigned(AView) or not Supports(AView.FileSource, IWfxPluginFileSource, Wfx) or
     not Assigned(Wfx.WfxModule) then Exit;
  Pointer(Callback):= GetProcAddress(Wfx.WfxModule.ModuleHandle, 'RemoteThumbnailDirectoryCapabilitiesW');
  if Assigned(Callback) then
  begin
    Directory:= UTF8Decode(AView.CurrentPath);
    try
      Result:= Callback(PWideChar(Directory));
    except
      Result:= 0;
    end;
  end
  else if Assigned(GetProcAddress(Wfx.WfxModule.ModuleHandle, 'RemoteThumbnailDirectoryStatusW')) then
    Result:= RemoteThumbnailCanReadStatus; // Never infer mutation support from a status export.
end;

function CanControlRemoteThumbnailDirectory(AView: TFileView): Boolean;
begin
  Result:= (RemoteThumbnailDirectoryCapabilities(AView) and RemoteThumbnailCanMutate) <> 0;
end;

function RequestRemoteThumbnailDirectory(AView: TFileView; const AAction: String;
  var ARequestId: String; AParent: HWND): Boolean;
var
  Wfx: IWfxPluginFileSource;
  Identity: TGUID;
  Directory: String;
begin
  if (AAction <> 'add') and (AAction <> 'remove') and (AAction <> 'refresh') then
    raise Exception.Create('action must be add, remove, or refresh');
  if ARequestId = '' then
  begin
    if CreateGUID(Identity) <> 0 then raise Exception.Create('Cannot generate directory request UUID');
    ARequestId:= Copy(LowerCase(GUIDToString(Identity)), 2, 36);
  end;
  if not CanonicalRequestId(ARequestId) then raise Exception.Create('request_id must be a canonical lowercase UUID');
  Wfx:= Source(AView);
  if not CanControlRemoteThumbnailDirectory(AView) then
    raise Exception.Create('Enable directory indexing on the mapped SFTP connection; a key/agent and supported provider are required');
  Directory:= AView.CurrentPath;
  Result:= Wfx.WfxModule.WfxExecuteFile(AParent, Directory,
    'remotethumbnail.index.' + AAction + ':' + ARequestId) = FS_EXEC_OK;
  if Result then LatestRequestId:= ARequestId;
end;

function ResumeRemoteThumbnailDirectory(AView: TFileView; const ARequestId: String;
  AParent: HWND): Boolean;
var Wfx: IWfxPluginFileSource; Directory: String;
begin
  if not CanonicalRequestId(ARequestId) then raise Exception.Create('Recovery requires the original canonical request UUID');
  Wfx:= Source(AView);
  if (RemoteThumbnailDirectoryCapabilities(AView) and RemoteThumbnailCanResume) = 0 then
    raise Exception.Create('Read-only recovery requires the original SFTP connection and key/agent; no command submitted');
  Directory:= AView.CurrentPath;
  Result:= Wfx.WfxModule.WfxExecuteFile(AParent, Directory,
    'remotethumbnail.index.resume:' + ARequestId) = FS_EXEC_OK;
  if Result then LatestRequestId:= ARequestId;
end;

function LastRemoteThumbnailDirectoryRequestId: String;
begin
  Result:= LatestRequestId;
end;

function RemoteThumbnailDirectoryStatus(AView: TFileView; const ARequestId: String): String;
var
  Wfx: IWfxPluginFileSource;
  Callback: TDirectoryStatusW;
  Request: UnicodeString;
  Buffer: array[0..65535] of WideChar;
begin
  if (ARequestId <> '') and not CanonicalRequestId(ARequestId) then
    raise Exception.Create('request_id must be a canonical lowercase UUID');
  Wfx:= Source(AView);
  Pointer(Callback):= GetProcAddress(Wfx.WfxModule.ModuleHandle, 'RemoteThumbnailDirectoryStatusW');
  if not Assigned(Callback) then raise Exception.Create('Directory task status export is unavailable');
  Request:= UTF8Decode(ARequestId);
  FillChar(Buffer, SizeOf(Buffer), 0);
  if Callback(PWideChar(Request), @Buffer[0], Length(Buffer)) <> 1 then
    raise Exception.Create('Cannot read directory task status');
  Result:= UTF8Encode(UnicodeString(PWideChar(@Buffer[0])));
end;

function ConfigureRemoteThumbnailDirectory(AView: TFileView; AParent: HWND): Boolean;
var Wfx: IWfxPluginFileSource; Directory: String;
begin
  Wfx:= Source(AView);
  if (RemoteThumbnailDirectoryCapabilities(AView) and RemoteThumbnailCanConfigure) = 0 then
    raise Exception.Create('PhotoThumbSync settings are unavailable for this file source');
  Directory:= AView.CurrentPath;
  Result:= Wfx.WfxModule.WfxExecuteFile(AParent, Directory, 'remotethumbnail.configure') = FS_EXEC_OK;
end;

end.
