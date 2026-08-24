program HorseNghttp2AdmitProbe;

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  HorseNghttp2AdmitProbe — admission-latency probe for FIX-IOCP-ADMIT-1
//
//  Purpose-built because no packaged HTTP/2 load generator was usable here.
//  MSYS2 ships libnghttp2 without the tools on MINGW64 and only the HPACK
//  tools (deflatehd/inflatehd) on msys; h2load needs libev, which on Windows
//  is select()-backed and would itself struggle at c=1000 — a load generator
//  that stalls on its own descriptors manufactures exactly the symptom under
//  test. Running h2load from WSL is worse: the devcontainer sits behind a
//  Docker bridge inside the WSL2 VM, and the recorded WSL run managed 2.13
//  req/s PER CONNECTION, i.e. it measured the vEthernet hop. For a CONNECT
//  latency measurement that hop is inside the quantity being measured.
//
//  ── Why this measures the defect more directly than h2load would ──
//
//  h2load reports one aggregate `time for connect` column. The stall being
//  hunted was `time for connect` mean 6.23 s / max 69.11 s while `time for
//  request` held at 9.56 ms — but that column bundles the TCP handshake with
//  the HTTP/2 connection becoming usable, so it cannot say WHICH stalled.
//
//  This tool separates them, and the split is the whole diagnosis:
//
//    t_connect  TNghttp2Client.Connect — TCP handshake plus writing the
//               client preface and SETTINGS. It never waits for the server,
//               so it completes out of the kernel's accept backlog whether or
//               not user space has admitted the socket.
//
//    t_request  SubmitRequest — blocks until END_STREAM. This CANNOT complete
//               until the loop thread has adopted the connection and built its
//               pump, so it contains the admission hop.
//
//  So the prediction is specific: if FIX-IOCP-ADMIT-1 is right, t_connect is
//  unchanged between the two binaries and t_request on a FRESH connection
//  under load falls from seconds to milliseconds. If both move together, the
//  problem is the accept path, not admission, and P1 is back in play.
//
//  ── Shape of the run ──
//
//    1. N load threads, each with its own client, hammering /ping. These keep
//       the IOCP loops saturated with socket completions, which is the state
//       where the timeout branch stops firing and admission used to depend
//       entirely on a wake packet reaching the front of a FIFO queue.
//    2. After a warm-up, M sequential probes. Each opens a NEW connection,
//       times both phases, issues one request, and closes.
//    3. The distribution of t_request across probes is the result. Not the
//       mean — the stall appeared in roughly one run in two, so the tail is
//       the finding and a mean would bury it.
//
//  ── The confound, stated up front ──
//
//  Load generator and server share one machine, so the probe competes with N
//  load threads for cores and absolute numbers are inflated. That is
//  acceptable ONLY because this is an A/B: both binaries are measured under
//  identical client-side load, so the DIFFERENCE stays meaningful even though
//  neither column is a clean absolute. Do not quote these numbers as
//  throughput figures; they are not comparable to the recorded h2load runs.
//
//  Usage:
//    HorseNghttp2AdmitProbe [host:port] [--load N] [--probes M]
//                           [--interval MS] [--warmup MS]
//
//  Defaults: 127.0.0.1:9010, --load 100, --probes 50, --interval 200,
//            --warmup 2000
//
//  Exit code: number of probes whose t_request reached STALL_THRESHOLD_MS,
//  capped at 250, so a script can gate on it.
// ============================================================================

uses
{$IF DEFINED(FPC) AND DEFINED(UNIX)}
  cthreads,   { MUST be first on FPC/Unix — installs the pthreads manager }
{$IFEND}
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Diagnostics,
{$IFEND}
  Nghttp2.Compat,   { TInterlocked shim for FPC < 3.3.1 — no-op elsewhere }
  Nghttp2.Client;

