unit uDebugRpcServer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

function StartDebugRpcServer: Boolean;
procedure StopDebugRpcServer;
function DebugRpcServerRunning: Boolean;
function DebugRpcServerPipeName: String;

implementation

uses
  SyncObjs, uDebugRpcDispatcher, uDebugRpcLogger, uDebugRpcRuntime,
  uGlobsPaths, uDebug
  {$IFDEF MSWINDOWS}
  , Windows, JwaWinNT, JwaAclApi, JwaAccCtrl, JwaWinBase,
  uNamedPipes, uProcessInfo
  {$ENDIF};

const
  MaxRequestBytes = 1024 * 1024;
  PipeBufferBytes = 1024 * 1024;
  PipeRejectRemoteClients = $00000008;

type
  TDebugRpcServer = class;

{$IFDEF MSWINDOWS}
  { TDebugRpcClientThread }

  TDebugRpcClientThread = class(TThread)
  private
    FServer: TDebugRpcServer;
    FPipe: THandle;
    FBuffer: UTF8String;
    FPipeLock: SyncObjs.TCriticalSection;
    function ReadChunk(out AChunk: UTF8String): Boolean;
    function ReadLine(out ALine: UTF8String): Boolean;
    function WriteLine(const ALine: UTF8String): Boolean;
    function WaitForIo(APipe: THandle; var AOverlapped: TOverlapped;
      out ATransferred: DWORD): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TDebugRpcServer; APipe: THandle);
    destructor Destroy; override;
    procedure RequestStop;
  end;

  { TDebugRpcListenerThread }

  TDebugRpcListenerThread = class(TThread)
  private
    FServer: TDebugRpcServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TDebugRpcServer);
  end;
{$ENDIF}

  { TDebugRpcServer }

  TDebugRpcServer = class
  private
    FPipeName: String;
    FDispatcher: TDebugRpcDispatcher;
    FReady: SyncObjs.TEvent;
    FStopEvent: THandle;
    FStartError: String;
    FClients: TThreadList;
{$IFDEF MSWINDOWS}
    FListener: TDebugRpcListenerThread;
{$ENDIF}
  public
    constructor Create(const APipeName: String);
    destructor Destroy; override;
    function Start: Boolean;
    procedure Stop;
{$IFDEF MSWINDOWS}
    procedure RegisterClient(AClient: TDebugRpcClientThread);
    procedure UnregisterClient(AClient: TDebugRpcClientThread);
    procedure AcceptClient(APipe: THandle);
{$ENDIF}
    property PipeName: String read FPipeName;
    property Dispatcher: TDebugRpcDispatcher read FDispatcher;
    property StopEvent: THandle read FStopEvent;
    property Ready: TEvent read FReady;
    property StartError: String read FStartError write FStartError;
  end;

var
  Server: TDebugRpcServer = nil;

{$IFDEF MSWINDOWS}

constructor TDebugRpcClientThread.Create(AServer: TDebugRpcServer;
  APipe: THandle);
begin
  inherited Create(True);
  FreeOnTerminate:= True;
  FServer:= AServer;
  FPipe:= APipe;
  FPipeLock:= SyncObjs.TCriticalSection.Create;
  FServer.RegisterClient(Self);
  Start;
end;

destructor TDebugRpcClientThread.Destroy;
var
  Pipe: THandle;
begin
  FPipeLock.Acquire;
  try
    Pipe:= FPipe;
    FPipe:= INVALID_HANDLE_VALUE;
  finally
    FPipeLock.Release;
  end;
  if Pipe <> INVALID_HANDLE_VALUE then
  begin
    FlushFileBuffers(Pipe);
    DisconnectNamedPipe(Pipe);
    CloseHandle(Pipe);
  end;
  FreeAndNil(FPipeLock);
  inherited Destroy;
end;

procedure TDebugRpcClientThread.RequestStop;
var
  Pipe: THandle;
