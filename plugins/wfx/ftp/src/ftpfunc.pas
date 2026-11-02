{
   Double commander
   -------------------------------------------------------------------------
   Wfx plugin for working with File Transfer Protocol

   Copyright (C) 2009-2026 Alexander Koblov (alexx2000@mail.ru)

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free Software
   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA
}

unit FtpFunc;

{$mode delphi}{$H+}
{$include calling.inc}

interface

uses
  SysUtils, Classes,
  WfxPlugin, Extension;

type

  { TConnection }

  TConnection = class
  public
    ConnectionName, Path, Host: AnsiString;
    Port: AnsiString;
    UserName: AnsiString;
    Password: AnsiString;
    MasterPassword: Boolean;
    CachedPassword: AnsiString;
    Proxy: String;
    PassiveMode: Boolean;
    CopySCP: Boolean;
    OnlySCP: Boolean;
    AutoTLS: Boolean;
    FullSSL: Boolean;
    OpenSSH: Boolean;
    AgentSSH: Boolean;
    UseAllocate: Boolean;
    Encoding: AnsiString;
    Fingerprint: AnsiString;
    InitCommands: AnsiString;
    ShowHiddenItems: Boolean;
    PasswordChanged: Boolean;
    KeepAliveTransfer: Boolean;
    PublicKey, PrivateKey: String;
    RemoteThumbnailEnabled: Boolean;
    RemoteThumbnailVolumeId: AnsiString;
    RemoteThumbnailRemoteRoot: AnsiString;
    RemoteThumbnailCatalogRoot: AnsiString;
    RemoteThumbnailIndexEnabled: Boolean;
    RemoteThumbnailBackend: AnsiString;
    RemoteThumbnailProtocolRoot: AnsiString;
    RemoteThumbnailTermuxConfig: AnsiString;
    RemoteThumbnailTermuxCli: AnsiString;
    RemoteThumbnailKnownHosts: String;
    RemoteThumbnailControlTransport: AnsiString;
  public
    constructor Create;
    procedure Assign(Connection: TConnection);
  end;

function FsInitW(PluginNr: Integer; pProgressProc: TProgressProcW;
  pLogProc: TLogProcW; pRequestProc: TRequestProcW): Integer; dcpcall; export;

function FsFindFirstW(Path: PWideChar; var FindData: TWin32FindDataW): THandle; dcpcall; export;
function FsFindNextW(Hdl: THandle; var FindData: TWin32FindDataW): BOOL; dcpcall; export;
function FsFindClose(Hdl: THandle): Integer; dcpcall; export;

function FsExecuteFileW(MainWin: THandle; RemoteName, Verb: PWideChar): Integer; dcpcall; export;
function RemoteThumbnailDirectoryCapabilitiesW(RemoteName: PWideChar): Integer; dcpcall; export;
function RemoteThumbnailDirectoryStatusW(RequestId, ReturnedJson: PWideChar; Capacity: Integer): Integer; dcpcall; export;
function FsRenMovFileW(OldName, NewName: PWideChar; Move, OverWrite: BOOL;
  RemoteInfo: pRemoteInfo): Integer; dcpcall; export;
function FsGetFileW(RemoteName, LocalName: PWideChar; CopyFlags: Integer;
  RemoteInfo: pRemoteInfo): Integer; dcpcall; export;
function FsGetPreviewBitmapW(RemoteName: PWideChar; Width, Height: Integer;
  ReturnedBitmap: Pointer): Integer; dcpcall; export;
function FsPutFileW(LocalName, RemoteName: PWideChar; CopyFlags: Integer)
  : Integer; dcpcall; export;
function FsDeleteFileW(RemoteName: PWideChar): BOOL; dcpcall; export;

function FsMkDirW(RemoteDir: PWideChar): BOOL; dcpcall; export;
function FsRemoveDirW(RemoteName: PWideChar): BOOL; dcpcall; export;

function FsSetTimeW(RemoteName: PWideChar; CreationTime, LastAccessTime,
                    LastWriteTime: PFileTime): BOOL; dcpcall; export;

function FsDisconnectW(DisconnectRoot: PWideChar): BOOL; dcpcall; export;

procedure FsSetCryptCallbackW(pCryptProc: TCryptProcW; CryptoNr, Flags: Integer); dcpcall; export;
procedure FsGetDefRootName(DefRootName: PAnsiChar; MaxLen: Integer); dcpcall; export;
procedure FsSetDefaultParams(dps: pFsDefaultParamStruct); dcpcall; export;
procedure FsStatusInfoW(RemoteDir: PWideChar; InfoStartEnd, InfoOperation: Integer); dcpcall; export;
function FsGetBackgroundFlags: Integer; dcpcall; export;
procedure FsContentPluginUnloading; dcpcall; export;
function FsExtractCustomIconW(RemoteName: PWideChar; ExtractFlags: Integer; TheIcon: PWfxIcon): Integer; dcpcall; export;
{ Network API }
{
procedure FsNetworkGetSupportedProtocols(Protocols: PAnsiChar; MaxLen: LongInt); dcpcall; export;
function FsNetworkGetConnection(Index: LongInt; Connection: PAnsiChar; MaxLen: LongInt): LongBool; dcpcall; export;
function FsNetworkManageConnection(MainWin: HWND; Connection: PAnsiChar; Action: LongInt; MaxLen: LongInt): LongBool; dcpcall; export;
function FsNetworkOpenConnection(Connection: PAnsiChar; RootDir, RemotePath: PAnsiChar; MaxLen: LongInt): LongBool; dcpcall; export;
}
{ Extension API }
procedure ExtensionInitialize(StartupInfo: PExtensionStartupInfo); dcpcall; export;

function ReadPassword(ConnectionName: AnsiString; out Password: AnsiString): Boolean;
function DeletePassword(ConnectionName: AnsiString): Boolean;
function GetRemoteThumbnailProviderPath: String;
function GetRemoteThumbnailConfigPath: String;
procedure SetRemoteThumbnailPaths(const ProviderPath, ConfigPath: String);

var
  gStartupInfo: TExtensionStartupInfo;

var
  LogProc: TLogProcW;
  CryptProc: TCryptProcW;
  PluginNumber: Integer;
  CryptoNumber: Integer;
  RequestProc: TRequestProcW;
  ProgressProc: TProgressProcW;

implementation

uses
  IniFiles, StrUtils, fpjson, FtpAdv, FtpUtils, FtpConfDlg, syncobjs, LazFileUtils,
  LazUTF8, DCClassesUtf8, DCConvertEncoding, SftpSend, ScpSend, FtpProxy,
  FtpPropDlg, FtpLng, DCFileAttributes, RemoteThumbnailProvider;

var
  DefaultIniName: String;
  TcpKeepAlive: Boolean = True;
  ActiveConnectionList, ConnectionList: TStringList;
  IniFile: TIniFile;
  ListLock: TCriticalSection;
  RemoteThumbnailProviderPath: String = '';
  RemoteThumbnailConfigPath: String = '';

threadvar
  ThreadCon: TFtpSendEx;

const
  FS_COPYFLAGS_FORCE = FS_COPYFLAGS_OVERWRITE or FS_COPYFLAGS_RESUME;

type
  TListRec = record
    Path: AnsiString;
    Index: Integer;
    FtpSend: TFTPSendEx;
    FtpList: TFTPListEx;
  end;
  PListRec = ^TListRec;

procedure ReadConnectionList;
var
  I, Count: Integer;
  sIndex: AnsiString;
  Connection: TConnection;