const
  DEFAULT_HOST     = '127.0.0.1';
  DEFAULT_PORT     = 9010;
  DEFAULT_LOAD     = 100;
  DEFAULT_PROBES   = 50;
  DEFAULT_INTERVAL = 200;
  DEFAULT_WARMUP   = 2000;

  PROBE_TIMEOUT_MS = 90000;   // must exceed the 69 s worst case on record
  LOAD_TIMEOUT_MS  = 30000;

  { A probe at or above this is a stall. The observed bad run was 69 s and the
    observed good one 21 ms, so anywhere between separates them cleanly; one
    second is a round number far clear of both, and far clear of the ~10 ms
    healthy request time. }
  STALL_THRESHOLD_MS = 1000.0;

type
  { A named dynamic-array type rather than open-array parameters. Passing a
    dynamic array to a `var array of Double` is legal but is one of the corners
    where Delphi and FPC's Delphi mode have historically differed, and this
    program has to build on three compilers. A plain named type has no such
    corner, and no generics, so FPC 3.2.2 is happy too. }
  TDoubleArray = array of Double;

var
  GHost:     string  = DEFAULT_HOST;
  GPort:     Word    = DEFAULT_PORT;
  GLoad:     Integer = DEFAULT_LOAD;
  GProbes:   Integer = DEFAULT_PROBES;
  GInterval: Integer = DEFAULT_INTERVAL;
  GWarmup:   Integer = DEFAULT_WARMUP;

  { Ramp capture. Every load thread's FIRST connection is a member of one
    simultaneous burst — which is the condition the recorded stall was measured
    under (h2load establishing 100 connections at once), and the condition a
    sequential probe cannot create. Each thread writes its OWN slot by index, so
    no lock is needed; -1 means the thread never got a first response. }
  GRampConnect: TDoubleArray;
  GRampFirst:   TDoubleArray;

  GStop:        Integer = 0;   // 0/1, interlocked
  GLoadReqs:    Integer = 0;   // requests completed by load threads
  GLoadErrs:    Integer = 0;   // reconnects forced by an error
  GLoadLive:    Integer = 0;   // load threads currently holding a connection

{$IF NOT DEFINED(FPC)}
var
  GBaseTicks: Int64 = 0;
{$IFEND}

// ─── Timing ─────────────────────────────────────────────────────────────────

{ Milliseconds as a Double, so sub-millisecond probe times survive. Delphi
  reads the performance counter as a DELTA from a baseline captured at start:
  multiplying the raw counter by 1e6 before dividing overflows Int64 on a
  machine with a long uptime, which is a silent wrong answer rather than an
  error. FPC falls back to Now, matching HorseNghttp2TestClient's guard — its
  ~1 ms resolution is coarse for the healthy case but this tool exists to find
  multi-second outliers. }
function NowMs: Double;
begin
{$IF DEFINED(FPC)}
  Result := Now * 86400.0 * 1000.0;
{$ELSE}
  Result := (TStopwatch.GetTimeStamp - GBaseTicks) * 1000.0 / TStopwatch.Frequency;
{$IFEND}
end;

function Stopping: Boolean;
begin
  Result := TInterlocked.CompareExchange(GStop, 0, 0) <> 0;
end;

// ─── Load thread ────────────────────────────────────────────────────────────

type
  { One background connection issuing /ping continuously. One client per
    thread, never shared: TNghttp2Client is documented as not thread-safe, and
    concurrency here means many connections, not a shared session. }
  TLoadThread = class(TThread)
  private
    FClient: TNghttp2Client;
    FIndex:  Integer;
    FFirst:  Boolean;   // still to record this thread's ramp timings?
    procedure RunConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(AIndex: Integer);
  end;

constructor TLoadThread.Create(AIndex: Integer);
begin
  FIndex := AIndex;
  FFirst := True;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TLoadThread.RunConnection;
var
  LResp: TNghttp2Response;
  LT0, LT1, LT2: Double;
