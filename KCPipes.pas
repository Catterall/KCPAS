unit KCPipes;
{
  KCPipes.pas

  Small named pipes IPC unit for services to talk to each other.
  Only very basic; no queueing for multiple connections yet.

  https://github.com/Catterall/KCPAS
}
interface

uses
  Classes, SysUtils,

  KCEvents;

type
  TOnPipeMessage = procedure(const aMessage: string;
    aResponseRequested: Boolean; var aResponse: string) of object;

  {$REGION 'Client / Server'}

  TPipeServerThd = class(TThread)
  private
    FPipeName: string;
    FPipeHandle: THandle;
    FShutdownEvent: THandle;
  private
    FOnMessage: TOnPipeMessage;
    FOnLog: TOnLog;
    FOnException: TOnException;
    procedure DoOnMessage(const aMessage: string; aResponseRequested: Boolean; var aResponse: string);
    procedure DoOnLog(const aMessage: string);
    procedure DoOnException(aException: Exception);
  protected
    procedure Execute; override;
  public
    constructor Create(const aPipeName: string);
    destructor Destroy; override;
  public
    procedure Shutdown;
  public
    property OnMessage: TOnPipeMessage read FOnMessage write FOnMessage;
    property OnException: TOnException read FOnException write FOnException;
    property OnLog: TOnLog read FOnLog write FOnLog;
  end;

  TPipeClient = class
  public
    class function Send(const aPipeName, aMessage: string;
      aExpectResponse: Boolean = False): string;
  end;

  {$ENDREGION}

{$REGION 'Protocol'}

  TPipeHeader = packed record
    Flags: Byte;
    PayloadLength: Integer;
  end;

  procedure WritePipeMessage(aPipeHandle: THandle; const aPayload: string;
  aResponseRequested: Boolean);

  function ReadPipeMessage(aPipeHandle: THandle; out aPayload: string;
    out aResponseRequested: Boolean): Boolean;

const
  PIPE_FLAG_NO_RESPONSE = $00;
  PIPE_FLAG_RESPONSE_REQUESTED = $01;
  PIPE_BUFFER_SIZE = 4096;
  PIPE_MAX_PAYLOAD_SIZE = 10 * 1024 * 1024;

{$ENDREGION}

implementation

uses
  Windows;

{$REGION 'TPipeServerThd' }

constructor TPipeServerThd.Create(const aPipeName: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPipeName := aPipeName;
  FPipeHandle := INVALID_HANDLE_VALUE;
  FShutdownEvent := CreateEvent(nil, True, False, nil);
  if FShutdownEvent = 0 then
    raise Exception.Create('Failed to create shutdown event');
end;

destructor TPipeServerThd.Destroy;
begin
  if FPipeHandle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FPipeHandle);
    FPipeHandle := INVALID_HANDLE_VALUE;
  end;
  if FShutdownEvent <> 0 then
  begin
    CloseHandle(FShutdownEvent);
    FShutdownEvent := 0;
  end;
  inherited;
end;

procedure TPipeServerThd.Execute;
var
  Msg, Response: string;
  ResponseRequested: Boolean;
  WaitHandles: array[0..1] of THandle;
  WaitResult: DWORD;
  ConnectEvent: THandle;
  Overlapped: _OVERLAPPED;
begin
  DoOnLog('Pipe Server Started');

  while not Terminated do
  begin
    try
      FPipeHandle := CreateNamedPipe(
        PChar(FPipeName),
        PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        PIPE_BUFFER_SIZE,
        PIPE_BUFFER_SIZE,
        0, nil
      );

      if FPipeHandle = INVALID_HANDLE_VALUE then
        raise Exception.CreateFmt('Failed to create named pipe: %s (%s)',
          [FPipeName, SysErrorMessage(GetLastError)]);

      ConnectEvent := CreateEvent(nil, True, False, nil);
      if ConnectEvent = 0 then
      begin
        CloseHandle(FPipeHandle);
        FPipeHandle := INVALID_HANDLE_VALUE;
        raise Exception.Create('Failed to create connect event');
      end;

      try
        FillChar(Overlapped, SizeOf(Overlapped), 0);
        Overlapped.hEvent := ConnectEvent;

        if not ConnectNamedPipe(FPipeHandle, @Overlapped) then
        begin
          case GetLastError of
            ERROR_IO_PENDING:
            begin
              WaitHandles[0] := FShutdownEvent;
              WaitHandles[1] := ConnectEvent;
              WaitResult := WaitForMultipleObjects(2, @WaitHandles[0], False, INFINITE);

              if WaitResult = WAIT_OBJECT_0 then
              begin
                CancelIo(FPipeHandle);
                CloseHandle(FPipeHandle);
                FPipeHandle := INVALID_HANDLE_VALUE;
                CloseHandle(ConnectEvent);
                ConnectEvent := 0;
                Break;
              end;
            end;
            ERROR_PIPE_CONNECTED:
              ;
          else
            begin
              CloseHandle(FPipeHandle);
              FPipeHandle := INVALID_HANDLE_VALUE;
              CloseHandle(ConnectEvent);
              ConnectEvent := 0;
              Continue;
            end;
          end;
        end;

        CloseHandle(ConnectEvent);
        ConnectEvent := 0;

        if Terminated then
        begin
          CloseHandle(FPipeHandle);
          FPipeHandle := INVALID_HANDLE_VALUE;
          Break;
        end;

        if ReadPipeMessage(FPipeHandle, Msg, ResponseRequested) then
        begin
          Response := '';

          DoOnMessage(Msg, ResponseRequested, Response);

          if ResponseRequested then
            WritePipeMessage(FPipeHandle, Response, False);
        end;

        FlushFileBuffers(FPipeHandle);
        DisconnectNamedPipe(FPipeHandle);
      finally
        if ConnectEvent <> 0 then
          CloseHandle(ConnectEvent);
        if FPipeHandle <> INVALID_HANDLE_VALUE then
        begin
          CloseHandle(FPipeHandle);
          FPipeHandle := INVALID_HANDLE_VALUE;
        end;
      end;

    except
      on E: Exception do
      begin
        if Assigned(FOnException) then
          DoOnException(E);

        if not Terminated then
          Sleep(1000);
      end;
    end;
  end;

  DoOnLog('Pipe Server Stopped');
