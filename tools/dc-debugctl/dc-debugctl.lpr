program dc_debugctl;

{$mode objfpc}{$H+}
{$apptype console}

uses
  Windows, Classes, SysUtils, fpjson, jsonparser;

const
  MaxResponseBytes = 1024 * 1024;

type
  EDebugCtlError = class(Exception);

procedure Usage;
begin
  WriteLn('dc-debugctl --pid <pid> [--timeout <ms>] <method> [params-json]');
  WriteLn('dc-debugctl --pipe <name> [--timeout <ms>] <method> [params-json]');
  WriteLn('dc-debugctl --pid <pid> --request <json-rpc-request>');
  WriteLn('dc-debugctl --pid <pid> --request-file <utf8-json-file>');
  WriteLn('Options: --pretty, --help');
end;

function NextArgument(var AIndex: Integer; const AOption: String): String;
begin
  Inc(AIndex);
  if AIndex > ParamCount then
    raise EDebugCtlError.Create('missing value for ' + AOption);
  Result:= ParamStr(AIndex);
end;

function NormalizeJsonArgument(const AValue: String): String;
var
  Index, SlashCount, FirstQuote: Integer;
begin
  Result:= AValue;
  FirstQuote:= Pos('"', AValue);
  if FirstQuote < 2 then Exit;
  SlashCount:= 0;
  Index:= FirstQuote - 1;
  while (Index > 0) and (AValue[Index] = '\') do
  begin
    Inc(SlashCount);
    Dec(Index);
  end;
  { PowerShell's native argument marshaller may expose the Windows command-line
    escaping layer to FPC as \". Decode it only when the first JSON quote has
    such a prefix, leaving ordinary JSON and deliberately malformed input alone. }
  if (SlashCount and 1) = 0 then Exit;

  Result:= EmptyStr;
  Index:= 1;
  while Index <= Length(AValue) do
  begin
    if AValue[Index] <> '\' then
    begin
      Result:= Result + AValue[Index];
      Inc(Index);
      Continue;
    end;
    SlashCount:= 0;
    while (Index <= Length(AValue)) and (AValue[Index] = '\') do
    begin
      Inc(SlashCount);
      Inc(Index);
    end;
    if (Index <= Length(AValue)) and (AValue[Index] = '"') and
       ((SlashCount and 1) = 1) then
    begin
      Result:= Result + StringOfChar('\', SlashCount div 2) + '"';
      Inc(Index);
    end
    else
      Result:= Result + StringOfChar('\', SlashCount);
  end;
end;

function LoadRequestFile(const AFileName: String): UTF8String;
var
  Stream: TFileStream;
  Size: Int64;
begin
  Stream:= TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    Size:= Stream.Size;
    if Size > MaxResponseBytes then
      raise EDebugCtlError.Create('request file exceeded one MiB');
    SetLength(Result, Integer(Size));
    if Size > 0 then Stream.ReadBuffer(Result[1], Integer(Size));
  finally
    Stream.Free;
  end;
  if (Length(Result) >= 3) and
     (Byte(Result[1]) = $EF) and (Byte(Result[2]) = $BB) and
     (Byte(Result[3]) = $BF) then Delete(Result, 1, 3);
end;

function BuildRequest(const AMethod, AParamsText: String;
  ATimeoutMs: Cardinal): UTF8String;
var
  Request: TJSONObject;
  Params: TJSONData;
begin
  Params:= nil;
  Request:= TJSONObject.Create;
  try
    Request.Add('jsonrpc', '2.0');
    Request.Add('id', 1);
    Request.Add('method', AMethod);
    Request.Add('timeout_ms', Int64(ATimeoutMs));
    if AParamsText <> EmptyStr then
    begin
      Params:= GetJSON(AParamsText, True);
      if not (Params.JSONType in [jtObject, jtArray]) then
        raise EDebugCtlError.Create('params JSON must be an object or array');
      Request.Add('params', Params);
      Params:= nil;
    end
    else
      Request.Add('params', TJSONObject.Create);
    Result:= UTF8String(Request.AsJSON);
  finally
    Params.Free;
    Request.Free;
  end;
end;

function CallPipe(const APipeName: String; const ARequest: UTF8String;
  AConnectTimeoutMs: Cardinal): UTF8String;
var
  PipePath: UnicodeString;
  Pipe: THandle;
  Payload, Chunk: UTF8String;
  Buffer: array[0..4095] of Byte;
  Offset, NewlinePosition: SizeInt;
  Count: DWORD;
begin
  PipePath:= UnicodeString('\\.\pipe\' + APipeName);
  if not WaitNamedPipeW(PWideChar(PipePath), AConnectTimeoutMs) then
    RaiseLastOSError;
  Pipe:= CreateFileW(PWideChar(PipePath), GENERIC_READ or GENERIC_WRITE, 0,
    nil, OPEN_EXISTING, 0, 0);
  if Pipe = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Payload:= ARequest + #10;
    Offset:= 1;
    while Offset <= Length(Payload) do
    begin
      Count:= 0;
      if not WriteFile(Pipe, Payload[Offset], Length(Payload) - Offset + 1,
        Count, nil) then RaiseLastOSError;
      if Count = 0 then raise EDebugCtlError.Create('named pipe write returned zero bytes');
      Inc(Offset, Count);
    end;

    Result:= EmptyStr;
    repeat
      Count:= 0;
      if not ReadFile(Pipe, Buffer[0], SizeOf(Buffer), Count, nil) then
        RaiseLastOSError;
      if Count = 0 then
        raise EDebugCtlError.Create('named pipe closed before a response');
      SetLength(Chunk, Count);
      Move(Buffer[0], Chunk[1], Count);
      Result:= Result + Chunk;
      if Length(Result) > MaxResponseBytes then
        raise EDebugCtlError.Create('response exceeded one MiB');
      NewlinePosition:= Pos(#10, Result);
    until NewlinePosition > 0;
    SetLength(Result, NewlinePosition - 1);
    if (Length(Result) > 0) and (Result[Length(Result)] = #13) then
      SetLength(Result, Length(Result) - 1);
  finally
    CloseHandle(Pipe);
  end;
end;

function ResponseHasError(AResponse: TJSONData): Boolean;
var
  Index: Integer;
begin
  if AResponse is TJSONObject then
    Exit(TJSONObject(AResponse).IndexOfName('error') >= 0);
  if AResponse is TJSONArray then
  begin
    for Index:= 0 to TJSONArray(AResponse).Count - 1 do
      if ResponseHasError(TJSONArray(AResponse).Items[Index]) then Exit(True);
  end;
  Result:= False;
end;

var
  Index: Integer;
  PipeName, MethodName, ParamsText, RequestText, RequestFileName,
    ResponseText, Value: String;
  ProcessId: Cardinal;
  TimeoutMs: Cardinal;
  Pretty, HasRpcError, RequestProvided: Boolean;
  ParsedResponse: TJSONData;
begin
  PipeName:= EmptyStr;
  MethodName:= EmptyStr;
  ParamsText:= EmptyStr;
  RequestText:= EmptyStr;
  RequestFileName:= EmptyStr;
  RequestProvided:= False;
  ProcessId:= 0;
  TimeoutMs:= 5000;
  Pretty:= False;
  ParsedResponse:= nil;
  try
    Index:= 1;
    while Index <= ParamCount do
    begin
      Value:= ParamStr(Index);
      if Value = '--help' then
      begin
        Usage;
        Halt(0);
      end
      else if Value = '--pid' then
      begin
        Value:= NextArgument(Index, '--pid');
        ProcessId:= StrToDWord(Value);
      end
      else if Value = '--pipe' then
        PipeName:= NextArgument(Index, '--pipe')
      else if Value = '--timeout' then
      begin
        Value:= NextArgument(Index, '--timeout');
        TimeoutMs:= StrToDWord(Value);
        if (TimeoutMs < 1) or (TimeoutMs > 300000) then
          raise EDebugCtlError.Create('timeout must be 1..300000 milliseconds');
      end
      else if Value = '--request' then
      begin
        if RequestProvided then
          raise EDebugCtlError.Create('only one raw request input is allowed');
        RequestText:= NextArgument(Index, '--request');
        RequestProvided:= True;
      end
      else if Value = '--request-file' then
      begin
        if RequestProvided then
          raise EDebugCtlError.Create('only one raw request input is allowed');
        RequestFileName:= NextArgument(Index, '--request-file');
        RequestProvided:= True;
      end
      else if Value = '--pretty' then
        Pretty:= True
      else if Copy(Value, 1, 2) = '--' then
        raise EDebugCtlError.Create('unknown option: ' + Value)
      else if MethodName = EmptyStr then
        MethodName:= Value
      else if ParamsText = EmptyStr then
        ParamsText:= Value
      else
        raise EDebugCtlError.Create('unexpected argument: ' + Value);
      Inc(Index);
    end;

    if PipeName = EmptyStr then
    begin
      if ProcessId = 0 then
        raise EDebugCtlError.Create('--pid or --pipe is required');
      PipeName:= 'doublecmd-debug-' + IntToStr(ProcessId);
    end;
    if Pos('\', PipeName) > 0 then
      raise EDebugCtlError.Create('--pipe accepts a pipe name, not a path');
    if RequestFileName <> EmptyStr then
      RequestText:= String(LoadRequestFile(RequestFileName));
    if not RequestProvided then
    begin
      if MethodName = EmptyStr then
        raise EDebugCtlError.Create('method is required');
      ParamsText:= NormalizeJsonArgument(ParamsText);
      RequestText:= String(BuildRequest(MethodName, ParamsText, TimeoutMs));
    end
    else if RequestFileName = EmptyStr then
      RequestText:= NormalizeJsonArgument(RequestText);

    ResponseText:= String(CallPipe(PipeName, UTF8String(RequestText), TimeoutMs));
    ParsedResponse:= GetJSON(ResponseText, True);
    HasRpcError:= ResponseHasError(ParsedResponse);
    if Pretty then WriteLn(ParsedResponse.FormatJSON)
    else WriteLn(ResponseText);
    ParsedResponse.Free;
    if HasRpcError then Halt(4);
  except
    on E: EDebugCtlError do
    begin
      WriteLn(StdErr, 'dc-debugctl: ', E.Message);
      Usage;
      Halt(2);
    end;
    on E: Exception do
    begin
      WriteLn(StdErr, 'dc-debugctl: ', E.Message);
      Halt(3);
    end;
  end;
end.