begin
  FClient := TNghttp2Client.Create;
  try
    LT0 := NowMs;
    FClient.Connect(GHost, GPort);
    LT1 := NowMs;
    TInterlocked.Increment(GLoadLive);
    try
      while not Stopping do
      begin
        LResp := FClient.SubmitRequest('GET', '/ping', nil, nil, LOAD_TIMEOUT_MS);
        if LResp.Status <> 200 then
          Break;
        { The first response on this thread's first connection closes the ramp
          measurement: it is the moment a loop thread had actually adopted this
          socket. Only the first — a later reconnect arrives alone, into a warm
          server, which is a different experiment. }
        if FFirst then
        begin
          LT2 := NowMs;
          GRampConnect[FIndex] := LT1 - LT0;
          GRampFirst[FIndex]   := LT2 - LT0;
          FFirst := False;
        end;
        TInterlocked.Increment(GLoadReqs);
      end;
    finally
      TInterlocked.Decrement(GLoadLive);
    end;
  finally
    FreeAndNil(FClient);
  end;
end;

procedure TLoadThread.Execute;
begin
  while not Stopping do
  begin
    try
      RunConnection;
    except
      // A dropped background connection is data, not a failure: it is counted
      // and retried. Letting it escape would silently shrink the load as the
      // run went on, so the probes late in a run would face less pressure
      // than the ones early — the measurement would drift under itself.
      TInterlocked.Increment(GLoadErrs);
    end;
    if not Stopping then
      Sleep(20);
  end;
end;

// ─── Statistics ─────────────────────────────────────────────────────────────

{ Insertion sort on a small array. Deliberately not TArray.Sort: this program
  must build on FPC 3.2.2 as well as trunk and Delphi, and keeping generic
  specialization out of it removes a whole class of compiler difference for a
  sort of at most a few hundred elements. }
procedure SortAsc(var A: TDoubleArray);
var
  I, J: Integer;
  LKey: Double;
begin
  for I := 1 to High(A) do
  begin
    LKey := A[I];
    J := I - 1;
    while (J >= 0) and (A[J] > LKey) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := LKey;
  end;
end;

{ Nearest-rank percentile over an already-sorted array. }
function Pct(const A: TDoubleArray; APct: Double): Double;
var
  LIdx: Integer;
begin
  if Length(A) = 0 then Exit(0);
  LIdx := Trunc(APct / 100.0 * (Length(A) - 1) + 0.5);
  if LIdx < 0 then LIdx := 0;
  if LIdx > High(A) then LIdx := High(A);
  Result := A[LIdx];
end;

function MeanOf(const A: TDoubleArray): Double;
var
  I: Integer;
  LSum: Double;
begin
  if Length(A) = 0 then Exit(0);
  LSum := 0;
  for I := 0 to High(A) do
    LSum := LSum + A[I];
  Result := LSum / Length(A);
end;

{ Threads that never completed a first request leave -1 behind. Reporting those
  as zeros would drag every percentile toward the floor and make a badly stalled
  ramp look fast, so they are dropped and counted separately. }
function Compact(const A: TDoubleArray): TDoubleArray;
var
  I, N: Integer;
begin
  N := 0;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    if A[I] >= 0 then
    begin
      Result[N] := A[I];
      Inc(N);
    end;
  SetLength(Result, N);
end;

procedure ReportColumn(const ALabel: string; var A: TDoubleArray);
begin
  SortAsc(A);
  WriteLn(Format('  %-10s min %9.2f   p50 %9.2f   p90 %9.2f   p99 %9.2f   max %9.2f   mean %9.2f',
    [ALabel, Pct(A, 0), Pct(A, 50), Pct(A, 90), Pct(A, 99), Pct(A, 100), MeanOf(A)]));
end;

// ─── Argument parsing ───────────────────────────────────────────────────────

procedure ParseArgs;
var
  I, LColon: Integer;
  LArg, LTarget: string;
begin
  I := 1;
  while I <= ParamCount do
  begin
    LArg := ParamStr(I);
    if LArg = '--load' then
    begin
      Inc(I); GLoad := StrToIntDef(ParamStr(I), DEFAULT_LOAD);
    end
    else if LArg = '--probes' then
    begin
      Inc(I); GProbes := StrToIntDef(ParamStr(I), DEFAULT_PROBES);
    end
    else if LArg = '--interval' then
    begin
      Inc(I); GInterval := StrToIntDef(ParamStr(I), DEFAULT_INTERVAL);
    end
    else if LArg = '--warmup' then
    begin
      Inc(I); GWarmup := StrToIntDef(ParamStr(I), DEFAULT_WARMUP);
    end
    else if Copy(LArg, 1, 2) <> '--' then
    begin
      // Bare argument: host or host:port.
      LTarget := LArg;
      LColon  := Pos(':', LTarget);
      if LColon > 0 then
      begin
        GHost := Copy(LTarget, 1, LColon - 1);
        GPort := StrToIntDef(Copy(LTarget, LColon + 1, MaxInt), DEFAULT_PORT);
      end
      else
        GHost := LTarget;
    end;
    Inc(I);
  end;
  if GLoad   < 0 then GLoad   := 0;
  if GProbes < 1 then GProbes := 1;