begin
  Terminate;
  FPipeLock.Acquire;
  try
    Pipe:= FPipe;
    FPipe:= INVALID_HANDLE_VALUE;
  finally
    FPipeLock.Release;
  end;
  if Pipe <> INVALID_HANDLE_VALUE then
  begin
    DisconnectNamedPipe(Pipe);
    CloseHandle(Pipe);
  end;
end;

function TDebugRpcClientThread.WaitForIo(APipe: THandle;
  var AOverlapped: TOverlapped; out ATransferred: DWORD): Boolean;
var
  WaitResult: DWORD;
begin
  Result:= False;
  repeat
    WaitResult:= WaitForSingleObject(AOverlapped.hEvent, 100);
    if WaitResult = WAIT_OBJECT_0 then
    begin
      Result:= GetOverlappedResult(APipe, AOverlapped, ATransferred, False);
      Exit;
    end;
    if WaitResult <> WAIT_TIMEOUT then Exit;
  until Terminated;
  CancelIo(APipe);
end;

function TDebugRpcClientThread.ReadChunk(out AChunk: UTF8String): Boolean;
var
  Buffer: array[0..4095] of Byte;
  Pipe: THandle;
  ReadCount: DWORD;
  Pending: Boolean;
  Overlapped: TOverlapped;
begin
  Result:= False;
  AChunk:= EmptyStr;
  FPipeLock.Acquire;
  try
    Pipe:= FPipe;
  finally
    FPipeLock.Release;
  end;
  if Pipe = INVALID_HANDLE_VALUE then Exit;
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  Overlapped.hEvent:= CreateEvent(nil, True, False, nil);
  if Overlapped.hEvent = 0 then Exit;
  try
    ReadCount:= 0;
    Pending:= not ReadFile(Pipe, @Buffer[0], SizeOf(Buffer), @ReadCount,
      @Overlapped);
    if Pending then
    begin
      if GetLastError <> ERROR_IO_PENDING then Exit;
      if not WaitForIo(Pipe, Overlapped, ReadCount) then Exit;
    end;
    if ReadCount = 0 then Exit;
    SetLength(AChunk, ReadCount);
    Move(Buffer[0], AChunk[1], ReadCount);
    Result:= True;
  finally
    CloseHandle(Overlapped.hEvent);
  end;
end;

function TDebugRpcClientThread.ReadLine(out ALine: UTF8String): Boolean;
var
  Position: SizeInt;
  Chunk: UTF8String;
