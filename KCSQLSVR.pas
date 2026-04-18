unit KCSQLSVR;
{
  KCSQLSVR.pas

  Implements various features from SQL server with an ADO connection.

  Currently Implemented:
  ----------------------
    Message Broker : Use TMessageQueueThdMgr and TMessageQueueThd instances to
                     listen to message queues.
}
interface

uses
  ADODB, Classes, Contnrs, SysUtils,

  KCEvents;

type
  {$REGION 'Message Queue Types'}

  TOnMessageQueueMessage = procedure(const aMessageQueue, aMessage: string) of object;

  TMessageQueueThd = class(TThread)
  private
    FMessageQueue : string;
    FWaitTimeoutMS : Integer;
  private
    FConnectionString : string;
    FConnection : TADOConnection;
    FQuery : TADOQuery;
    procedure Connect;
    procedure Disconnect;
  private
    FOnMessageQueueMessage : TOnMessageQueueMessage;
    FOnLog : TOnLog;
    FOnException : TOnException;
    procedure DoLog(const aMessage: string);
    procedure DoError(aException: Exception);
  private
    function WaitForMessage: string;
  protected
    procedure Execute; override;
  public
    constructor Create(
      const aConnectionString, aMessageQueue: string;
      aOnMessageQueueMessage: TOnMessageQueueMessage;
      aOnLog: TOnLog = nil;
      aOnException: TOnException = nil;
      const aWaitTimeoutMS: Integer = 5000
    );
    destructor Destroy; override;
  public
    procedure Shutdown;
  public
    property ConnectionString: string read FConnectionString;
    property MessageQueue: string read FMessageQueue;
  public
    property OnMessageQueueMessage: TOnMessageQueueMessage
      read FOnMessageQueueMessage write FOnMessageQueueMessage;
    property OnLog: TOnLog read FOnLog write FOnLog;
    property OnException: TOnException read FOnException write FOnException;
  end;

  TMessageQueueThdMgr = class(TObject)
  private
    FThreads : TObjectList;
    function GetCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
  public
    procedure AddMessageQueueThd(aMessageQueueThd: TMessageQueueThd);
    procedure StartAll;
    procedure StopAll;
    property Count: NativeInt read GetCount;
  end;

  {$ENDREGION}

implementation

uses
  ActiveX;

{$REGION 'TMessageQueueThd' }

constructor TMessageQueueThd.Create(const aConnectionString, aMessageQueue: string;
  aOnMessageQueueMessage: TOnMessageQueueMessage;
  aOnLog: TOnLog; aOnException: TOnException; const aWaitTimeoutMS: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FConnectionString := aConnectionString;
  FMessageQueue := aMessageQueue;
  FWaitTimeoutMS := aWaitTimeoutMS;
  FOnMessageQueueMessage := aOnMessageQueueMessage;
  FOnLog := aOnLog;
  FOnException := aOnException;
end;

destructor TMessageQueueThd.Destroy;
begin
  if Assigned(FConnection) then
  try
    if FConnection.Connected then
      FConnection.Close;
    FreeAndNil(FConnection)
  except
    FConnection := nil;
  end;
  inherited;
end;

procedure TMessageQueueThd.Connect;
begin
  FConnection := TADOConnection.Create(nil);
  FConnection.ConnectionString := FConnectionString;
  FConnection.LoginPrompt := False;
  try
    FConnection.Connected := True;
  except
    on E: Exception do
    begin
      DoError(E);
      Disconnect;
      Terminate;
    end;
  end;
  FConnection.CommandTimeout := 0;

  FQuery := TADOQuery.Create(nil);
  FQuery.Connection := FConnection;
  FQuery.CommandTimeout := 0;

  FQuery.SQL.Text :=
    'WAITFOR (' +
    '  RECEIVE TOP(1) ' +
    '    CAST(message_body AS NVARCHAR(MAX)) AS MessageBody ' +
    '  FROM ' + FMessageQueue +
    '), TIMEOUT ' + IntToStr(FWaitTimeoutMs);

  DoLog('Connected to SQL Server. Listening on MessageQueue: ' + FMessageQueue);
end;

procedure TMessageQueueThd.Disconnect;
begin
  if Assigned(FQuery) then
    FreeAndNil(FQuery);

  if Assigned(FConnection) then
  try
    if FConnection.Connected then
      FConnection.Close;
    FreeAndNil(FConnection);
  except
    FConnection := nil;
  end;
end;

procedure TMessageQueueThd.Execute;
var
  MessageBody: string;
begin
  CoInitialize(nil);
  try
    Connect;
    try
      while not Terminated do
      begin
        try
          MessageBody := WaitForMessage;

          if (MessageBody <> '') and (not Terminated) then
          begin
            DoLog('Message received: ' + MessageBody);
            FOnMessageQueueMessage(FMessageQueue, MessageBody);
          end;

        except
          on E: Exception do
          begin
            DoError(E);

            if Assigned(FConnection) and (not FConnection.Connected) then
            begin
              DoLog('Connection lost, attempting reconnect in 5s...');
              Disconnect;
              Sleep(5000);
              if not Terminated then
                Connect;
            end else
              Sleep(1000);
          end;
        end;
      end;
    finally
      Disconnect;
    end;
  finally
    CoUninitialize;
  end;

  DoLog('MessageQueueThd stopped for Message Queue: ' + FMessageQueue);
end;

procedure TMessageQueueThd.Shutdown;
begin
  Terminate;
end;

function TMessageQueueThd.WaitForMessage: string;
begin
  Result := '';
  FQuery.Close;
  FQuery.Open;

  if not FQuery.Eof then
    Result := FQuery.FieldByName('MessageBody').AsString;
end;

procedure TMessageQueueThd.DoError(aException: Exception);
begin
  if Assigned(FOnException) then
    FOnException(FMessageQueue, aException);
end;

procedure TMessageQueueThd.DoLog(const aMessage: string);
begin
  if Assigned(FOnLog) then
    FOnLog(FMessageQueue, aMessage);
end;

{$ENDREGION}

{$REGION 'TMessageQueueThdMgr' }

constructor TMessageQueueThdMgr.Create;
begin
  inherited Create;
  FThreads := TObjectList.Create(False);
end;

destructor TMessageQueueThdMgr.Destroy;
begin
  StopAll;

  while FThreads.Count > 0 do
  begin
    FThreads[0].Free;
    FThreads.Delete(0);
  end;

  FreeAndNil(FThreads);
  inherited;
end;

procedure TMessageQueueThdMgr.AddMessageQueueThd(
  aMessageQueueThd: TMessageQueueThd);
begin
  FThreads.Add(aMessageQueueThd);
end;

procedure TMessageQueueThdMgr.StartAll;
var
  I: Integer;
  Thd: TMessageQueueThd;
begin
  for I := 0 to FThreads.Count - 1 do
  begin
    Thd := TMessageQueueThd(FThreads[I]);
    Thd.Start;
  end;
end;

procedure TMessageQueueThdMgr.StopAll;
var
  I: Integer;
begin
  for I := 0 to FThreads.Count - 1 do
    TMessageQueueThd(FThreads[I]).Shutdown;

  for I := 0 to FThreads.Count - 1 do
    TMessageQueueThd(FThreads[I]).WaitFor;
end;

function TMessageQueueThdMgr.GetCount: Integer;
begin
  Result := FThreads.Count;
end;

{$ENDREGION}

end.