end;

// ─── Main ───────────────────────────────────────────────────────────────────

procedure Main;
var
  LThreads:  array of TLoadThread;
  LConnect:  TDoubleArray;
  LRequest:  TDoubleArray;
  LOkCount, LFailCount, LStalls, I: Integer;
  LClient:   TNghttp2Client;
  LResp:     TNghttp2Response;
  LT0, LT1, LT2, LCon, LReq: Double;
  LStatus:   Integer;
  LNote:     string;
  LRampC, LRampF: TDoubleArray;
  LRampStalls: Integer;
begin
  ParseArgs;

  WriteLn('HorseNghttp2AdmitProbe - admission-latency probe (FIX-IOCP-ADMIT-1)');
  WriteLn(Format('target %s:%d   load %d   probes %d   interval %d ms   warmup %d ms',
    [GHost, GPort, GLoad, GProbes, GInterval, GWarmup]));
  WriteLn;
  WriteLn('t_connect = TCP handshake + preface write (kernel backlog; should NOT move)');
  WriteLn('t_request = first request to END_STREAM (contains the admission hop)');
  WriteLn;

  SetLength(LThreads, GLoad);
  SetLength(GRampConnect, GLoad);
  SetLength(GRampFirst, GLoad);
  for I := 0 to GLoad - 1 do
  begin
    GRampConnect[I] := -1;
    GRampFirst[I]   := -1;
  end;
  { Created in one tight loop deliberately: the burst is the experiment. }
  for I := 0 to GLoad - 1 do
    LThreads[I] := TLoadThread.Create(I);

  try
    if GLoad > 0 then
    begin
      WriteLn(Format('Warming up %d load connections for %d ms...', [GLoad, GWarmup]));
      Sleep(GWarmup);
      WriteLn(Format('  connected %d/%d   requests so far %d   reconnects %d',
        [TInterlocked.CompareExchange(GLoadLive, 0, 0), GLoad,
         TInterlocked.CompareExchange(GLoadReqs, 0, 0),
         TInterlocked.CompareExchange(GLoadErrs, 0, 0)]));
      { A load phase that never connected measures nothing. Say so rather than
        producing a clean-looking probe table taken against an idle server —
        that is the "neither side stalls" false pass. }
      if TInterlocked.CompareExchange(GLoadLive, 0, 0) = 0 then
      begin
        WriteLn;
        WriteLn('  *** NO load connections established - the server is idle.');
        WriteLn('  *** Probe results below would NOT exercise the defect.');
      end;
      WriteLn;
    end;

    SetLength(LConnect, 0);
    SetLength(LRequest, 0);
    LOkCount   := 0;
    LFailCount := 0;

    WriteLn('  #    t_connect ms   t_request ms   status');
    for I := 1 to GProbes do
    begin
      if Stopping then Break;
      LCon := 0; LReq := 0; LStatus := 0; LNote := '';

      LClient := TNghttp2Client.Create;
      try
        try
          LT0 := NowMs;
          LClient.Connect(GHost, GPort);
          LT1 := NowMs;
          LResp := LClient.SubmitRequest('GET', '/ping', nil, nil, PROBE_TIMEOUT_MS);
          LT2 := NowMs;

          LCon    := LT1 - LT0;
          LReq    := LT2 - LT1;
          LStatus := LResp.Status;

          SetLength(LConnect, Length(LConnect) + 1);
          LConnect[High(LConnect)] := LCon;
          SetLength(LRequest, Length(LRequest) + 1);
          LRequest[High(LRequest)] := LReq;
          Inc(LOkCount);
        except
          on E: Exception do
          begin
            Inc(LFailCount);
            LNote := 'FAILED ' + E.ClassName + ': ' + E.Message;
          end;
        end;
      finally
        LClient.Free;
      end;

      if LNote <> '' then
        WriteLn(Format('  %-4d %14s %14s   %s', [I, '-', '-', LNote]))
      else
        WriteLn(Format('  %-4d %14.2f %14.2f   %d', [I, LCon, LReq, LStatus]));

      if GInterval > 0 then
        Sleep(GInterval);
    end;
  finally
    TInterlocked.Exchange(GStop, 1);
    for I := 0 to High(LThreads) do
      if LThreads[I] <> nil then
      begin
        LThreads[I].WaitFor;
        LThreads[I].Free;
      end;
  end;

  LStalls := 0;
  LRampStalls := 0;
  for I := 0 to High(LRequest) do
    if LRequest[I] >= STALL_THRESHOLD_MS then
      Inc(LStalls);

  WriteLn;
  WriteLn('-- Summary ------------------------------------------------------');
  WriteLn(Format('  probes ok %d   failed %d', [LOkCount, LFailCount]));
  WriteLn(Format('  load requests completed %d   reconnects %d',
    [TInterlocked.CompareExchange(GLoadReqs, 0, 0),
     TInterlocked.CompareExchange(GLoadErrs, 0, 0)]));
  WriteLn;

  { The ramp block is the one that reproduces the recorded condition: GLoad
    connections arriving simultaneously, each timed from connect to its first
    served response. The probe block below it measures a single arrival into an
    already-warm server, which is a gentler question. }
  LRampC := Compact(GRampConnect);
  LRampF := Compact(GRampFirst);
  if Length(LRampF) > 0 then
  begin
    WriteLn(Format('  RAMP - %d simultaneous connections, %d reached a first response',
      [GLoad, Length(LRampF)]));
    ReportColumn('r_connect', LRampC);
    ReportColumn('r_first', LRampF);
    LRampStalls := 0;
    for I := 0 to High(LRampF) do
      if LRampF[I] >= STALL_THRESHOLD_MS then
        Inc(LRampStalls);
    WriteLn(Format('  ramp connections with r_first >= %.0f ms: %d / %d',
      [STALL_THRESHOLD_MS, LRampStalls, Length(LRampF)]));
    WriteLn;
  end;

  if LOkCount > 0 then
  begin
    WriteLn(Format('  STEADY - %d single arrivals into a warm server', [LOkCount]));
    ReportColumn('t_connect', LConnect);
    ReportColumn('t_request', LRequest);
  end;
  WriteLn;
  WriteLn(Format('  probes with t_request >= %.0f ms: %d / %d',
    [STALL_THRESHOLD_MS, LStalls, LOkCount]));
  WriteLn;
  WriteLn('  Read the RAMP block first - simultaneous arrivals are the condition');
  WriteLn('  the recorded 6.23 s stall was measured under. A single arrival into');
  WriteLn('  a warm server (STEADY) is a gentler question and may look clean');
  WriteLn('  even when the defect is present.');
  WriteLn('  In both blocks read the *_first / t_request column, not the connect');
  WriteLn('  one: connect completes out of the kernel backlog and should look');
  WriteLn('  healthy in BOTH binaries. A connect difference would mean the accept');
  WriteLn('  path, not admission.');

  { Exit code counts BOTH populations. The ramp is the one expected to show the
    defect, so an exit code driven only by the steady-state probes would report
    success on precisely the run that found something. }
  if (LStalls + LRampStalls) > 250 then
    ExitCode := 250
  else
    ExitCode := LStalls + LRampStalls;
end;

begin
{$IF NOT DEFINED(FPC)}
  GBaseTicks := TStopwatch.GetTimeStamp;
{$IFEND}
  try
    Main;
  except
    on E: Exception do
    begin
      WriteLn('FATAL ', E.ClassName, ': ', E.Message);
      ExitCode := 255;
    end;
  end;
end.
