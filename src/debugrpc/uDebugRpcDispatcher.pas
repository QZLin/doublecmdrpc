unit uDebugRpcDispatcher;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, uDebugRpcMethods;

type
  { TDebugRpcDispatcher }

  TDebugRpcDispatcher = class
  private
    FMethods: TDebugRpcMethods;
    function DispatchOne(ARequest: TJSONData): TJSONData;
  public
    constructor Create;
    destructor Destroy; override;
    function Dispatch(const ARequest: UTF8String): UTF8String; reintroduce;
  end;

implementation

uses
  jsonparser, uDebugRpcLogger;

const
  JsonRpcVersion = '2.0';
  DefaultTimeoutMs = 5000;
  MaximumTimeoutMs = 300000;

function FindMember(AObject: TJSONObject; const AName: String): TJSONData;
var
  Index: Integer;
begin
  Result:= nil;
  Index:= AObject.IndexOfName(AName);
  if Index >= 0 then Result:= AObject.Items[Index];
end;

function ErrorResponse(AId: TJSONData; ACode: Integer;
  const AMessage: String; const ADetail: String = ''): TJSONObject;
var
  ErrorObject: TJSONObject;
begin
  Result:= TJSONObject.Create;
  Result.Add('jsonrpc', JsonRpcVersion);
  if Assigned(AId) then Result.Add('id', AId.Clone)
  else Result.Add('id', TJSONNull.Create);
  ErrorObject:= TJSONObject.Create;
  ErrorObject.Add('code', ACode);
  ErrorObject.Add('message', AMessage);
  if ADetail <> EmptyStr then ErrorObject.Add('data', ADetail);
  Result.Add('error', ErrorObject);
end;

function RequestIdText(AId: TJSONData): String;
begin
  if not Assigned(AId) or (AId.JSONType = jtNull) then Exit('null');
  if AId.JSONType = jtString then Exit(AId.AsString);
  Result:= AId.AsJSON;
end;

function ReadTimeout(ARequest: TJSONObject; AParams: TJSONData): Cardinal;
var
  Data: TJSONData;
  Value: Int64;
begin
  Result:= DefaultTimeoutMs;
  Data:= FindMember(ARequest, 'timeout_ms');
  if not Assigned(Data) and (AParams is TJSONObject) then
    Data:= FindMember(TJSONObject(AParams), 'timeout_ms');
  if not Assigned(Data) then Exit;
  if Data.JSONType <> jtNumber then
    raise EDebugRpcMethodError.Create(-32602,
      'timeout_ms must be a number');
  Value:= Data.AsInt64;
  if (Value < 1) or (Value > MaximumTimeoutMs) then
    raise EDebugRpcMethodError.Create(-32602,
      'timeout_ms must be between 1 and 300000');
  Result:= Cardinal(Value);
end;

constructor TDebugRpcDispatcher.Create;
begin
  inherited Create;
  FMethods:= TDebugRpcMethods.Create;
end;

destructor TDebugRpcDispatcher.Destroy;
begin
  FreeAndNil(FMethods);
  inherited Destroy;
end;

function TDebugRpcDispatcher.DispatchOne(ARequest: TJSONData): TJSONData;
var
  RequestObject, Response: TJSONObject;
  IdData, VersionData, MethodData, ParamsData: TJSONData;
  RpcMethod, TestId, ErrorText: String;
  TimeoutMs: Cardinal;
  Started, Duration: QWord;
  MethodResult: TJSONData;
  ErrorCode: Integer;
