program HorseNghttp2DrainCheck;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ELSE}{$APPTYPE CONSOLE}{$ENDIF}

// ============================================================================
//  HorseNghttp2DrainCheck — the three drain-delivery shapes, in Pascal.
//
//  Why this exists
//  ───────────────
//  `verify-drain-delivery.sh` answers the question that matters — does a
//  CONFORMING client with a request genuinely in flight across the shutdown
//  trigger get its response? — but it is Linux bash driving `nghttp`, and the
//  Windows nghttp2 distribution ships the DLL without the CLI tools. So the
//  IOCP event-loop engine, which exists only on Windows, could never be put
//  through that gate. It has sat "not re-validated" for weeks for want of a
//  client, not for want of a server.
//
//  This is that client. Same three shapes, same pass condition, no cross-
//  boundary networking:
//
//    A  1 request                    — baseline
//    B  4 concurrent, 4 CONNECTIONS  — mirrors h2load -c 4 -m 1
//    C  8 streams, 1 CONNECTION      — the only shape where many streams share
//                                      one session through the drain, and so
//                                      the only one that exercises GOAWAY's
//                                      last_stream_id semantics
//
//  Case C is why TNghttp2Client gained BeginRequest/PumpAll/TakeResponse
//  (MULTISTREAM-1). With the old one-shot API it was inexpressible, and a
//  driver covering only A and B would have validated the two easy cases and
//  skipped the one that matters.
//
//  Pass condition is deliberately identical to the bash gate: count
//  occurrences of "sleptMs":<SLOW_MS> across the response bodies. Counting
//  responses rather than occurrences would report 1 for a perfect 8/8 on case
//  C, because those eight bodies arrive on one connection.
//
//  The server must ALREADY be running with shutdown-after set, and each case
//  needs its own server lifetime — the drain fires once and the process exits.
//  verify-drain-delivery.bat does that orchestration on Windows.
//
//  Usage:
//    HorseNghttp2DrainCheck case=A [host=127.0.0.1] [port=9010] [slowms=3000]
//
//  Exit code 0 = the case delivered every response; non-zero = it did not.
// ============================================================================

uses
{$IF DEFINED(FPC)}
  cthreads,          { MUST be first on Unix — case B spawns threads }
  SysUtils, Classes, SyncObjs,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs,
{$ENDIF}
  Nghttp2.Client,
  Nghttp2.Types;

const
  DEFAULT_HOST    = '127.0.0.1';
  DEFAULT_PORT    = 9010;
  DEFAULT_SLOW_MS = 3000;

  { Generous, and deliberately not the thing under test: the route sleeps
    SLOW_MS and the drain has its own timeout, so this only bounds a hang. }
  CLIENT_TIMEOUT_MS = 30000;

var
  GHost:    string  = DEFAULT_HOST;
  GPort:    Word    = DEFAULT_PORT;
  GSlowMs:  Integer = DEFAULT_SLOW_MS;
  GCase:    string  = '';

{ Mirrors count_ok() in verify-drain-delivery.sh: occurrences of the marker,
  not responses containing it. }
function CountMarker(const ABody: TBytes): Integer;
var
  LText, LNeedle: string;
  LPos: Integer;
begin
  Result := 0;
  if Length(ABody) = 0 then Exit;
  SetString(LText, PAnsiChar(@ABody[0]), Length(ABody));
  LNeedle := '"sleptMs":' + IntToStr(GSlowMs);
  LPos := Pos(LNeedle, LText);
  while LPos > 0 do
  begin
    Inc(Result);
    LPos := Pos(LNeedle, LText, LPos + Length(LNeedle));
  end;
end;

function SlowPath: string;
begin
  Result := '/slow/' + IntToStr(GSlowMs);
end;

// ─── Case A · one request ───────────────────────────────────────────────────

function CaseA: Integer;
var
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
begin
  Result := 0;
  LClient := TNghttp2Client.Create;
  try
    LClient.Connect(GHost, GPort);
    LResp := LClient.SubmitRequest('GET', SlowPath, nil, nil, CLIENT_TIMEOUT_MS);
    if LResp.Status = 200 then
      Result := CountMarker(LResp.Body);
  finally
    LClient.Free;
  end;
end;

// ─── Case B · four concurrent requests on four connections ──────────────────

type
  { One connection per thread. Failures are captured rather than raised: a
    thread that dies silently would be indistinguishable from a request the
    server never answered, which is the distinction this whole check exists to
    make. }
  TCaseBThread = class(TThread)
  private
    FDelivered: Integer;
    FError:     string;
  protected
    procedure Execute; override;
  public
    property Delivered: Integer read FDelivered;
    property Error:     string  read FError;
  end;

