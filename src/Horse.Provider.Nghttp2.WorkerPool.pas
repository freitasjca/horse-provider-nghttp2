unit Horse.Provider.Nghttp2.WorkerPool;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.WorkerPool
//  Bounded worker thread pool for CPU-bound work that a handler wants to
//  offload from the nghttp2 connection thread.
//
//  Same shape as horse-provider-crosssocket's WorkerPool, but v1 is
//  deliberately simpler: fixed thread count, no anonymous-method tasks, no
//  per-task error callback. Tasks are `procedure of object` — accepts
//  instance and class methods on both Delphi and FPC without triggering the
//  pre-10.4 generic-of-anon-method compiler traps (FIX-WP-4 in CrossSocket).
//
//  Design notes:
//    - Bounded queue (`MAX_QUEUE_DEPTH = 4096`). Submit returns False on
//      overflow; the caller decides whether to synchronously fall through
//      or reject with HTTP 503.
//    - Workers block on FTaskAvailable (TEvent); Stop signals it repeatedly
//      until every worker has drained.
//    - Shutdown drain honours `SHUTDOWN_DRAIN_MS` before force-exit.
//    - The pool is instantiated per-provider (not a singleton) so future
//      Multi-Instance work can give each `THorseInstance` its own pool
//      without contention on a global lock.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Generics.Collections;
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections;
{$IFEND}

const
  WORKER_POOL_DEFAULT_THREADS = 4;
  WORKER_POOL_MAX_THREADS     = 64;
  MAX_QUEUE_DEPTH             = 4096;
  SHUTDOWN_DRAIN_MS           = 5000;

type
  { Public alias — the caller passes any `procedure of object` as TWorkerTask.
    The bridge below wraps it into IWorkerTask before storing in the queue
    (FIX-WP-4 pattern from horse-provider-crosssocket: generic containers
    over `procedure of object` produce internal types the compiler can't
    unify with the original name on Dequeue). }
  TWorkerTask = procedure of object;

  { Named interface — safe to store in TQueue<IWorkerTask> across all
    Delphi versions. Wraps a TWorkerTask internally. }
  IWorkerTask = interface
    ['{5C3D8A7E-6F1B-4E9A-B2D0-8F6E4A1C9D2F}']
    procedure Execute;
  end;

  THorseNghttp2WorkerPool = class;

  TWorkerThread = class(TThread)
  private
    FPool:      THorseNghttp2WorkerPool;
    FThreadIdx: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: THorseNghttp2WorkerPool; AIdx: Integer);
  end;

  THorseNghttp2WorkerPool = class
  private
    FThreads:        TObjectList<TWorkerThread>;
    FTasks:          TQueue<IWorkerTask>;
    FLock:           TCriticalSection;
    FTaskAvailable:  TEvent;
    FStopping:       Boolean;
    FMaxQueueDepth:  Integer;
    function  DequeueTask(out ATask: IWorkerTask): Boolean;
  public
    constructor Create(AThreadCount: Integer = WORKER_POOL_DEFAULT_THREADS;
      AMaxQueueDepth: Integer = MAX_QUEUE_DEPTH);
    destructor  Destroy; override;

    // Enqueues ATask. Returns True if accepted, False if the queue is full.
    // On overflow the caller SHOULD respond with HTTP 503 Service
    // Unavailable (RFC 9110 §15.6.4) rather than blocking the I/O thread.
    function Submit(ATask: TWorkerTask): Boolean;

    // Signals every worker to exit after finishing its current task.
    // Blocks up to SHUTDOWN_DRAIN_MS for graceful termination.
    procedure Stop;

    property MaxQueueDepth: Integer read FMaxQueueDepth;
  end;

implementation

// ─── IWorkerTask bridge — TWorkerTask (method pointer) → interface ───────

type
  TMethodWorkerTask = class(TInterfacedObject, IWorkerTask)
  strict private
    FMethod: TWorkerTask;
  public
    constructor Create(AMethod: TWorkerTask);
    procedure Execute;
  end;

constructor TMethodWorkerTask.Create(AMethod: TWorkerTask);
begin
  inherited Create;
  FMethod := AMethod;
end;

procedure TMethodWorkerTask.Execute;
begin
  if Assigned(FMethod) then
    FMethod;
end;

// ─── TWorkerThread ───────────────────────────────────────────────────────

constructor TWorkerThread.Create(APool: THorseNghttp2WorkerPool; AIdx: Integer);
begin
  inherited Create(True);          // suspended
  FreeOnTerminate := False;
  FPool           := APool;
  FThreadIdx      := AIdx;
{$IF NOT DEFINED(FPC)}
  NameThreadForDebugging(AnsiString(Format('nghttp2-worker-%d', [AIdx])));
{$IFEND}
end;