begin
  if not (ARequest is TJSONObject) then
    Exit(ErrorResponse(nil, -32600, 'Invalid Request'));
  RequestObject:= TJSONObject(ARequest);
  IdData:= FindMember(RequestObject, 'id');
  VersionData:= FindMember(RequestObject, 'jsonrpc');
  MethodData:= FindMember(RequestObject, 'method');
  ParamsData:= FindMember(RequestObject, 'params');

  if not Assigned(IdData) or not Assigned(VersionData) or
     (VersionData.JSONType <> jtString) or
     (VersionData.AsString <> JsonRpcVersion) or not Assigned(MethodData) or
     (MethodData.JSONType <> jtString) then
    Exit(ErrorResponse(IdData, -32600,
      'Invalid Request: jsonrpc, id, and method are required'));
  if not (IdData.JSONType in [jtString, jtNumber, jtNull]) then
    Exit(ErrorResponse(nil, -32600,
      'Invalid Request: id must be string, number, or null'));
  if Assigned(ParamsData) and
     not (ParamsData.JSONType in [jtObject, jtArray]) then
    Exit(ErrorResponse(IdData, -32602,
      'Invalid params: expected object or array'));

  RpcMethod:= MethodData.AsString;
  TestId:= EmptyStr;
  if ParamsData is TJSONObject then
    TestId:= TJSONObject(ParamsData).Get('test_id', EmptyStr);
  Started:= GetTickCount64;
  MethodResult:= nil;
  ErrorCode:= 0;
  ErrorText:= EmptyStr;
  try
    TimeoutMs:= ReadTimeout(RequestObject, ParamsData);
    MethodResult:= FMethods.Execute(RpcMethod, ParamsData, TimeoutMs);
    Response:= TJSONObject.Create;
    Response.Add('jsonrpc', JsonRpcVersion);
    Response.Add('id', IdData.Clone);
    if Assigned(MethodResult) then
    begin
      Response.Add('result', MethodResult);
      MethodResult:= nil;
    end
    else
      Response.Add('result', TJSONNull.Create);
    Result:= Response;
  except
    on E: EDebugRpcMethodError do
    begin
      ErrorCode:= E.Code;
      ErrorText:= E.Message;
      Result:= ErrorResponse(IdData, E.Code, E.Message);
    end;
    on E: EJSON do
    begin
      ErrorCode:= -32602;
      ErrorText:= E.Message;
      Result:= ErrorResponse(IdData, ErrorCode, 'Invalid params', E.Message);
    end;
    on E: Exception do
    begin
      ErrorCode:= -32603;
      ErrorText:= E.Message;
      Result:= ErrorResponse(IdData, ErrorCode, 'Internal error', E.Message);
    end;
  end;
  MethodResult.Free;
  Duration:= GetTickCount64 - Started;
  if ErrorCode = 0 then
    DebugRpcLog(RequestIdText(IdData), TestId, 'rpc', RpcMethod, Duration,
      'ok', EmptyStr)
  else
    DebugRpcLog(RequestIdText(IdData), TestId, 'rpc', RpcMethod, Duration,
      'error', ErrorText, IntToStr(ErrorCode));
end;

function TDebugRpcDispatcher.Dispatch(const ARequest: UTF8String): UTF8String;
var
  Parsed, ResponseData: TJSONData;
  RequestArray, ResponseArray: TJSONArray;
  Index: Integer;
begin
  Parsed:= nil;
  ResponseData:= nil;
  try
    try
      Parsed:= GetJSON(String(ARequest), True);
    except
      on E: Exception do
      begin
        ResponseData:= ErrorResponse(nil, -32700, 'Parse error', E.Message);
        Exit(UTF8String(ResponseData.AsJSON));
      end;
    end;

    if Parsed is TJSONArray then
    begin
      RequestArray:= TJSONArray(Parsed);
      if RequestArray.Count = 0 then
        ResponseData:= ErrorResponse(nil, -32600,
          'Invalid Request: empty batch')
      else begin
        ResponseArray:= TJSONArray.Create;
        ResponseData:= ResponseArray;
        for Index:= 0 to RequestArray.Count - 1 do
          ResponseArray.Add(DispatchOne(RequestArray.Items[Index]));
      end;
    end
    else
      ResponseData:= DispatchOne(Parsed);
    Result:= UTF8String(ResponseData.AsJSON);
  finally
    ResponseData.Free;
    Parsed.Free;
  end;
end;

end.