procedure TCaseBThread.Execute;
var
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
begin
  FDelivered := 0;
  FError     := '';
  LClient    := nil;
  { Create is INSIDE the try: it is what loads libnghttp2, so a missing
    nghttp2.dll raises here. With Create outside, that exception escaped
    Execute, TThread swallowed it into FatalException, and the case reported
    "0/4 delivered" with no reason — indistinguishable from a server that
    dropped every response. }
  try
    LClient := TNghttp2Client.Create;
    LClient.Connect(GHost, GPort);
    LResp := LClient.SubmitRequest('GET', SlowPath, nil, nil, CLIENT_TIMEOUT_MS);
    if LResp.Status = 200 then
      FDelivered := CountMarker(LResp.Body);
  except
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
  LClient.Free;
end;

function CaseB: Integer;
const
  N = 4;
var
  LThreads: array[0..N - 1] of TCaseBThread;
  I: Integer;
begin
  Result := 0;
  for I := 0 to N - 1 do
  begin
    LThreads[I] := TCaseBThread.Create(True);
    LThreads[I].FreeOnTerminate := False;
  end;
  try
    for I := 0 to N - 1 do LThreads[I].Start;
    for I := 0 to N - 1 do LThreads[I].WaitFor;
    for I := 0 to N - 1 do
    begin
      Inc(Result, LThreads[I].Delivered);
      if LThreads[I].Error <> '' then
        WriteLn('    conn ', I + 1, ' error: ', LThreads[I].Error);
    end;
  finally
    for I := 0 to N - 1 do LThreads[I].Free;
  end;
end;

// ─── Case C · eight streams on ONE connection ───────────────────────────────

function CaseC: Integer;
const
  N = 8;
var
  LClient: TNghttp2Client;
  LIds:    array[0..N - 1] of Int32;
  LResp:   TNghttp2Response;
  I: Integer;
begin
  Result := 0;
  LClient := TNghttp2Client.Create;
  try
    LClient.Connect(GHost, GPort);

    { All eight submitted BEFORE any pumping, so all eight are genuinely open
      when the drain fires. Submitting and pumping one at a time would serialise
      them and never produce the multiplexed shape. }
    for I := 0 to N - 1 do
      LIds[I] := LClient.BeginRequest('GET', SlowPath, nil, nil);

    try
      LClient.PumpAll(CLIENT_TIMEOUT_MS);
    except
      on E: Exception do
        WriteLn('    pump ended early: ', E.ClassName, ': ', E.Message);
    end;

    { Collect per stream. One failed stream must not discard the rest — that is
      exactly why TakeResponse raises per stream rather than PumpAll raising for
      all of them. }
    for I := 0 to N - 1 do
    begin
      try
        LResp := LClient.TakeResponse(LIds[I]);
        if LResp.Status = 200 then
          Inc(Result, CountMarker(LResp.Body));
      except
        on E: Exception do
          WriteLn('    stream ', LIds[I], ' error: ', E.Message);
      end;
    end;
  finally
    LClient.Free;
  end;
end;

// ─── Entry point ────────────────────────────────────────────────────────────

procedure ParseArgs;
var
  I: Integer;
  A: string;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    if Copy(A, 1, 5) = 'case=' then
      GCase := UpperCase(Copy(A, 6, MaxInt))
    else if Copy(A, 1, 5) = 'host=' then
      GHost := Copy(A, 6, MaxInt)
    else if Copy(A, 1, 5) = 'port=' then
      GPort := StrToIntDef(Copy(A, 6, MaxInt), DEFAULT_PORT)
    else if Copy(A, 1, 7) = 'slowms=' then
      GSlowMs := StrToIntDef(Copy(A, 8, MaxInt), DEFAULT_SLOW_MS);
  end;
end;

var
  LExpected: Integer = 0;   { Halt(2) below is not seen as terminating by Delphi's flow analysis }
  LDelivered: Integer = 0;
  LLabel: string;
begin
  ParseArgs;

  if GCase = 'A' then      begin LLabel := 'A  1 request';                   LExpected := 1; end
  else if GCase = 'B' then begin LLabel := 'B  4 concurrent, 4 connections'; LExpected := 4; end
  else if GCase = 'C' then begin LLabel := 'C  8 streams, 1 connection';     LExpected := 8; end
  else
  begin
    WriteLn('usage: HorseNghttp2DrainCheck case=A|B|C [host=H] [port=P] [slowms=N]');
    WriteLn;
    WriteLn('The server must already be listening, started with shutdown-after set');
    WriteLn('so the drain fires while these requests are in flight.');
    Halt(2);
  end;

  WriteLn('drain-check  ', LLabel, '   ', GHost, ':', GPort, SlowPath);

  LDelivered := 0;
  try
    if      GCase = 'A' then LDelivered := CaseA
    else if GCase = 'B' then LDelivered := CaseB
    else                     LDelivered := CaseC;
  except
    on E: Exception do
      WriteLn('    fatal: ', E.ClassName, ': ', E.Message);
  end;

  WriteLn('  ', LDelivered, '/', LExpected, ' delivered');
  if LDelivered = LExpected then
  begin
    WriteLn('  PASS');
    Halt(0);
  end;
  WriteLn('  FAIL — in-flight responses were lost across the drain');
  Halt(1);
end.