begin
  Count := IniFile.ReadInteger('FTP', 'ConnectionCount', 0);
  for I := 1 to Count do
  begin
    sIndex := IntToStr(I);
    Connection := TConnection.Create;
    Connection.ConnectionName := IniFile.ReadString('FTP', 'Connection' + sIndex + 'Name', EmptyStr);
    Connection.Path := IniFile.ReadString('FTP', 'Connection' + sIndex + 'Path', EmptyStr);
    Connection.Host := IniFile.ReadString('FTP', 'Connection' + sIndex + 'Host', EmptyStr);
    Connection.Port := IniFile.ReadString('FTP', 'Connection' + sIndex + 'Port', EmptyStr);
    Connection.UserName := IniFile.ReadString('FTP', 'Connection' + sIndex + 'UserName', EmptyStr);
    Connection.MasterPassword := IniFile.ReadBool('FTP', 'Connection' + sIndex + 'MasterPassword', False);
    if Connection.MasterPassword then
      Connection.Password := EmptyStr
    else
      Connection.Password := DecodeBase64(IniFile.ReadString('FTP', 'Connection' + sIndex + 'Password', EmptyStr));
    Connection.Proxy := IniFile.ReadString('FTP', 'Connection' + sIndex + 'Proxy', EmptyStr);
    Connection.Encoding := IniFile.ReadString('FTP', 'Connection' + sIndex + 'Encoding', EmptyStr);
    Connection.PassiveMode:= IniFile.ReadBool('FTP', 'Connection' + sIndex + 'PassiveMode', True);
    Connection.AutoTLS:= IniFile.ReadBool('FTP', 'Connection' + sIndex + 'AutoTLS', False);
    Connection.FullSSL:= IniFile.ReadBool('FTP', 'Connection' + sIndex + 'FullSSL', False);
    Connection.OpenSSH:= IniFile.ReadBool('FTP', 'Connection' + sIndex + 'OpenSSH', False);
    Connection.OnlySCP:= IniFile.ReadBool('FTP', 'Connection' + sIndex + 'OnlySCP', False);
    Connection.CopySCP:= IniFile.ReadBool('FTP', 'Connection' + sIndex + 'CopySCP', False);
    Connection.AgentSSH:= IniFile.ReadBool('FTP', 'Connection' + sIndex + 'AgentSSH', False);
    Connection.UseAllocate:= IniFile.ReadBool('FTP', 'Connection' + sIndex + 'UseAllocate', False);
    Connection.PublicKey := IniFile.ReadString('FTP', 'Connection' + sIndex + 'PublicKey', EmptyStr);
    Connection.PrivateKey := IniFile.ReadString('FTP', 'Connection' + sIndex + 'PrivateKey', EmptyStr);
    Connection.Fingerprint:= IniFile.ReadString('FTP', 'Connection' + sIndex + 'Fingerprint', EmptyStr);
    Connection.InitCommands := IniFile.ReadString('FTP', 'Connection' + sIndex + 'InitCommands', EmptyStr);
    Connection.ShowHiddenItems := IniFile.ReadBool('FTP', 'Connection' + sIndex + 'ShowHiddenItems', True);
    Connection.KeepAliveTransfer := IniFile.ReadBool('FTP', 'Connection' + sIndex + 'KeepAliveTransfer', False);
    Connection.RemoteThumbnailEnabled := IniFile.ReadBool('FTP',
      'Connection' + sIndex + 'RemoteThumbnailEnabled', False);
    Connection.RemoteThumbnailVolumeId := IniFile.ReadString('FTP',
      'Connection' + sIndex + 'RemoteThumbnailVolumeId', 'external_primary');
    Connection.RemoteThumbnailRemoteRoot := IniFile.ReadString('FTP',
      'Connection' + sIndex + 'RemoteThumbnailRemoteRoot', '/sdcard/Pictures');
    Connection.RemoteThumbnailCatalogRoot := IniFile.ReadString('FTP',
      'Connection' + sIndex + 'RemoteThumbnailCatalogRoot', 'Pictures');
    Connection.RemoteThumbnailIndexEnabled := IniFile.ReadBool('FTP',
      'Connection' + sIndex + 'RemoteThumbnailIndexEnabled', False);
    Connection.RemoteThumbnailBackend := IniFile.ReadString('FTP',
      'Connection' + sIndex + 'RemoteThumbnailBackend', 'direct');
    Connection.RemoteThumbnailProtocolRoot := IniFile.ReadString('FTP',
      'Connection' + sIndex + 'RemoteThumbnailProtocolRoot', '~/PhotoThumbSync/v1');
    Connection.RemoteThumbnailTermuxConfig := IniFile.ReadString('FTP',
      'Connection' + sIndex + 'RemoteThumbnailTermuxConfig', '~/.config/photothumbsync/config.toml');
    Connection.RemoteThumbnailTermuxCli := IniFile.ReadString('FTP',
      'Connection' + sIndex + 'RemoteThumbnailTermuxCli', '~/.local/bin/photothumbsync');
    Connection.RemoteThumbnailKnownHosts := IniFile.ReadString('FTP',
      'Connection' + sIndex + 'RemoteThumbnailKnownHosts', Connection.RemoteThumbnailKnownHosts);
    Connection.RemoteThumbnailControlTransport := IniFile.ReadString('FTP',
      'Connection' + sIndex + 'RemoteThumbnailControlTransport', 'ssh');
    // add connection to connection list
    ConnectionList.AddObject(Connection.ConnectionName, Connection);
  end;
  LoadProxyList(IniFile);
end;

procedure WriteConnectionList;
var
  I, Count: Integer;
  sIndex: AnsiString;
  Connection: TConnection;
begin
  IniFile.EraseSection('FTP');
  Count := ConnectionList.Count;
  IniFile.WriteInteger('FTP', 'ConnectionCount', Count);
  for I := 0 to Count - 1 do
  begin
    sIndex := IntToStr(I + 1);
    Connection := TConnection(ConnectionList.Objects[I]);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'Name', Connection.ConnectionName);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'Path', Connection.Path);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'Host', Connection.Host);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'Port', Connection.Port);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'UserName', Connection.UserName);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'MasterPassword', Connection.MasterPassword);
    if Connection.MasterPassword then
      IniFile.DeleteKey('FTP', 'Connection' + sIndex + 'Password')
    else
      IniFile.WriteString('FTP', 'Connection' + sIndex + 'Password', EncodeBase64(Connection.Password));
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'Proxy', Connection.Proxy);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'Encoding', Connection.Encoding);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'PassiveMode', Connection.PassiveMode);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'AutoTLS', Connection.AutoTLS);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'FullSSL', Connection.FullSSL);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'OpenSSH', Connection.OpenSSH);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'OnlySCP', Connection.OnlySCP);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'CopySCP', Connection.CopySCP);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'AgentSSH', Connection.AgentSSH);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'UseAllocate', Connection.UseAllocate);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'PublicKey', Connection.PublicKey);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'PrivateKey', Connection.PrivateKey);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'Fingerprint', Connection.Fingerprint);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'InitCommands', Connection.InitCommands);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'ShowHiddenItems', Connection.ShowHiddenItems);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'KeepAliveTransfer', Connection.KeepAliveTransfer);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'RemoteThumbnailEnabled',
      Connection.RemoteThumbnailEnabled);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'RemoteThumbnailVolumeId',
      Connection.RemoteThumbnailVolumeId);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'RemoteThumbnailRemoteRoot',
      Connection.RemoteThumbnailRemoteRoot);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'RemoteThumbnailCatalogRoot',
      Connection.RemoteThumbnailCatalogRoot);
    IniFile.WriteBool('FTP', 'Connection' + sIndex + 'RemoteThumbnailIndexEnabled', Connection.RemoteThumbnailIndexEnabled);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'RemoteThumbnailBackend', Connection.RemoteThumbnailBackend);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'RemoteThumbnailProtocolRoot', Connection.RemoteThumbnailProtocolRoot);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'RemoteThumbnailTermuxConfig', Connection.RemoteThumbnailTermuxConfig);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'RemoteThumbnailTermuxCli', Connection.RemoteThumbnailTermuxCli);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'RemoteThumbnailKnownHosts', Connection.RemoteThumbnailKnownHosts);
    IniFile.WriteString('FTP', 'Connection' + sIndex + 'RemoteThumbnailControlTransport', Connection.RemoteThumbnailControlTransport);
  end;
  IniFile.WriteString('RemoteThumbnail', 'ProviderPath', RemoteThumbnailProviderPath);
  IniFile.WriteString('RemoteThumbnail', 'ConfigPath', RemoteThumbnailConfigPath);
  SaveProxyList(IniFile);
  try
    IniFile.UpdateFile;
  except
    on E: Exception do
      gStartupInfo.MessageBox(PAnsiChar(E.Message), nil, MB_OK or MB_ICONERROR);
  end;
end;

procedure FreeConnectionList;
var
  I, Count: Integer;
  Connection: TConnection;
begin
  Count := ConnectionList.Count;
  for I := Count - 1 downto 0  do
  begin
    Connection := TConnection(ConnectionList.Objects[I]);
    Connection.Free;
    ConnectionList.Delete(I);
  end;
end;

procedure ZeroPassword(var APassword: String);
begin
  if (Length(APassword) > 0) then
  begin
    FillChar(APassword[1], Length(APassword), 0);
    SetLength(APassword, 0);
  end;
end;

function CryptFunc(Mode: LongInt; ConnectionName: String; var Password: String): LongInt;
var
  APassword: UnicodeString;
  AConnection: UnicodeString;