begin
  Result:= False;
  ALine:= EmptyStr;
  repeat
    Position:= Pos(#10, FBuffer);
    if Position > 0 then
    begin
      if Position - 1 > MaxRequestBytes then Exit(False);
      ALine:= Copy(FBuffer, 1, Position - 1);
      System.Delete(FBuffer, 1, Position);
      if (Length(ALine) > 0) and (ALine[Length(ALine)] = #13) then
        SetLength(ALine, Length(ALine) - 1);
      Exit(True);
    end;
    if Length(FBuffer) > MaxRequestBytes then Exit(False);
    if not ReadChunk(Chunk) then Exit(False);
    FBuffer:= FBuffer + Chunk;
  until Terminated;
end;

function TDebugRpcClientThread.WriteLine(const ALine: UTF8String): Boolean;
var
  Payload: UTF8String;
  Pipe: THandle;
  Offset: SizeInt;
  Written: DWORD;
  Pending: Boolean;
  Overlapped: TOverlapped;
begin
  Result:= False;
  Payload:= ALine + #10;
  FPipeLock.Acquire;
  try
    Pipe:= FPipe;
  finally
    FPipeLock.Release;
  end;
  if Pipe = INVALID_HANDLE_VALUE then Exit;
  Offset:= 1;
  while Offset <= Length(Payload) do
  begin
    FillChar(Overlapped, SizeOf(Overlapped), 0);
    Overlapped.hEvent:= CreateEvent(nil, True, False, nil);
    if Overlapped.hEvent = 0 then Exit;
    try
      Written:= 0;
      Pending:= not WriteFile(Pipe, @Payload[Offset],
        Length(Payload) - Offset + 1, @Written, @Overlapped);
      if Pending then
      begin
        if GetLastError <> ERROR_IO_PENDING then Exit;
        if not WaitForIo(Pipe, Overlapped, Written) then Exit;
      end;
      if Written = 0 then Exit;
      Inc(Offset, Written);
    finally
      CloseHandle(Overlapped.hEvent);
    end;
  end;
  Result:= True;
end;

procedure TDebugRpcClientThread.Execute;
var
  Request, Response: UTF8String;
begin
  try
    try
      while not Terminated do
      begin
        if not ReadLine(Request) then Break;
        if Length(Request) > MaxRequestBytes then Break;
        Response:= FServer.Dispatcher.Dispatch(Request);
        if (Response <> EmptyStr) and (not WriteLine(Response)) then Break;
      end;
    except
      on E: Exception do
        DebugRpcLog(EmptyStr, EmptyStr, 'server', 'client', 0, 'error',
          E.Message);
    end;
  finally
    if Assigned(FServer) then FServer.UnregisterClient(Self);
  end;
end;

constructor TDebugRpcListenerThread.Create(AServer: TDebugRpcServer);
begin
  inherited Create(True);
  FreeOnTerminate:= False;
  FServer:= AServer;
  Start;
end;

procedure TDebugRpcListenerThread.Execute;
var
  UserSID: TBytes;
  ACL: PACL;
  ExplicitAccess: TExplicitAccess;
  SecurityAttributes: TSecurityAttributes;
  SecurityDescriptor: TSecurityDescriptor;
  Pipe: THandle;
  Overlapped: TOverlapped;
  Events: array[0..1] of THandle;
  Connected, Pending, ReadySignalled: Boolean;
  WaitResult, Transferred, AclError: DWORD;
  PipePath: UnicodeString;
begin
  ACL:= nil;
  Pipe:= INVALID_HANDLE_VALUE;
  ReadySignalled:= False;
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  try
    if not GetProcessUserSID(GetCurrentProcess, UserSID) or
       (Length(UserSID) = 0) then RaiseLastOSError;
    FillChar(ExplicitAccess, SizeOf(ExplicitAccess), 0);
    ExplicitAccess.grfAccessPermissions:= GENERIC_ALL;
    ExplicitAccess.grfAccessMode:= DWORD(SET_ACCESS);
    ExplicitAccess.grfInheritance:= NO_INHERITANCE;
    ExplicitAccess.Trustee.TrusteeForm:= DWORD(TRUSTEE_IS_SID);
    ExplicitAccess.Trustee.TrusteeType:= DWORD(TRUSTEE_IS_USER);
    ExplicitAccess.Trustee.ptstrName:= PAnsiChar(@UserSID[0]);
    AclError:= SetEntriesInAcl(1, @ExplicitAccess, nil,
      JwaWinNT.PACL(ACL));
    if AclError <> ERROR_SUCCESS then RaiseLastOSError(AclError);
    if not InitializeSecurityDescriptor(@SecurityDescriptor,
      SECURITY_DESCRIPTOR_REVISION) then RaiseLastOSError;
    if not SetSecurityDescriptorDacl(@SecurityDescriptor, True, ACL, False) then
      RaiseLastOSError;

    SecurityAttributes.nLength:= SizeOf(SecurityAttributes);
    SecurityAttributes.lpSecurityDescriptor:= @SecurityDescriptor;
    SecurityAttributes.bInheritHandle:= False;
    Overlapped.hEvent:= CreateEvent(nil, True, False, nil);
    if Overlapped.hEvent = 0 then RaiseLastOSError;
    Events[0]:= Overlapped.hEvent;
    Events[1]:= FServer.StopEvent;
    PipePath:= UnicodeString('\\.\pipe\' + FServer.PipeName);

    while not Terminated do
    begin
      ResetEvent(Overlapped.hEvent);
      Pipe:= CreateNamedPipeW(PWideChar(PipePath),
        PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
        PIPE_WAIT or PIPE_READMODE_BYTE or PIPE_TYPE_BYTE or
          PipeRejectRemoteClients,
        PIPE_UNLIMITED_INSTANCES, PipeBufferBytes, PipeBufferBytes, 0,
        @SecurityAttributes);
      if Pipe = INVALID_HANDLE_VALUE then RaiseLastOSError;
      if not ReadySignalled then
      begin
        ReadySignalled:= True;
        FServer.Ready.SetEvent;
      end;

      Connected:= ConnectNamedPipe(Pipe, @Overlapped);
      Pending:= False;
      if Connected then SetEvent(Overlapped.hEvent);
      if not Connected then
      begin
        case GetLastError of
          ERROR_IO_PENDING: Pending:= True;
          ERROR_PIPE_CONNECTED:
            begin
              SetEvent(Overlapped.hEvent);
              Connected:= True;
            end;
          else RaiseLastOSError;
        end;
      end;
      if Pending or Connected then
      begin
        WaitResult:= WaitForMultipleObjects(Length(Events), @Events[0], False,
          INFINITE);
        if WaitResult = WAIT_OBJECT_0 + 1 then
        begin
          CancelIo(Pipe);
          Break;
        end;
        if (WaitResult <> WAIT_OBJECT_0) or
           (Pending and not GetOverlappedResult(Pipe, Overlapped,
             Transferred, False)) then
        begin
          DisconnectNamedPipe(Pipe);
          CloseHandle(Pipe);
          Pipe:= INVALID_HANDLE_VALUE;
          Continue;
        end;
      end;

      if not VerifySameUser(Pipe) then
      begin
        DebugRpcLog(EmptyStr, EmptyStr, 'server', 'authenticate', 0,
          'rejected', 'client SID does not match server user');
        DisconnectNamedPipe(Pipe);
        CloseHandle(Pipe);
        Pipe:= INVALID_HANDLE_VALUE;
        Continue;
      end;
      DebugRpcLog(EmptyStr, EmptyStr, 'server', 'authenticate', 0,
        'accepted', EmptyStr);
      FServer.AcceptClient(Pipe);
      Pipe:= INVALID_HANDLE_VALUE;
    end;
  except
    on E: Exception do
    begin
      FServer.StartError:= E.Message;
      FServer.Ready.SetEvent;
      DebugRpcLog(EmptyStr, EmptyStr, 'server', 'listen', 0, 'error',
        E.Message);
    end;
  end;
  if Pipe <> INVALID_HANDLE_VALUE then
  begin
    DisconnectNamedPipe(Pipe);
    CloseHandle(Pipe);
  end;
  if Overlapped.hEvent <> 0 then CloseHandle(Overlapped.hEvent);
  if Assigned(ACL) then LocalFree(HLOCAL(ACL));
end;

{$ENDIF}

constructor TDebugRpcServer.Create(const APipeName: String);
begin
  inherited Create;
  FPipeName:= APipeName;
  FDispatcher:= TDebugRpcDispatcher.Create;
  FReady:= SyncObjs.TEvent.Create(nil, True, False, EmptyStr);
  FClients:= TThreadList.Create;
{$IFDEF MSWINDOWS}
  FStopEvent:= CreateEvent(nil, True, False, nil);
  if FStopEvent = 0 then RaiseLastOSError;
{$ELSE}
  FStopEvent:= 0;
{$ENDIF}
end;

destructor TDebugRpcServer.Destroy;
begin
  Stop;
{$IFDEF MSWINDOWS}
  if FStopEvent <> 0 then CloseHandle(FStopEvent);
{$ENDIF}
  FreeAndNil(FClients);
  FreeAndNil(FReady);
  FreeAndNil(FDispatcher);
  inherited Destroy;
end;

function TDebugRpcServer.Start: Boolean;
begin
  Result:= False;
{$IFDEF MSWINDOWS}
  FListener:= TDebugRpcListenerThread.Create(Self);
  if FReady.WaitFor(10000) <> wrSignaled then
  begin
    FStartError:= 'named-pipe listener startup timed out';
    Exit;
  end;
  Result:= FStartError = EmptyStr;
{$ELSE}
  FStartError:= 'DoubleCmdRPC is only available on Windows';
{$ENDIF}
end;

procedure TDebugRpcServer.Stop;
var
  List: TList;
  Index, Attempts: Integer;
begin
{$IFDEF MSWINDOWS}
  if Assigned(FListener) then
  begin
    FListener.Terminate;
    SetEvent(FStopEvent);
    FListener.WaitFor;
    FreeAndNil(FListener);
  end;
  List:= FClients.LockList;
  try
    for Index:= 0 to List.Count - 1 do
      TDebugRpcClientThread(List[Index]).RequestStop;
  finally
    FClients.UnlockList;
  end;
  Attempts:= 0;
  repeat
    List:= FClients.LockList;
    try
      if List.Count = 0 then Break;
    finally
      FClients.UnlockList;
    end;
    Sleep(10);
    Inc(Attempts);
  until Attempts >= 500;
{$ENDIF}
end;

{$IFDEF MSWINDOWS}
procedure TDebugRpcServer.RegisterClient(AClient: TDebugRpcClientThread);
begin
  FClients.Add(AClient);
end;

procedure TDebugRpcServer.UnregisterClient(AClient: TDebugRpcClientThread);
begin
  FClients.Remove(AClient);
end;

procedure TDebugRpcServer.AcceptClient(APipe: THandle);
begin
  TDebugRpcClientThread.Create(Self, APipe);
end;
{$ENDIF}

function StartDebugRpcServer: Boolean;
var
  PipeName, LogPath: String;
begin
  if Assigned(Server) then Exit(True);
  PipeName:= 'doublecmd-debug-' + IntToStr(System.GetProcessID);
  LogPath:= IncludeTrailingPathDelimiter(gpCfgDir) + 'logs' + PathDelim +
    'debug-rpc.jsonl';
  InitializeDebugRpcLogger(LogPath);
  try
    Server:= TDebugRpcServer.Create(PipeName);
    DebugRpcSetRuntime(PipeName, True);
    Result:= Server.Start;
    if Result then
    begin
      DebugRpcLog(EmptyStr, EmptyStr, 'server', 'start', 0, 'ok', EmptyStr,
        PipeName);
      DCDebug('DoubleCmdRPC listening on \\.\pipe\' + PipeName);
    end
    else begin
      DCDebug('DoubleCmdRPC failed to start: ' + Server.StartError);
      DebugRpcLog(EmptyStr, EmptyStr, 'server', 'start', 0, 'error',
        Server.StartError);
      DebugRpcSetRuntime(EmptyStr, False);
      FreeAndNil(Server);
      FinalizeDebugRpcLogger;
    end;
  except
    on E: Exception do
    begin
      DCDebug('DoubleCmdRPC failed to start: ' + E.Message);
      DebugRpcLog(EmptyStr, EmptyStr, 'server', 'start', 0, 'error', E.Message);
      DebugRpcSetRuntime(EmptyStr, False);
      FreeAndNil(Server);
      FinalizeDebugRpcLogger;
      Result:= False;
    end;
  end;
end;

procedure StopDebugRpcServer;
begin
  if not Assigned(Server) then Exit;
  DebugRpcLog(EmptyStr, EmptyStr, 'server', 'stop', 0, 'ok', EmptyStr);
  DebugRpcSetRuntime(EmptyStr, False);
  FreeAndNil(Server);
  FinalizeDebugRpcLogger;
end;

function DebugRpcServerRunning: Boolean;
begin
  Result:= Assigned(Server) and DebugRpcRuntimeEnabled;
end;

function DebugRpcServerPipeName: String;
begin
  if Assigned(Server) then Result:= Server.PipeName else Result:= EmptyStr;
end;

finalization
  StopDebugRpcServer;

end.