end;

procedure TPipeServerThd.Shutdown;
begin
  Terminate;
  SetEvent(FShutdownEvent);
end;

procedure TPipeServerThd.DoOnMessage(const aMessage: string;
  aResponseRequested: Boolean; var aResponse: string);
begin
  if Assigned(FOnMessage) then
    FOnMessage(aMessage, aResponseRequested, aResponse);
end;

procedure TPipeServerThd.DoOnLog(const aMessage: string);
begin
  if Assigned(FOnLog) then
    FOnLog(FPipeName, aMessage);
end;

procedure TPipeServerThd.DoOnException(aException: Exception);
begin
  if Assigned(FOnException) then
    FOnException(FPipeName, aException)
end;

{$ENDREGION}

{$REGION 'TPipeClient'}

class function TPipeClient.Send(const aPipeName, aMessage: string;
  aExpectResponse: Boolean): string;
const
  PIPE_TIMEOUT_MS = 5000;
var
  PipeHandle: THandle;
  ResponseRequested: Boolean;
begin
  Result := '';

  if not WaitNamedPipe(PChar(aPipeName), PIPE_TIMEOUT_MS) then
    raise Exception.CreateFmt('Pipe not available: %s (%s)',
      [aPipeName, SysErrorMessage(GetLastError)]);

  PipeHandle := CreateFile(
    PChar(aPipeName),
    GENERIC_READ or GENERIC_WRITE,
    0, nil, OPEN_EXISTING, 0, 0
  );

  if PipeHandle = INVALID_HANDLE_VALUE then
    raise Exception.CreateFmt('Failed to connect to pipe: %s (%s)',
      [aPipeName, SysErrorMessage(GetLastError)]);

  try
    WritePipeMessage(PipeHandle, aMessage, aExpectResponse);

    if aExpectResponse then
    begin
      if not ReadPipeMessage(PipeHandle, Result, ResponseRequested) then
        raise Exception.CreateFmt('Failed to read response from pipe: %s',
          [aPipeName]);
    end;
  finally
    CloseHandle(PipeHandle);
  end;
end;

{$ENDREGION}

{$REGION 'Protocol'}

procedure WritePipeMessage(aPipeHandle: THandle; const aPayload: string;
  aResponseRequested: Boolean);
var
  Header: TPipeHeader;
  PayloadBytes: TBytes;
  BytesWritten: DWORD;
begin
  PayloadBytes := TEncoding.UTF8.GetBytes(aPayload);

  if Length(PayloadBytes) > PIPE_MAX_PAYLOAD_SIZE then
    raise Exception.CreateFmt('Payload too large: %d bytes (max %d)',
      [Length(PayloadBytes), PIPE_MAX_PAYLOAD_SIZE]);

  if aResponseRequested then
    Header.Flags := PIPE_FLAG_RESPONSE_REQUESTED
  else
    Header.Flags := PIPE_FLAG_NO_RESPONSE;

  Header.PayloadLength := Length(PayloadBytes);

  if not WriteFile(aPipeHandle, Header, SizeOf(Header), BytesWritten, nil) then
    raise Exception.CreateFmt('Failed to write pipe header: %s',
      [SysErrorMessage(GetLastError)]);

  if Header.PayloadLength > 0 then
  begin
    if not WriteFile(aPipeHandle, PayloadBytes[0], Header.PayloadLength,
      BytesWritten, nil) then
      raise Exception.CreateFmt('Failed to write pipe payload: %s',
        [SysErrorMessage(GetLastError)]);
  end;
end;

function ReadPipeMessage(aPipeHandle: THandle; out aPayload: string;
  out aResponseRequested: Boolean): Boolean;
var
  Header: TPipeHeader;
  PayloadBytes: TBytes;
  BytesRead: DWORD;
begin
  Result := False;
  aPayload := '';
  aResponseRequested := False;

  if not ReadFile(aPipeHandle, Header, SizeOf(Header), BytesRead, nil) then
    Exit;

  if BytesRead <> SizeOf(Header) then
    Exit;

  aResponseRequested := (Header.Flags and PIPE_FLAG_RESPONSE_REQUESTED) <> 0;

  if Header.PayloadLength < 0 then
    Exit;

  if Header.PayloadLength > PIPE_MAX_PAYLOAD_SIZE then
    raise Exception.CreateFmt('Payload size %d exceeds maximum allowed %d bytes',
      [Header.PayloadLength, PIPE_MAX_PAYLOAD_SIZE]);

  if Header.PayloadLength > 0 then
  begin
    SetLength(PayloadBytes, Header.PayloadLength);
    if not ReadFile(aPipeHandle, PayloadBytes[0], Header.PayloadLength,
      BytesRead, nil) then
      Exit;
    if Integer(BytesRead) <> Header.PayloadLength then
      Exit;
    aPayload := TEncoding.UTF8.GetString(PayloadBytes);
  end;

  Result := True;
end;

{$ENDREGION}

end.