begin
  APassword:= CeUtf8ToUtf16(Password);
  AConnection:= CeUtf8ToUtf16(ConnectionName);
  if (Mode = FS_CRYPT_LOAD_PASSWORD) or (Mode = FS_CRYPT_LOAD_PASSWORD_NO_UI) then
  begin
    SetLength(APassword, MAX_PATH);
    FillChar(APassword[1], MAX_PATH * SizeOf(WideChar), #0);
  end;
  Result:= CryptProc(PluginNumber, CryptoNumber, Mode, PWideChar(AConnection), PWideChar(APassword), MAX_PATH);
  if (Mode = FS_CRYPT_LOAD_PASSWORD) or (Mode = FS_CRYPT_LOAD_PASSWORD_NO_UI) then
  begin
    Password:= UTF16ToUTF8(PWideChar(APassword)); // truncate to #0
  end;
end;

function ShowPasswordDialog(out Password: String): Boolean;
var
  APassword: UnicodeString;
begin
  SetLength(APassword, MAX_PATH); APassword[1] := #0;
  Result := RequestProc(PluginNumber, RT_Password, nil, nil, PWideChar(APassword), MAX_PATH);
  if Result then
    Password := UTF16ToUTF8(PWideChar(APassword)) // truncate to #0
  else
    Password := EmptyStr;
end;

function FtpLogin(const Connection: TConnection; const FtpSend: TFTPSendEx): Boolean;
var
  sTemp: AnsiString;
begin
  Result := False;
  if FtpSend.Login then
  begin
    sTemp:= Connection.InitCommands;
    while sTemp <> EmptyStr do
      FtpSend.ExecuteCommand(Copy2SymbDel(sTemp, ';'));
    if Length(Connection.Path) > 0 then
      FtpSend.ChangeWorkingDir(FtpSend.ClientToServer(CeUtf8ToUtf16(Connection.Path)));
    Result := True;
  end;
end;

function FtpConnect(const ConnectionName: AnsiString; out FtpSend: TFTPSendEx): Boolean;
var
  I: Integer;
  APassword: String;
  Connection: TConnection;
begin
  Result:= False;
  I:= ActiveConnectionList.IndexOf(ConnectionName);
  // If find active connection then use it
  if I >= 0 then
    begin
      FtpSend:= TFTPSendEx(ActiveConnectionList.Objects[I]);
      
      if FtpSend.NetworkError then
        //Server closed the connection, or network error occurred, or whatever else.
        //Attempt to reconnect and execute login sequence
        begin
          LogProc(PluginNumber, msgtype_details, PWideChar('Network error detected, attempting to reconnect...'));
          I:= ConnectionList.IndexOf(ConnectionName);
          if I >= 0 then
          begin
            Connection := TConnection(ConnectionList.Objects[I]);
            if not FtpLogin(Connection, FtpSend) then
              begin
                RequestProc(PluginNumber, RT_MsgOK, nil, 'Connection lost, unable to reconnect!', nil, MAX_PATH);
                Exit;
              end;
          end;
        end;
      
      Result:= True;
    end
  else
    begin
      // find in exists connection list
      I:= ConnectionList.IndexOf(ConnectionName);
      if I >= 0 then
      begin
        Connection := TConnection(ConnectionList.Objects[I]);
        if Connection.OpenSSH then
        begin
          if Connection.OnlySCP then
            FtpSend := TScpSend.Create(Connection.Encoding)
          else begin
            FtpSend := TSftpSend.Create(Connection.Encoding);
            TSftpSend(FtpSend).CopySCP := Connection.CopySCP;
          end;
          FtpSend.PublicKey:= Connection.PublicKey;
          FtpSend.PrivateKey:= Connection.PrivateKey;
          TScpSend(FtpSend).Agent:= Connection.AgentSSH;
          TScpSend(FtpSend).Fingerprint:= Connection.Fingerprint;
        end
        else begin
          FtpSend := TFTPSendEx.Create(Connection.Encoding);
          FtpSend.ShowHidden := Connection.ShowHiddenItems;
          FtpSend.KeepAliveTransfer := Connection.KeepAliveTransfer;
        end;
        FtpSend.TcpKeepAlive := TcpKeepAlive;
        FtpSend.TargetHost := Connection.Host;
        FtpSend.PassiveMode:= Connection.PassiveMode;
        FtpSend.AutoTLS:= Connection.AutoTLS;
        FtpSend.FullSSL:= Connection.FullSSL;
        FtpSend.UseAllocate:= Connection.UseAllocate;
        if Connection.Port <> EmptyStr then
          FtpSend.TargetPort := Connection.Port
        else if Connection.FullSSL then
          FtpSend.TargetPort := cFtpsPort;
        if Connection.UserName <> EmptyStr then
          FtpSend.UserName := Connection.UserName;
        if Connection.MasterPassword then
        begin
          if CryptFunc(FS_CRYPT_LOAD_PASSWORD, Connection.ConnectionName, Connection.Password) <> FS_FILE_OK then
            ZeroPassword(Connection.Password);
        end;
        // if no saved password then ask it
        if Connection.OpenSSH and (Connection.AgentSSH or ((Connection.PrivateKey <> '') and (Connection.PublicKey <> ''))) then
          APassword:= EmptyStr
        else if Length(Connection.Password) > 0 then
          APassword:= Connection.Password
        else if Length(Connection.CachedPassword) > 0 then
          APassword:= Connection.CachedPassword
        else if not ShowPasswordDialog(APassword) then
        begin
          FreeAndNil(FtpSend);
          Exit;
        end;
        FtpSend.Password := FtpSend.ClientToServer(APassword);
        SetProxy(FtpSend, Connection.Proxy);
        // try to connect
        if not FtpLogin(Connection, FtpSend) then
        begin
          RequestProc(PluginNumber, RT_MsgOK, nil, 'Can not connect to the server!', nil, MAX_PATH);
          FreeAndNil(FtpSend);
        end
        else begin
          Connection.CachedPassword:= APassword;
          LogProc(PluginNumber, MSGTYPE_CONNECT, PWideChar('CONNECT ' + PathDelim + CeUtf8ToUtf16(ConnectionName)));
          ActiveConnectionList.AddObject(ConnectionName, FtpSend);
          if Connection.OpenSSH and (ConnectionName <> cQuickConnection) then
          begin
            // Save connection server fingerprint
            if Connection.Fingerprint <> TScpSend(FtpSend).Fingerprint then
            begin
              Connection.Fingerprint:= TScpSend(FtpSend).Fingerprint;
              WriteConnectionList;
            end;
          end;
          Result:= True;
        end;
      end;
    end;
end;

function QuickConnection(out FtpSend: TFTPSendEx): Boolean;
var
  Index: Integer;
  Connection: TConnection;
begin
  Index:= ActiveConnectionList.IndexOf(cQuickConnection);
  Result:= (Index >= 0);
  if Result then
    FtpSend:= TFTPSendEx(ActiveConnectionList.Objects[Index])
  else begin
    Connection := TConnection.Create;
    Connection.ConnectionName:= cQuickConnection;
    if ShowFtpConfDlg(Connection) then
    begin
      Connection.ConnectionName:= cQuickConnection;
      Index:= ConnectionList.AddObject(Connection.ConnectionName, Connection);
      Result:= FtpConnect(Connection.ConnectionName, FtpSend);
      ConnectionList.Delete(Index);
    end;
    Connection.Free;
  end;
end;

function AddConnection: Integer;
var
  Connection: TConnection;
begin
  Result := -1;
  Connection := TConnection.Create;
  Connection.PassiveMode := True;

  if ShowFtpConfDlg(Connection) then
  begin
    with Connection do
    begin
      if ConnectionList.IndexOf(ConnectionName) >= 0 then begin
        ConnectionName += '+' + IntToStr(Random(MaxInt));
      end;
      if MasterPassword then
      begin
        if Length(Password) = 0 then
          MasterPassword:= False
        else if CryptFunc(FS_CRYPT_SAVE_PASSWORD, ConnectionName, Password) = FS_FILE_OK then
          Password:= EmptyStr
        else
          MasterPassword:= False;
      end;
      Result:= ConnectionList.AddObject(ConnectionName, Connection);
    end;
  end;

  if Result < 0 then
    FreeAndNil(Connection)
  else
    WriteConnectionList;
end;

function EditConnection(ConnectionName: AnsiString): Boolean;
var
  I: Integer;
  ATemp: TConnection;
  Connection: TConnection;
begin
  Result:= False;
  I := ConnectionList.IndexOf(ConnectionName);
  if I >= 0 then
  begin
    ATemp:= TConnection.Create;
    Connection:= TConnection(ConnectionList.Objects[I]);
    ATemp.Assign(Connection);
    if ShowFtpConfDlg(ATemp) then
    begin
      with ATemp do
      begin
        if ConnectionName <> Connection.ConnectionName then
        begin
          if Connection.MasterPassword then
          begin
            if CryptFunc(FS_CRYPT_MOVE_PASSWORD, Connection.ConnectionName, ConnectionName) <> FS_FILE_OK then
            begin
              gStartupInfo.MessageBox('Cannot save connection!', 'FTP', MB_OK or MB_ICONERROR);
              Exit(False);
            end;
          end;
          ConnectionList[I]:= ConnectionName
        end;
        if PasswordChanged then
        begin
          // Master password enabled
          if MasterPassword then
          begin
            if Length(Password) = 0 then
              MasterPassword:= False
            else if CryptFunc(FS_CRYPT_SAVE_PASSWORD, ConnectionName, Password) = FS_FILE_OK then
              Password:= EmptyStr
            else
              MasterPassword:= False;
          end;
          // Master password disabled
          if (MasterPassword = False) and (Connection.MasterPassword <> MasterPassword) then
          begin
            DeletePassword(ConnectionName);
          end;
        end
      end;
      Connection.Assign(ATemp);
      WriteConnectionList;
      Result:= True;
    end;
    FreeAndNil(ATemp);
  end;
end;

function DeleteConnection(ConnectionName: AnsiString): Boolean;
var
  I: Integer;
  Connection: TConnection;
begin
  Result:= False;
  I:= ConnectionList.IndexOf(ConnectionName);
  if I >= 0 then
  begin
    Connection:= TConnection(ConnectionList.Objects[I]);
    Connection.Free;
    ConnectionList.Delete(I);
    WriteConnectionList;
    Result:= True;
  end;
end;

function ExtractConnectionName(const sPath: AnsiString): AnsiString;
var
  Index: Integer;
begin
  Result:= sPath;
  if sPath[1] = PathDelim then
    Result := Copy(sPath, 2, Length(sPath));
  Index := Pos(PathDelim, Result);
  if Index = 0 then
    Index := MaxInt;
  Result := Copy(Result, 1, Index - 1);
end;

function ExtractRemoteFileName(const FileName: AnsiString): AnsiString;
var
  I: Integer;
begin
  Result := FileName;
  System.Delete(Result, 1, 1);

  I := Pos(PathDelim, Result);
  if I = 0 then
    Result := '/'
  else
  begin
    System.Delete(Result, 1, I - 1);
    Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
  end;
end;

function NormalizeRemoteThumbnailPath(const APath: UnicodeString;
  RequireAbsolute: Boolean): UnicodeString;
var
  Index: Integer;
  Guarded: UnicodeString;
begin
  Result:= APath;
  for Index:= 1 to Length(Result) do
    if Result[Index] = '\' then Result[Index]:= '/';
  Index:= Pos('//', Result);
  while Index > 0 do
  begin
    Delete(Result, Index, 1);
    Index:= Pos('//', Result);
  end;
  if RequireAbsolute and ((Result = '') or (Result[1] <> '/')) then Exit('');
  if not RequireAbsolute then
    while (Result <> '') and (Result[1] = '/') do Delete(Result, 1, 1);
  while (Length(Result) > 1) and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
  Guarded:= '/' + Result + '/';
  if (Pos('/../', Guarded) > 0) or (Pos('/./', Guarded) > 0) then Exit('');
  for Index:= 1 to Length(Result) do
    if Ord(Result[Index]) < 32 then Exit('');
end;

function BuildRemoteThumbnailRequest(RemoteName: PWideChar;
  out ProviderPath, ConfigPath, VolumeId, CatalogPath, ConnectionJson,
  RemoteDirectory: UnicodeString; RequireControl: Boolean = False;
  ConnectionOnly: Boolean = False): Boolean;
var
  RawPath, ConnectionName, RemoteRoot, CatalogRoot, Tail: UnicodeString;
  Separator, ConnectionIndex: Integer;
  Connection: TConnection;
  Description: TJSONObject;
begin
  Result:= False;
  ProviderPath:= ''; ConfigPath:= ''; VolumeId:= ''; CatalogPath:= '';
  ConnectionJson:= ''; RemoteDirectory:= '';
  if RemoteName = nil then Exit;
  RawPath:= UnicodeString(RemoteName);
  for Separator:= 1 to Length(RawPath) do
    if RawPath[Separator] = '\' then RawPath[Separator]:= '/';
  while (RawPath <> '') and (RawPath[1] = '/') do Delete(RawPath, 1, 1);
  Separator:= Pos('/', RawPath);
  if Separator <= 1 then Exit;
  ConnectionName:= Copy(RawPath, 1, Separator - 1);
  RemoteDirectory:= NormalizeRemoteThumbnailPath('/' + Copy(RawPath, Separator + 1, MaxInt), True);
  if RemoteDirectory = '' then Exit;
  ListLock.Acquire;
  try
    ConnectionIndex:= ConnectionList.IndexOf(UTF16ToUTF8(ConnectionName));
    if ConnectionIndex < 0 then Exit;
    Connection:= TConnection(ConnectionList.Objects[ConnectionIndex]);
    if RequireControl and not Connection.RemoteThumbnailIndexEnabled then Exit;
    if RequireControl or ConnectionOnly then
    begin
      if not Connection.OpenSSH or Connection.OnlySCP or (Connection.Proxy <> '') then Exit;
      if not Connection.AgentSSH and (Connection.PrivateKey = '') then Exit;
    end
    else if not Connection.RemoteThumbnailEnabled then Exit;
    ProviderPath:= UTF8ToUTF16(RemoteThumbnailProviderPath);
    ConfigPath:= UTF8ToUTF16(RemoteThumbnailConfigPath);
    VolumeId:= UTF8ToUTF16(Connection.RemoteThumbnailVolumeId);
    RemoteRoot:= UTF8ToUTF16(Connection.RemoteThumbnailRemoteRoot);
    CatalogRoot:= UTF8ToUTF16(Connection.RemoteThumbnailCatalogRoot);
    Description:= TJSONObject.Create;
    try
      Description.Add('host', Connection.Host);
      Description.Add('port', StrToIntDef(Connection.Port, 22));
      Description.Add('username', Connection.UserName);
      Description.Add('private_key', Connection.PrivateKey);
      Description.Add('public_key', Connection.PublicKey);
      Description.Add('allow_agent', Connection.AgentSSH);
      Description.Add('known_hosts', Connection.RemoteThumbnailKnownHosts);
      Description.Add('backend', Connection.RemoteThumbnailBackend);
      Description.Add('transport', Connection.RemoteThumbnailControlTransport);
      Description.Add('remote_protocol_root', Connection.RemoteThumbnailProtocolRoot);
      Description.Add('remote_config', Connection.RemoteThumbnailTermuxConfig);
      Description.Add('termux_cli', Connection.RemoteThumbnailTermuxCli);
      ConnectionJson:= UTF8ToUTF16(Description.AsJSON);
    finally
      Description.Free;
    end;
  finally
    ListLock.Release;
  end;
  if ConnectionOnly then Exit(True);
  RemoteRoot:= NormalizeRemoteThumbnailPath(RemoteRoot, True);
  CatalogRoot:= NormalizeRemoteThumbnailPath(CatalogRoot, False);
  if (VolumeId = '') or (RemoteRoot = '') or (CatalogRoot = '') then Exit;
  if Copy(RemoteDirectory, 1, Length(RemoteRoot)) <> RemoteRoot then Exit;
  if (Length(RemoteDirectory) > Length(RemoteRoot)) and
     (RemoteDirectory[Length(RemoteRoot) + 1] <> '/') then Exit;
  Tail:= Copy(RemoteDirectory, Length(RemoteRoot) + 1, MaxInt);
  while (Tail <> '') and (Tail[1] = '/') do Delete(Tail, 1, 1);
  if Tail = '' then CatalogPath:= CatalogRoot
  else CatalogPath:= NormalizeRemoteThumbnailPath(CatalogRoot + '/' + Tail, False);
  Result:= CatalogPath <> '';
end;

function RemoteThumbnailDirectoryCapabilitiesW(RemoteName: PWideChar): Integer; dcpcall; export;
var ProviderPath, ConfigPath, VolumeId, CatalogPath, ConnectionJson, RemoteDirectory: UnicodeString;
begin
  // 1=settings, 2=local status, 4=mutations, 8=read-only original-request recovery.
  Result:= 1 or 2;
  if BuildRemoteThumbnailRequest(RemoteName, ProviderPath, ConfigPath, VolumeId,
    CatalogPath, ConnectionJson, RemoteDirectory, False, True) then Result:= Result or 8;
  if BuildRemoteThumbnailRequest(RemoteName, ProviderPath, ConfigPath, VolumeId,
    CatalogPath, ConnectionJson, RemoteDirectory, True) then Result:= Result or 4;
end;

function RemoteThumbnailDirectoryStatusW(RequestId, ReturnedJson: PWideChar; Capacity: Integer): Integer; dcpcall; export;
var Status: UnicodeString;
begin
  Result:= 0;
  if (ReturnedJson = nil) or (Capacity <= 0) then Exit;
  ReturnedJson[0]:= #0;
  Status:= GetRemoteDirectoryStatus(UTF8ToUTF16(GetRemoteThumbnailProviderPath),
    UTF8ToUTF16(GetRemoteThumbnailConfigPath), UnicodeString(RequestId), PluginNumber, LogProc);
  if Length(Status) >= Capacity then Exit;
  StrPLCopy(ReturnedJson, Status, Capacity - 1);
  Result:= 1;
end;

function GetConnectionByPath(const sPath: UnicodeString; out FtpSend: TFTPSendEx;
  out RemotePath: AnsiString): Boolean;
var
  sConnName: AnsiString;
begin
  Result := False;
  if (ExtractFileDir(sPath) = PathDelim) then Exit;
  if Assigned(ThreadCon) then
  begin
    Result:= True;
    FtpSend:= ThreadCon;
  end
  else begin
    sConnName:= ExtractConnectionName(UTF16ToUTF8(sPath));
    Result:= FtpConnect(sConnName, FtpSend);
  end;
  if Result then begin
    RemotePath:= FtpSend.ClientToServer(sPath);
    RemotePath:= ExtractRemoteFileName(RemotePath);
  end;
end;

function LocalFindNext(Hdl: THandle; var FindData: TWin32FindDataW): Boolean;
var
  I, RootCount: Integer;
  Connection: TConnection;
  ListRec: PListRec absolute Hdl;
  RootList: array [0..1] of String;
begin
  Result := False;
  I := ListRec^.Index;
  RootList[0]:= cAddConnection;
  RootList[1]:= cQuickConnection;
  RootCount := High(RootList) + 1;
  FillChar(FindData, SizeOf(FindData), 0);
  if I < RootCount then
  begin
    StrPCopy(FindData.cFileName, CeUtf8ToUtf16(RootList[I]));
    FindData.dwFileAttributes := 0;
    Inc(ListRec^.Index);
    Result := True;
  end
  else if I - RootCount < ConnectionList.Count then
  begin
    Connection := TConnection(ConnectionList.Objects[I - RootCount]);
    StrPCopy(FindData.cFileName, CeUtf8ToUtf16(Connection.ConnectionName));
    FindData.dwFileAttributes := FILE_ATTRIBUTE_VOLUME;
    Inc(ListRec^.Index);
    Result := True;
  end;
  if Result then
  begin
    FindData.nFileSizeLow := $FFFFFFFE;
    FindData.nFileSizeHigh := $FFFFFFFF;
    FindData.ftLastWriteTime.dwLowDateTime := $FFFFFFFE;
    FindData.ftLastWriteTime.dwHighDateTime := $FFFFFFFF;
  end;
end;

function FsInitW(PluginNr: Integer; pProgressProc: TProgressProcW;
  pLogProc: TLogProcW; pRequestProc: TRequestProcW): Integer; dcpcall; export;
begin
  ProgressProc := pProgressProc;
  LogProc := pLogProc;
  RequestProc := pRequestProc;
  PluginNumber := PluginNr;

  Result := 0;
end;

function FsFindFirstW(Path: PWideChar; var FindData: TWin32FindDataW): THandle; dcpcall; export;
var
  ListRec: PListRec;
  sPath: AnsiString;
  FtpSend: TFTPSendEx;
  Directory: UnicodeString;
begin
  New(ListRec);
  ListRec.Index := 0;
  ListRec.Path := Path;
  ListRec.FtpSend := nil;
  ListRec.FtpList := nil;
  Result := wfxInvalidHandle;

  if Path = PathDelim then
    begin
      Result := THandle(ListRec);
      LocalFindNext(Result, FindData);
    end
  else
    begin
      ListLock.Acquire;
      try
        Directory:= Path;
        if Directory[Length(Directory)] <> PathDelim then
          Directory:= Directory + PathDelim;
        if GetConnectionByPath(Directory, FtpSend, sPath) then
        begin
          ListRec.FtpSend := FtpSend;
          ListRec.FtpList := FtpSend.FsFindFirstW(sPath, FindData);
          if Assigned(ListRec.FtpList) then Result:= THandle(ListRec);
        end;
      finally
        ListLock.Release;
        if Result = wfxInvalidHandle then
          Dispose(ListRec);
      end;
    end;
end;

function FsFindNextW(Hdl: THandle; var FindData: TWin32FindDataW): BOOL; dcpcall; export;
var
  ListRec: PListRec absolute Hdl;
begin
  if ListRec.Path = PathDelim then
    Result := LocalFindNext(Hdl, FindData)
  else
    Result := ListRec^.FtpSend.FsFindNextW(ListRec.FtpList, FindData);
end;

function FsFindClose(Hdl: THandle): Integer; dcpcall; export;
var
  ListRec: PListRec absolute Hdl;
begin
  Result:= 0;
  if Assigned(ListRec) then
  begin
    if Assigned(ListRec^.FtpSend) then begin
      Result:= ListRec^.FtpSend.FsFindClose(ListRec.FtpList);
    end;
    Dispose(ListRec);
  end;
end;

function FsExecuteFileW(MainWin: THandle; RemoteName, Verb: PWideChar): Integer; dcpcall; export;
var
  FtpSend: TFTPSendEx;
  RemoteDir: AnsiString;
  asFileName: AnsiString;
  wsFileName: UnicodeString;
  ControlVerb, ControlAction, RequestId: UnicodeString;
  ProviderPath, ConfigPath, VolumeId, CatalogPath, ConnectionJson, RemoteDirectory: UnicodeString;
  Colon: Integer;
  Identity: TGUID;
begin
  Result:= FS_EXEC_YOURSELF;
  if (RemoteName = '') then Exit;
  ControlVerb:= UnicodeString(Verb);
  if ControlVerb = 'remotethumbnail.configure' then
    Exit(ConfigureRemoteThumbnailProvider(UTF8ToUTF16(GetRemoteThumbnailProviderPath),
      UTF8ToUTF16(GetRemoteThumbnailConfigPath), PluginNumber, LogProc, MainWin));
  if Pos('remotethumbnail.index.resume:', ControlVerb) = 1 then
  begin
    Result:= FS_EXEC_ERROR;
    RequestId:= Copy(ControlVerb, Length('remotethumbnail.index.resume:') + 1, MaxInt);
    if not BuildRemoteThumbnailRequest(RemoteName, ProviderPath, ConfigPath, VolumeId,
      CatalogPath, ConnectionJson, RemoteDirectory, False, True) then Exit;
    if ResumeRemoteDirectoryIndex(ProviderPath, ConfigPath, ConnectionJson, RequestId, PluginNumber, LogProc) then
      Result:= FS_EXEC_OK;
    Exit;
  end;
  if Pos('remotethumbnail.index.', ControlVerb) = 1 then
  begin
    Result:= FS_EXEC_ERROR;
    ControlAction:= Copy(ControlVerb, Length('remotethumbnail.index.') + 1, MaxInt);
    Colon:= Pos(':', ControlAction);
    if Colon > 0 then
    begin
      RequestId:= Copy(ControlAction, Colon + 1, MaxInt);
      ControlAction:= Copy(ControlAction, 1, Colon - 1);
    end
    else begin
      if CreateGUID(Identity) <> 0 then Exit;
      RequestId:= LowerCase(Copy(UnicodeString(GUIDToString(Identity)), 2, 36));
    end;
    if (ControlAction <> 'add') and (ControlAction <> 'remove') and (ControlAction <> 'refresh') then Exit;
    if not BuildRemoteThumbnailRequest(RemoteName, ProviderPath, ConfigPath, VolumeId,
      CatalogPath, ConnectionJson, RemoteDirectory, True) then
    begin
      wsFileName:= 'RemoteThumbnail directory control requires an enabled SFTP thumbnail index, ' +
        'an in-root directory, a configured key/agent and no unsupported proxy. Check connection Thumbnails settings.';
      if Assigned(LogProc) then LogProc(PluginNumber, msgtype_importanterror, PWideChar(wsFileName));
      Exit;
    end;
    if RequestRemoteDirectoryIndex(ProviderPath, ConfigPath, ConnectionJson, ControlAction,
      RemoteDirectory, VolumeId, CatalogPath, RequestId, PluginNumber, LogProc) then
    begin
      Result:= FS_EXEC_OK;
      wsFileName:= 'RemoteThumbnail.DirectoryIndex accepted request_id=' + RequestId + ' action=' + ControlAction;
      if Assigned(LogProc) then LogProc(PluginNumber, msgtype_details, PWideChar(wsFileName));
    end;
    Exit;
  end;

  if Verb = 'open' then
    begin
      if (ExtractFileDir(RemoteName) = PathDelim) then // root path
      begin
        asFileName:= UTF16ToUTF8(RemoteName + 1);
        if RemoteName[1] <> '<' then // connection
          begin
            if not FtpConnect(asFileName, FtpSend) then
              Result := FS_EXEC_OK
            else begin
              Result := FS_EXEC_SYMLINK;
            end;
          end
        else  // special item
          begin
            if asFileName = cAddConnection then
              begin
                AddConnection;
                Result:= FS_EXEC_OK;
              end
            else if asFileName = cQuickConnection then
              begin
                if not QuickConnection(FtpSend) then
                  Result := FS_EXEC_OK
                else begin
                  Result := FS_EXEC_SYMLINK;
                end;
              end;
          end;
          if (Result = FS_EXEC_SYMLINK) then
          begin
            wsFileName := FtpSend.ServerToClient(FtpSend.GetCurrentDir);
            wsFileName := SetDirSeparators(RemoteName + wsFileName);
            StrPLCopy(RemoteName, wsFileName, MAX_PATH);
          end;
      end; // root path
    end // Verb = open
  else if Pos('chmod', UnicodeString(Verb)) = 1 then
    begin
      if GetConnectionByPath(RemoteName, FtpSend, asFileName) then
      begin
        if FtpSend.ChangeMode(asFileName, AnsiString(Copy(Verb, 7, MaxInt))) then
          Result:= FS_EXEC_OK
        else
          Result := FS_EXEC_ERROR;
      end;
    end
  else if Pos('quote', UnicodeString(Verb)) = 1 then
    begin
      if GetConnectionByPath(RemoteName, FtpSend, RemoteDir) then
      begin
        asFileName:= FtpSend.ClientToServer(Verb);
        if FtpSend.ExecuteCommand(Copy(asFileName, 7, MaxInt), RemoteDir) then
          Result := FS_EXEC_OK
        else
          Result := FS_EXEC_ERROR;
      end;
    end
  else if Verb = 'properties' then
    begin
      if (ExtractFileDir(RemoteName) = PathDelim) and not (RemoteName[1] in [#0, '<']) then // connection
      begin
        EditConnection(UTF16ToUTF8(RemoteName + 1));
      end
      else if (ExtractFileDir(RemoteName) <> PathDelim) then
      begin
        if GetConnectionByPath(RemoteName, FtpSend, asFileName) then
        begin
          if FtpSend.FileProperties(asFileName) then
          begin
            wsFileName:= FtpSend.ServerToClient(FtpSend.FullResult.Text);
            ShowPropertiesDlg(PAnsiChar(UTF8Encode(wsFileName)));
          end
        end;
      end;
      Result:= FS_EXEC_OK;
    end;
end;

function FsRenMovFileW(OldName, NewName: PWideChar; Move, OverWrite: BOOL;
  RemoteInfo: pRemoteInfo): Integer; dcpcall; export;
var
  O, N: Integer;
  FtpSend: TFTPSendEx;
  sOldName: AnsiString;
  sNewName: AnsiString;
  Connection: TConnection;
begin
  Result := FS_FILE_NOTSUPPORTED;

  if not Move then
  begin
    if (ExtractFileDir(OldName) = PathDelim) and (WideChar(OldName[1]) <> '<') and
       (ExtractFileDir(NewName) = PathDelim) and (WideChar(NewName[1]) <> '<') then
    begin
      O:= ConnectionList.IndexOf(OldName + 1);
      if O < 0 then
        Result:= FS_FILE_NOTFOUND
      else begin
        sNewName:= RepairConnectionName(UTF16ToUTF8(UnicodeString(NewName + 1)));
        N:= ConnectionList.IndexOf(sNewName);
        if (N >= 0) then
        begin
          if not OverWrite then Exit(FS_FILE_EXISTS);
          Connection:= TConnection(ConnectionList.Objects[N]);
        end
        else begin
          Connection:= TConnection.Create;
          ConnectionList.AddObject(sNewName, Connection);
        end;
        Connection.Assign(TConnection(ConnectionList.Objects[O]));
        Connection.ConnectionName:= sNewName;

        WriteConnectionList;
        Result:= FS_FILE_OK;
      end;
    end
    else if GetConnectionByPath(OldName, FtpSend, sOldName) then
    begin
      if FtpSend is TScpSend then
      begin
        sNewName := FtpSend.ClientToServer(NewName);
        sNewName := ExtractRemoteFileName(sNewName);
        ProgressProc(PluginNumber, OldName, NewName, 0);
        if (not OverWrite) and (FtpSend.FileExists(sNewName)) then
        begin
          Exit(FS_FILE_EXISTS);
        end;
        if FtpSend.CopyFile(sOldName, sNewName) then
        begin
          ProgressProc(PluginNumber, OldName, NewName, 100);
          Result := FS_FILE_OK;
        end;
      end;
    end;
    Exit;
  end;

  if (ExtractFileDir(OldName) = PathDelim) and (WideChar(OldName[1]) <> '<') then
    begin
      O:= ConnectionList.IndexOf(OldName + 1);
      if O < 0 then
        Result:= FS_FILE_NOTFOUND
      else
        begin
          ConnectionList[O]:= RepairConnectionName(UTF16ToUTF8(UnicodeString(NewName + 1)));
          TConnection(ConnectionList.Objects[O]).ConnectionName:= ConnectionList[O];
          WriteConnectionList;
          Result:= FS_FILE_OK;
        end;
    end
  else if GetConnectionByPath(OldName, FtpSend, sOldName) then
    begin
      sNewName := FtpSend.ClientToServer(NewName);
      sNewName := ExtractRemoteFileName(sNewName);
      ProgressProc(PluginNumber, OldName, NewName, 0);
      if FtpSend.RenameFile(sOldName, sNewName) then
      begin
        ProgressProc(PluginNumber, OldName, NewName, 100);
        Result := FS_FILE_OK;
      end;
    end;
end;

function FsGetFileW(RemoteName, LocalName: PWideChar; CopyFlags: Integer;
  RemoteInfo: pRemoteInfo): Integer; dcpcall; export;
var
  FileSize: Int64;
  FtpSend: TFTPSendEx;
  sFileName: AnsiString;
  FileName: AnsiString;
begin
  Result := FS_FILE_READERROR;
  if GetConnectionByPath(RemoteName, FtpSend, sFileName) then
  try
    FileName:= UTF16ToUTF8(UnicodeString(LocalName));
    if FileExistsUTF8(FileName) and (CopyFlags and FS_COPYFLAGS_FORCE = 0) then
    begin
      if not FtpSend.CanResume then Exit(FS_FILE_EXISTS);
      Exit(FS_FILE_EXISTSRESUMEALLOWED);
    end;
    FtpSend.DataStream.Clear;
    FtpSend.DirectFileName := FileName;
    Int64Rec(FileSize).Lo := RemoteInfo^.SizeLow;
    Int64Rec(FileSize).Hi := RemoteInfo^.SizeHigh;
    ProgressProc(PluginNumber, RemoteName, LocalName, 0);
    if FtpSend.RetrieveFile(sFileName, FileSize, (CopyFlags and FS_COPYFLAGS_RESUME) <> 0) then
    begin
      ProgressProc(PluginNumber, RemoteName, LocalName, 100);
      Result := FS_FILE_OK;
    end;
  except
    on EUserAbort do Result := FS_FILE_USERABORT;
    on EFOpenError do Result := FS_FILE_READERROR;
    else Result := FS_FILE_WRITEERROR;
  end;
end;

function FsGetPreviewBitmapW(RemoteName: PWideChar; Width, Height: Integer;
  ReturnedBitmap: Pointer): Integer; dcpcall; export;
var
  ProviderPath, ConfigPath, VolumeId, CatalogPath, ConnectionJson, RemoteDirectory: UnicodeString;
  ReturnedName: array[0..MAX_PATH - 1] of WideChar;
  Bitmap: HBITMAP;
begin
  Result:= FS_BITMAP_NONE;
  if ReturnedBitmap = nil then Exit;
  PWfxBitmapHandle(ReturnedBitmap)^:= 0;
  if not BuildRemoteThumbnailRequest(RemoteName, ProviderPath, ConfigPath,
     VolumeId, CatalogPath, ConnectionJson, RemoteDirectory) then Exit;
  FillChar(ReturnedName, SizeOf(ReturnedName), 0);
  Bitmap:= 0;
  Result:= GetRemoteThumbnailPreview(ProviderPath, ConfigPath, VolumeId,
    CatalogPath, PluginNumber, LogProc, Width, Height, @ReturnedName[0],
    Length(ReturnedName), @Bitmap, ConnectionJson);
  if (Result and $FF) = FS_BITMAP_NONE then Exit;
  StrPLCopy(RemoteName, UnicodeString(PWideChar(@ReturnedName[0])), MAX_PATH - 1);
  PWfxBitmapHandle(ReturnedBitmap)^:= Bitmap;
end;

function FsPutFileW(LocalName, RemoteName: PWideChar; CopyFlags: Integer): Integer; dcpcall; export;
var
  FtpSend: TFTPSendEx;
  sFileName: AnsiString;
  FileName: AnsiString;
begin
  Result := FS_FILE_WRITEERROR;
  if GetConnectionByPath(RemoteName, FtpSend, sFileName) then
  try
    FileName:= UTF16ToUTF8(UnicodeString(LocalName));
    if (CopyFlags and FS_COPYFLAGS_FORCE = 0) and (FtpSend.FileExists(sFileName)) then
    begin
      if not FtpSend.CanResume then Exit(FS_FILE_EXISTS);
      Exit(FS_FILE_EXISTSRESUMEALLOWED);
    end;
    FtpSend.DataStream.Clear;
    FtpSend.DirectFileName := FileName;
    ProgressProc(PluginNumber, LocalName, RemoteName, 0);
    if FtpSend.StoreFile(sFileName, (CopyFlags and FS_COPYFLAGS_RESUME) <> 0) then
    begin
      ProgressProc(PluginNumber, LocalName, RemoteName, 100);
      Result := FS_FILE_OK;
    end;
  except
    on EReadError do Result := FS_FILE_READERROR;
    on EUserAbort do Result := FS_FILE_USERABORT;
    else Result := FS_FILE_WRITEERROR;
  end;
end;

function FsDeleteFileW(RemoteName: PWideChar): BOOL; dcpcall; export;
var
  FtpSend: TFTPSendEx;
  sFileName: AnsiString;
begin
  Result := False;
  // if root path then delete connection
  if (ExtractFileDir(RemoteName) = PathDelim) and (RemoteName[1] <> '<') then
    Result:= DeleteConnection(ExtractConnectionName(UTF16ToUTF8(RemoteName)))
  else if GetConnectionByPath(RemoteName, FtpSend, sFileName) then
    Result := FtpSend.DeleteFile(sFileName);
end;

function FsMkDirW(RemoteDir: PWideChar): BOOL; dcpcall; export;
var
  sPath: AnsiString;
  FtpSend: TFTPSendEx;
begin
  Result := False;
  if GetConnectionByPath(RemoteDir, FtpSend, sPath) then
    Result := FtpSend.CreateDir(sPath);
end;

function FsRemoveDirW(RemoteName: PWideChar): BOOL; dcpcall; export;
var
  sPath: AnsiString;
  FtpSend: TFTPSendEx;
begin
  Result := False;
  if GetConnectionByPath(RemoteName, FtpSend, sPath) then
    Result := FtpSend.DeleteDir(sPath);
end;

function FsSetTimeW(RemoteName: PWideChar; CreationTime, LastAccessTime,
  LastWriteTime: PFileTime): BOOL; dcpcall; export;
var
  sPath: AnsiString;
  FtpSend: TFTPSendEx;
begin
  if (LastAccessTime = nil) and (LastWriteTime = nil) then
    Result := False
  else if GetConnectionByPath(RemoteName, FtpSend, sPath) then
    Result := FtpSend.FsSetTime(sPath, LastAccessTime, LastWriteTime)
  else begin
    Result := False;
  end;
end;

function FsDisconnectW(DisconnectRoot: PWideChar): BOOL; dcpcall; export;
var
  Index: Integer;
  asTemp: AnsiString;
  FtpSend: TFTPSendEx;
  wsTemp: UnicodeString;
begin
  wsTemp := ExcludeLeadingPathDelimiter(DisconnectRoot);
  asTemp := ExtractConnectionName(UTF16ToUTF8(wsTemp));

  Index := ActiveConnectionList.IndexOf(asTemp);
  Result := (Index >= 0);

  if Result then
  begin
    FtpSend:= TFTPSendEx(ActiveConnectionList.Objects[Index]);

    if not FtpSend.NetworkError then
    begin
      FtpSend.Logout;
    end;
    ActiveConnectionList.Delete(Index);

    Index:= ConnectionList.IndexOf(asTemp);
    if Index >= 0 then begin
      ZeroPassword(TConnection(ConnectionList.Objects[Index]).CachedPassword);
    end;
    LogProc(PluginNumber, MSGTYPE_DISCONNECT, PWideChar('DISCONNECT ' + DisconnectRoot));

    FreeAndNil(FtpSend);
  end;
end;

procedure FsSetCryptCallbackW(pCryptProc: TCryptProcW; CryptoNr, Flags: Integer); dcpcall; export;
begin
  CryptProc:= pCryptProc;
  CryptoNumber:= CryptoNr;
end;

procedure FsGetDefRootName(DefRootName: PAnsiChar; MaxLen: Integer); dcpcall; export;
begin
  StrPLCopy(DefRootName, 'FTP', MaxLen);
end;

procedure FsSetDefaultParams(dps: pFsDefaultParamStruct); dcpcall; export;
begin
  ConnectionList := TStringList.Create;
  ActiveConnectionList := TStringList.Create;
  DefaultIniName:= ExtractFileName(dps.DefaultIniName);
end;

procedure FsStatusInfoW(RemoteDir: PWideChar; InfoStartEnd, InfoOperation: Integer); dcpcall; export;
var
  FtpSend: TFtpSendEx;
  RemotePath: AnsiString;
begin
  if (InfoOperation in [FS_STATUS_OP_GET_MULTI_THREAD, FS_STATUS_OP_PUT_MULTI_THREAD]) then
  begin
    if InfoStartEnd = FS_STATUS_START then
    begin
      if GetConnectionByPath(RemoteDir, FtpSend, RemotePath) then
      begin
        LogProc(PluginNumber, msgtype_details, 'Create background connection');
        ThreadCon:= FtpSend.Clone;
        if not ThreadCon.Login then
        begin
          FreeAndNil(ThreadCon);
          LogProc(PluginNumber, msgtype_importanterror, 'Cannot create background connection, use foreground');
        end;
      end;
    end
    else if Assigned(ThreadCon) then
    begin
      LogProc(PluginNumber, msgtype_details, 'Destroy background connection');
      ThreadCon.Logout;
      FreeAndNil(ThreadCon);
    end;
  end;
end;

function FsGetBackgroundFlags: Integer; dcpcall; export;
begin
  Result:= BG_DOWNLOAD or BG_UPLOAD or BG_ASK_USER;
end;

function FsExtractCustomIconW(RemoteName: PWideChar; ExtractFlags: Integer; TheIcon: PWfxIcon): Integer; dcpcall; export;
var
  asRemoteName: String;
begin
  Result:= FS_ICON_USEDEFAULT;
  if (ExtractFileDir(RemoteName) = PathDelim) then
  begin
    asRemoteName:= CeUtf16ToUtf8(RemoteName + 1);
    if (asRemoteName='') or (RemoteName[1]='<') then
    begin
      Result:= FS_ICON_EXTRACTED;
      TheIcon^.Format:= FS_ICON_FORMAT_FILE;
      if asRemoteName = '' then
        StrPCopy(RemoteName, gStartupInfo.PluginDir+'ftp.ico')
      else if asRemoteName = cAddConnection then
        StrPCopy(RemoteName, 'list-add')
      else if asRemoteName = cQuickConnection then
        StrPCopy(RemoteName, 'view-file');
    end;
  end;
end;

{
procedure FsNetworkGetSupportedProtocols(Protocols: PAnsiChar; MaxLen: LongInt); dcpcall; export;
begin
  StrPLCopy(Protocols, ftpProtocol, MaxLen);
end;

function FsNetworkGetConnection(Index: LongInt; Connection: PAnsiChar;
  MaxLen: LongInt): LongBool; dcpcall; export;
begin
  Result:= False;
  if Index >= ConnectionList.Count then Exit;
  StrPLCopy(Connection, TConnection(ConnectionList.Objects[Index]).ConnectionName, MaxLen);
  Result:= True;
end;

function FsNetworkManageConnection(MainWin: HWND; Connection: PAnsiChar; Action: LongInt;
  MaxLen: LongInt): LongBool; dcpcall; export;
var
  I: Integer;
begin
  Result:= False;
  case Action of
  FS_NM_ACTION_ADD:
    begin
      I:= AddConnection;
      if I >= 0 then
      begin
        StrPLCopy(Connection, ConnectionList[I], MaxLen);
        Result:= True;
      end;
    end;
  FS_NM_ACTION_EDIT:
    begin
      I:= ConnectionList.IndexOf(Connection);
      if I >= 0 then
      begin
        if EditConnection(Connection) then
          begin
            StrPLCopy(Connection, ConnectionList[I], MaxLen);
            Result:= True;
          end;
      end;
    end;
  FS_NM_ACTION_DELETE:
    Result:= DeleteConnection(Connection);
  end;
end;

function FsNetworkOpenConnection(Connection: PAnsiChar; RootDir, RemotePath: PAnsiChar;
  MaxLen: LongInt): LongBool; dcpcall; export;
var
  I: Integer;
  FtpSend: TFTPSendEx;
  Con: TConnection;
begin
  Result:= False;
  if Connection = #0 then
    begin
      if QuickConnection then
      begin
        I:= ActiveConnectionList.IndexOf(cQuickConnection);
        if I >= 0 then
          begin
            Con:= TConnection(ActiveConnectionList.Objects[I]);
            StrPLCopy(Connection, ftpProtocol + Con.Host, MaxLen);
            StrPLCopy(RootDir, PathDelim + Con.ConnectionName, MaxLen);
            StrPLCopy(RemotePath, Con.Path, MaxLen);
            Result:= True;
          end;
      end;
    end
  else if FtpConnect(Connection, FtpSend) then
    begin
      I:= ConnectionList.IndexOf(Connection);
      if I >= 0 then
        begin
          Con:= TConnection(ConnectionList.Objects[I]);
          StrPLCopy(Connection, ftpProtocol + Con.Host, MaxLen);
          StrPLCopy(RootDir, PathDelim + Con.ConnectionName, MaxLen);
          StrPLCopy(RemotePath, Con.Path, MaxLen);
          Result:= True;
        end;
    end;
end;
}

procedure ExtensionInitialize(StartupInfo: PExtensionStartupInfo);
begin
  gStartupInfo:= StartupInfo^;
  DefaultIniName:= gStartupInfo.PluginConfDir + DefaultIniName;
  TranslateResourceStrings;

  try
    IniFile := TIniFileEx.Create(DefaultIniName, fmOpenReadWrite);

    // Use TCP keep alive for all connections: Useful for certain
    // firewalls/router if the connection breaks very often.
    TcpKeepAlive := IniFile.ReadBool('General', 'TcpKeepAlive', TcpKeepAlive);
    RemoteThumbnailProviderPath:= IniFile.ReadString('RemoteThumbnail',
      'ProviderPath', EmptyStr);
    RemoteThumbnailConfigPath:= IniFile.ReadString('RemoteThumbnail',
      'ConfigPath', EmptyStr);

    ReadConnectionList;
  except
    on E: Exception do
      gStartupInfo.MessageBox(PAnsiChar(E.Message), nil, MB_OK or MB_ICONERROR);
  end;
end;

function GetRemoteThumbnailProviderPath: String;
begin
  ListLock.Acquire;
  try
    Result:= RemoteThumbnailProviderPath;
  finally
    ListLock.Release;
  end;
end;

function GetRemoteThumbnailConfigPath: String;
begin
  ListLock.Acquire;
  try
    Result:= RemoteThumbnailConfigPath;
  finally
    ListLock.Release;
  end;
end;

procedure SetRemoteThumbnailPaths(const ProviderPath, ConfigPath: String);
begin
  ListLock.Acquire;
  try
    RemoteThumbnailProviderPath:= Trim(ProviderPath);
    RemoteThumbnailConfigPath:= Trim(ConfigPath);
  finally
    ListLock.Release;
  end;
end;

function ReadPassword(ConnectionName: AnsiString; out Password: AnsiString): Boolean;
begin
  Password:= EmptyStr;
  case CryptFunc(FS_CRYPT_LOAD_PASSWORD, ConnectionName, Password) of
    FS_FILE_OK,
    FS_FILE_READERROR:
      Result:= True
    else
      Result:= False;
  end;
end;

function DeletePassword(ConnectionName: AnsiString): Boolean;
var
  Password: String = '';
begin
  Result:= CryptFunc(FS_CRYPT_DELETE_PASSWORD, ConnectionName, Password) = FS_FILE_OK;
end;

{ TConnection }

constructor TConnection.Create;
begin
  inherited Create;
  RemoteThumbnailEnabled:= False;
  RemoteThumbnailVolumeId:= 'external_primary';
  RemoteThumbnailRemoteRoot:= '/sdcard/Pictures';
  RemoteThumbnailCatalogRoot:= 'Pictures';
  RemoteThumbnailIndexEnabled:= False;
  RemoteThumbnailBackend:= 'direct';
  RemoteThumbnailProtocolRoot:= '~/PhotoThumbSync/v1';
  RemoteThumbnailTermuxConfig:= '~/.config/photothumbsync/config.toml';
  RemoteThumbnailTermuxCli:= '~/.local/bin/photothumbsync';
  RemoteThumbnailControlTransport:= 'ssh';
  {$IFDEF MSWINDOWS}
  RemoteThumbnailKnownHosts:= GetEnvironmentVariableUTF8('USERPROFILE') + '\.ssh\known_hosts';
  {$ELSE}
  RemoteThumbnailKnownHosts:= GetEnvironmentVariableUTF8('HOME') + '/.ssh/known_hosts';
  {$ENDIF}
end;

procedure TConnection.Assign(Connection: TConnection);
begin
  Path:= Connection.Path;
  Host:= Connection.Host;
  Port:= Connection.Port;
  Proxy:= Connection.Proxy;
  AutoTLS:= Connection.AutoTLS;
  FullSSL:= Connection.FullSSL;
  OpenSSH:= Connection.OpenSSH;
  CopySCP:= Connection.CopySCP;
  OnlySCP:= Connection.OnlySCP;
  AgentSSH:= Connection.AgentSSH;
  UserName:= Connection.UserName;
  Password:= Connection.Password;
  Encoding:= Connection.Encoding;
  PublicKey:= Connection.PublicKey;
  PrivateKey:= Connection.PrivateKey;
  Fingerprint:= Connection.Fingerprint;
  PassiveMode:= Connection.PassiveMode;
  UseAllocate:= Connection.UseAllocate;
  InitCommands:= Connection.InitCommands;
  MasterPassword:= Connection.MasterPassword;
  ConnectionName:= Connection.ConnectionName;
  PasswordChanged:= Connection.PasswordChanged;
  ShowHiddenItems:= Connection.ShowHiddenItems;
  KeepAliveTransfer:= Connection.KeepAliveTransfer;
  RemoteThumbnailEnabled:= Connection.RemoteThumbnailEnabled;
  RemoteThumbnailVolumeId:= Connection.RemoteThumbnailVolumeId;
  RemoteThumbnailRemoteRoot:= Connection.RemoteThumbnailRemoteRoot;
  RemoteThumbnailCatalogRoot:= Connection.RemoteThumbnailCatalogRoot;
  RemoteThumbnailIndexEnabled:= Connection.RemoteThumbnailIndexEnabled;
  RemoteThumbnailBackend:= Connection.RemoteThumbnailBackend;
  RemoteThumbnailProtocolRoot:= Connection.RemoteThumbnailProtocolRoot;
  RemoteThumbnailTermuxConfig:= Connection.RemoteThumbnailTermuxConfig;
  RemoteThumbnailTermuxCli:= Connection.RemoteThumbnailTermuxCli;
  RemoteThumbnailKnownHosts:= Connection.RemoteThumbnailKnownHosts;
  RemoteThumbnailControlTransport:= Connection.RemoteThumbnailControlTransport;
end;

procedure FsContentPluginUnloading; dcpcall;
begin
  { The provider owns joinable workers. The host calls this while the FTP DLL
    is still fully loaded, before FreeLibrary acquires the loader lock. }
  ShutdownRemoteThumbnailProvider;
end;

initialization
  ListLock := syncobjs.TCriticalSection.Create;

finalization
  { Never join provider workers from DLL finalization / the loader lock. }
  FreeAndNil(ListLock);

end.
