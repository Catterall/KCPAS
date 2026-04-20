# KCPAS

![Delphi](https://img.shields.io/badge/Delphi-EE1F35?style=flat&logo=delphi&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows-0078D6?style=flat&logo=windows&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat)

**A collection of small, self-contained Delphi utility units.**

Each unit is independent\* and can be dropped into any project as needed.

*\* Aside from the shared `KCEvents` signatures, but you can just rip that out and replace with your own stuff.*

## Units

| Unit | Purpose |
|------|---------|
| **KCSQLSVR** | SQL Server utilities via ADO |
| **KCPipes** | Named pipe IPC — server thread and client sender |
| **KCEvents** | Shared event signatures (`TOnLog`, `TOnException`) used across units |

---

## KCSQLSVR - SQL Server Utilities

SQL Server functionality accessed through ADO.

### Message Queue Listener

Spawns background threads that issue `WAITFOR (RECEIVE ...)` against Service Broker queues. When a message arrives, your callback fires.

### Setup

You need a Service Broker queue already configured in SQL Server. The unit handles the ADO connection and polling loop.

### Quick Start

```delphi
uses
  KCSQLSVR, KCEvents;

type
  TMyHandler = class
    procedure OnMessage(const aMessageQueue, aMessage: string);
    procedure OnLog(const aSentBy, aMessage: string);
    procedure OnError(const aRaisedBy: string; aException: Exception);
  end;

procedure TMyHandler.OnMessage(const aMessageQueue, aMessage: string);
begin
  // aMessageQueue = queue name, aMessage = message body
  WriteLn('Received: ', aMessage);
end;

procedure TMyHandler.OnLog(const aSentBy, aMessage: string);
begin
  WriteLn('[LOG] ', aSentBy, ': ', aMessage);
end;

procedure TMyHandler.OnError(const aRaisedBy: string; aException: Exception);
begin
  WriteLn('[ERR] ', aRaisedBy, ': ', aException.Message);
end;
```

#### Single Queue

```delphi
var
  Thd: TMessageQueueThd;
  Handler: TMyHandler;
begin
  Handler := TMyHandler.Create;

  Thd := TMessageQueueThd.Create(
    'Provider=MSOLEDBSQL;Data Source=localhost;Initial Catalog=MyDB;...', // connection string
    'dbo/MyQueue',          // queue name
    Handler.OnMessage,      // message callback
    Handler.OnLog,          // optional log callback
    Handler.OnError,        // optional error callback
    5000                    // WAITFOR timeout in ms (default 5000)
  );

  Thd.Start;

  // ... later ...
  Thd.Shutdown;
  Thd.WaitFor;
  Thd.Free;
end;
```

#### Multiple Queues with the Thread Manager

```delphi
var
  Mgr: TMessageQueueThdMgr;
begin
  Mgr := TMessageQueueThdMgr.Create;

  Mgr.AddMessageQueueThd(TMessageQueueThd.Create(
    CONNECTION_STRING, 'dbo/OrderQueue', Handler.OnMessage, Handler.OnLog, Handler.OnError
  ));

  Mgr.AddMessageQueueThd(TMessageQueueThd.Create(
    CONNECTION_STRING, 'dbo/NotificationQueue', Handler.OnMessage, Handler.OnLog, Handler.OnError
  ));

  Mgr.StartAll;

  // ... application runs ...

  Mgr.Free; // calls StopAll, waits for threads, then frees them
end;
```

### Thread Safety

Callbacks (`OnMessageQueueMessage`, `OnLog`, `OnException`) are invoked on the worker thread, **not** the main thread. Your handlers must be thread-safe or provide their own synchronization.

### Reconnection

If the SQL connection drops, the thread logs the disconnection, waits 5 seconds, and attempts to reconnect automatically. If the initial connection fails, the thread exits.

---

## KCPipes - Named Pipe IPC

A simple named pipe server and client for fire-and-forget or request/response messaging between processes.

### Protocol

Messages use a small binary header:

| Field | Size | Description |
|-------|------|-------------|
| Flags | 1 byte | `$00` = no response expected, `$01` = response requested |
| PayloadLength | 4 bytes | Length of the UTF-8 payload |

Followed by the UTF-8 payload bytes. Maximum payload size is 10 MB.

### Pipe Server

```delphi
uses
  KCPipes, KCEvents;

type
  TMyPipeHandler = class
    procedure OnMessage(const aMessage: string;
      aResponseRequested: Boolean; var aResponse: string);
    procedure OnLog(const aSentBy, aMessage: string);
    procedure OnError(const aRaisedBy: string; aException: Exception);
  end;

procedure TMyPipeHandler.OnMessage(const aMessage: string;
  aResponseRequested: Boolean; var aResponse: string);
begin
  WriteLn('Pipe received: ', aMessage);

  if aResponseRequested then
    aResponse := 'ACK: ' + aMessage;
end;

procedure TMyPipeHandler.OnLog(const aSentBy, aMessage: string);
begin
  WriteLn('[LOG] ', aSentBy, ': ', aMessage);
end;

procedure TMyPipeHandler.OnError(const aRaisedBy: string; aException: Exception);
begin
  WriteLn('[ERR] ', aRaisedBy, ': ', aException.Message);
end;
```

```delphi
var
  Server: TPipeServerThd;
  Handler: TMyPipeHandler;
begin
  Handler := TMyPipeHandler.Create;

  Server := TPipeServerThd.Create('\\.\pipe\MyAppPipe');
  Server.OnMessage := Handler.OnMessage;
  Server.OnLog := Handler.OnLog;
  Server.OnException := Handler.OnError;
  Server.Start;

  // ... later ...
  Server.Shutdown;   // signals the thread to stop cleanly
  Server.WaitFor;
  Server.Free;
end;
```

### Pipe Client

#### Fire and Forget

```delphi
TPipeClient.Send('\\.\pipe\MyAppPipe', 'Hello from another process');
```

#### Request / Response

```delphi
var
  Response: string;
begin
  Response := TPipeClient.Send('\\.\pipe\MyAppPipe', 'Ping', True);
  WriteLn('Server replied: ', Response);
end;
```

### Thread Safety

The pipe server processes one connection at a time. `OnMessage` is called on the server thread. The client (`TPipeClient.Send`) is a blocking class method. It is safe to call from any thread since it uses only local state.

---

## KCEvents - Shared Event Signatures

Provides the callback types used by the other units:

```delphi
TOnLog = procedure(const aSentBy, aMessage: string) of object;
TOnException = procedure(const aRaisedBy: string; aException: Exception) of object;
```

These are declared once here so `KCSQLSVR` and `KCPipes` share the same signatures. Your handler objects can implement both and be wired into either unit.

---

## Installation

Copy `KCSQLSVR.pas`, `KCPipes.pas`, and `KCEvents.pas` into your project or add their directory to your Delphi search path. No packages or components to install.

### Requirements

- Delphi (tested on Delphi 12, should work on older versions with minor adjustments).
- Windows (named pipes and ADO are Windows APIs).
- For `KCSQLSVR`: an ADO-compatible SQL Server driver (e.g. MSOLEDBSQL).

## License

MIT