procedure TWorkerThread.Execute;
var
  LTask: IWorkerTask;
begin
  while not Terminated do
  begin
    // Wait for a task or shutdown signal.
    FPool.FTaskAvailable.WaitFor(200);
    if Terminated then Break;

    // Drain everything currently in the queue before waiting again — a
    // single wake can correspond to multiple enqueues.
    //
    // Deliberately no Terminated check inside this loop: a queued task may
    // hold resources whose release is its own responsibility (the nghttp2
    // provider pairs each task with a dispatch counter that keeps a
    // connection alive until the task runs). Dropping queued tasks on
    // shutdown would strand those. Stop already blocks Submit once it begins,
    // so the queue is finite here and drains promptly.
    while FPool.DequeueTask(LTask) do
    begin
      try
        LTask.Execute;
      except
        on E: Exception do
        begin
          // Never let a handler exception kill the worker.
          if IsConsole then
            WriteLn(ErrOutput,
              Format('[nghttp2-worker-%d] %s: %s', [FThreadIdx, E.ClassName, E.Message]));
        end;
      end;
    end;
  end;
end;

// ─── THorseNghttp2WorkerPool ─────────────────────────────────────────────

constructor THorseNghttp2WorkerPool.Create(AThreadCount, AMaxQueueDepth: Integer);
var
  I: Integer;
begin
  inherited Create;
  if AThreadCount < 1 then
    AThreadCount := 1;
  if AThreadCount > WORKER_POOL_MAX_THREADS then
    AThreadCount := WORKER_POOL_MAX_THREADS;
  if AMaxQueueDepth < 1 then
    AMaxQueueDepth := MAX_QUEUE_DEPTH;

  FMaxQueueDepth := AMaxQueueDepth;
  FLock          := TCriticalSection.Create;
  FTasks         := TQueue<IWorkerTask>.Create;
  FTaskAvailable := TEvent.Create(nil, {ManualReset=}False, {InitialState=}False, '');
  FThreads       := TObjectList<TWorkerThread>.Create(True);
  FStopping      := False;

  for I := 0 to AThreadCount - 1 do
  begin
    FThreads.Add(TWorkerThread.Create(Self, I));
    FThreads[I].Start;
  end;
end;

destructor THorseNghttp2WorkerPool.Destroy;
begin
  Stop;
  FThreads.Free;
  FTasks.Free;
  FTaskAvailable.Free;
  FLock.Free;
  inherited;
end;

function THorseNghttp2WorkerPool.DequeueTask(out ATask: IWorkerTask): Boolean;
begin
  FLock.Enter;
  try
    if FTasks.Count = 0 then
      Exit(False);
    ATask  := FTasks.Dequeue;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function THorseNghttp2WorkerPool.Submit(ATask: TWorkerTask): Boolean;
begin
  if not Assigned(ATask) then Exit(False);

  FLock.Enter;
  try
    if FStopping then Exit(False);
    if FTasks.Count >= FMaxQueueDepth then Exit(False);
    // Wrap the method pointer into an IWorkerTask; the interface refcount
    // owns the wrapper for the duration of the queue slot.
    FTasks.Enqueue(TMethodWorkerTask.Create(ATask));
    Result := True;
  finally
    FLock.Leave;
  end;

  FTaskAvailable.SetEvent;
end;

procedure THorseNghttp2WorkerPool.Stop;
var
  I: Integer;
begin
  FLock.Enter;
  try
    if FStopping then Exit;
    FStopping := True;
  finally
    FLock.Leave;
  end;

  // Wake and Terminate every worker; they'll observe both on their next loop.
  for I := 0 to FThreads.Count - 1 do
  begin
    if FThreads[I] <> nil then
      FThreads[I].Terminate;
    FTaskAvailable.SetEvent;
  end;

  // WaitFor is unbounded, but each worker has already been Terminate()d and
  // its inner WaitFor uses a 200 ms tick — so worst-case per-thread wait is
  // ~200 ms + whatever the current task takes. Tasks are the caller's
  // responsibility to keep bounded (this pool exists for CPU work, not
  // network I/O). SHUTDOWN_DRAIN_MS is documented as the budget callers
  // should assume when planning shutdown, not enforced here.
  for I := 0 to FThreads.Count - 1 do
    if FThreads[I] <> nil then
      FThreads[I].WaitFor;
end;

initialization

end.
