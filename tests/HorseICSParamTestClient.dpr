program HorseICSParamTestClient;

{$APPTYPE CONSOLE}

(*
  Horse + OverbyteICS  —  Named-parameter isolation + feature parity test client
  =============================================================================
  Destination: horse-provider-ics/samples/tests/HorseICSParamTestClient.dpr

  Requires HorseICSParamTestServer running on 127.0.0.1:9110.
  Exit code = number of failed assertions (0 = all passed).

  Drives the ICS server with TCrossHttpClient (used purely as a provider-neutral
  HTTP client — the server transport under test is OverbyteICS).  Mirrors the
  CrossSocket/mORMot A–K matrix EXCEPT:

    • Section H (stream body) — ICS reads the response-owned ContentStream
      SYNCHRONOUSLY in WriteBody (no async Send(TStream) window like CrossSocket).
    • Section I (multipart)   — decoded by ICS's TFormDataAnalyser; full parity
      with the CrossSocket / mORMot multipart suites.

  Test matrix
  -----------
  [A] single param cross-method contamination (01-07)
  [B] five-round DELETE/PUT contamination cycle (08-17)
  [C] two-param routes (18-19)
  [D] real-world URL pattern from the bug report (20-21)
  [E] same method, five sequential DELETEs (22-26)
  [F] memory growth / pool-leak detection (F5-F7)
  [G] concurrent param isolation (G1)
  [H] response body via stream — Res.SendFile (H1-H2)
  [I] multipart upload — text fields + file part via ContentFields (I1-I3)
  [J] wildcard catch-all + SendFile — PATCH-SENDFILE-1 (J1)
  [K] RFC 6265 cookies — multiple Set-Cookie + attributes — PATCH-COOKIE-1 (K1-K2)
*)

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.SyncObjs,
  Net.CrossHttpClient,
  Net.CrossHttpParams;

const
  BASE_URL     = 'http://127.0.0.1:9110';
  TIMEOUT_MS   = 8000;

  MEM_WARMUP_COUNT = 200;
  MEM_STRESS_COUNT = 1000;
  MEM_FAIL_KB      = 2000;
  MEM_WARN_KB      = 2;

  // Section H — stream-body transfer.  Must match HorseICSParamTestServer.
  STREAM_SMALL_PAYLOAD =
    'stream-body-OK-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  STREAM_LARGE_LEN = 65536;

  // Section J — wildcard catch-all + SendFile.  Must match the server.
  WILDCARD_PAYLOAD = 'wildcard-sendfile-OK-0123456789-ABCDEF';

// ── Global counters ────────────────────────────────────────────────────────────

var
  GPassCount: Integer = 0;
  GFailCount: Integer = 0;

// ── Types ──────────────────────────────────────────────────────────────────────

type
  TReqResult = record
    StatusCode: Integer;
    Body:       string;
    Cookies:    string;   // all Set-Cookie header values, LF-joined (Section K)
    TimedOut:   Boolean;
  end;

  TConcSlot = class
    ExpectedId: string;
    StatusCode: Integer;
    Body:       string;
    Done:       TEvent;
    constructor Create(const AId: string);
    destructor  Destroy; override;
  end;

{ TConcSlot }

constructor TConcSlot.Create(const AId: string);
begin
  ExpectedId := AId;
  StatusCode := 0;
  Body       := '';
  Done       := TEvent.Create(nil, True, False, '');
end;

destructor TConcSlot.Destroy;
begin
  Done.Free;
  inherited;
end;

// ── Helpers ────────────────────────────────────────────────────────────────────

function StreamToStr(AStream: TStream): string;
var
  LBytes: TBytes;
begin
  Result := '';
  if not Assigned(AStream) or (AStream.Size = 0) then
    Exit;
  AStream.Position := 0;
  SetLength(LBytes, AStream.Size);
  AStream.ReadBuffer(LBytes[0], AStream.Size);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

function BuildLargePayload(const ALen: Integer): string;
var
  I: Integer;
begin
  SetLength(Result, ALen);
  for I := 1 to ALen do
    Result[I] := Chr(Ord('A') + ((I - 1) mod 26));
end;

{ Synchronous multipart/form-data POST: two text fields + one in-memory file part.
  Returns True if the request did not time out.  The ICS server does not decode
  the parts in v1 — this just exercises the path. }
function DoMultipart(
  const AClient:      TCrossHttpClient;
  const AUrl:         string;
  const AField1:      string;
  const AField2:      string;
  const AFileField:   string;
  const AFileName:    string;
  const AFileContent: string;
  out   AResult:      TReqResult
): Boolean;
const
  BOUNDARY = '----HorseMultipartTestBoundary7e9f';
var
  LEvent:   TEvent;
  LLocal:   TReqResult;
  LBodyStr: string;
  LBody:    TBytes;
begin
  LLocal := Default(TReqResult);
  LEvent := TEvent.Create(nil, True, False, '');
  try
    // Build the multipart/form-data body by hand (RFC 7578) so its size is known.
    // Passing a TBytes body makes TCrossHttpClient send Content-Length rather than
    // chunked transfer-encoding — ICS's THttpServer rejects POSTs that arrive with
    // no Content-Length (ProcessPostPutPat -> 400 + close), so a chunked upload
    // never reaches the handler. Real browsers send Content-Length on uploads too.
    LBodyStr :=
      '--' + BOUNDARY + #13#10 +
      'Content-Disposition: form-data; name="field1"' + #13#10#13#10 +
      AField1 + #13#10 +
      '--' + BOUNDARY + #13#10 +
      'Content-Disposition: form-data; name="field2"' + #13#10#13#10 +
      AField2 + #13#10 +
      '--' + BOUNDARY + #13#10 +
      'Content-Disposition: form-data; name="' + AFileField + '"; filename="' +
        AFileName + '"' + #13#10 +
      'Content-Type: application/octet-stream' + #13#10#13#10 +
      AFileContent + #13#10 +
      '--' + BOUNDARY + '--' + #13#10;
    LBody := TEncoding.UTF8.GetBytes(LBodyStr);

    AClient.DoRequest('POST', AUrl,
      nil,        // request headers — Content-Type is set in the init proc below
      LBody,      // TBytes body => TCrossHttpClient sends Content-Length
      nil,        // response stream (auto-created)
      procedure(const ARequest: ICrossHttpClientRequest)
      begin
        ARequest.Header['Content-Type'] :=
          'multipart/form-data; boundary=' + BOUNDARY;
      end,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          LLocal.StatusCode := AResp.StatusCode;
          LLocal.Body       := StreamToStr(AResp.Content);
        end;
        LEvent.SetEvent;
      end);

    LLocal.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
  finally
    LEvent.Free;
  end;
  AResult := LLocal;
  Result  := not AResult.TimedOut;
end;

{ Synchronous HTTP request via TCrossHttpClient. Returns True if not timed out. }
function DoSync(
  const AClient:  TCrossHttpClient;
  const AMethod:  string;
  const AUrl:     string;
  const ABodyStr: string;
  out   AResult:  TReqResult
): Boolean;
var
  LEvent: TEvent;
  LLocal: TReqResult;
  LBody:  TBytes;
begin
  LLocal   := Default(TReqResult);
  LEvent   := TEvent.Create(nil, True, False, '');
  try
    if ABodyStr <> '' then
      LBody := TEncoding.UTF8.GetBytes(ABodyStr)
    else
      LBody := nil;

    AClient.DoRequest(AMethod, AUrl, nil, LBody, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      var
        NV: TNameValue;
      begin
        if AResp <> nil then
        begin
          LLocal.StatusCode := AResp.StatusCode;
          LLocal.Body       := StreamToStr(AResp.Content);
          for NV in AResp.Header do
            if SameText(NV.Name, 'Set-Cookie') then
              LLocal.Cookies := LLocal.Cookies + NV.Value + #10;
        end;
        LEvent.SetEvent;
      end);

    LLocal.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
  finally
    LEvent.Free;
  end;
  AResult := LLocal;
  Result  := not AResult.TimedOut;
end;

procedure Check(const AName: string; const APassed: Boolean;
  const ADetail: string = '');
begin
  if APassed then
  begin
    Writeln(Format('  PASS  %s', [AName]));
    Inc(GPassCount);
  end
  else
  begin
    if ADetail <> '' then
      Writeln(Format('  FAIL  %s  [%s]', [AName, ADetail]))
    else
      Writeln(Format('  FAIL  %s', [AName]));
    Inc(GFailCount);
  end;
end;

function JsonValue(const AJson, AKey: string): string;
var
  LPattern: string;
  LPos:     Integer;
  LStart:   Integer;
begin
  Result   := '';
  LPattern := '"' + AKey + '":"';
  LPos     := Pos(LPattern, AJson);
  if LPos = 0 then
    Exit;
  LStart := LPos + Length(LPattern);
  while (LStart <= Length(AJson)) and (AJson[LStart] <> '"') do
  begin
    Result := Result + AJson[LStart];
    Inc(LStart);
  end;
end;

function JsonInt64(const AJson, AKey: string; ADefault: Int64 = -1): Int64;
var
  LPattern: string;
  LPos:     Integer;
  LStart:   Integer;
  LStr:     string;
begin
  Result   := ADefault;
  LPattern := '"' + AKey + '":';
  LPos     := Pos(LPattern, AJson);
  if LPos = 0 then
    Exit;
  LStart := LPos + Length(LPattern);
  while (LStart <= Length(AJson)) and
        (AJson[LStart] in ['0'..'9', '-']) do
  begin
    LStr := LStr + AJson[LStart];
    Inc(LStart);
  end;
  if LStr <> '' then
    Result := StrToInt64Def(LStr, ADefault);
end;

function ServerMemKB(const AClient: TCrossHttpClient): Int64;
var
  R: TReqResult;
begin
  Result := -1;
  if DoSync(AClient, 'GET', BASE_URL + '/mem', '', R) then
    Result := JsonInt64(R.Body, 'workingSetKB');
end;

function ServerPoolIdle(const AClient: TCrossHttpClient): Int64;
var
  R: TReqResult;
begin
  Result := -1;
  if DoSync(AClient, 'GET', BASE_URL + '/mem/pool', '', R) then
    Result := JsonInt64(R.Body, 'idleCount');
end;

procedure FireConc(
  const AClient: TCrossHttpClient;
  const AUrl:    string;
        ASlot:   TConcSlot
);
var
  LEmpty: TBytes;
begin
  AClient.DoRequest('GET', AUrl, nil, LEmpty, nil, nil,
    procedure(const AResp: ICrossHttpClientResponse)
    begin
      if AResp <> nil then
      begin
        ASlot.StatusCode := AResp.StatusCode;
        ASlot.Body       := StreamToStr(AResp.Content);
      end;
      ASlot.Done.SetEvent;
    end);
end;

// ── Test suite ─────────────────────────────────────────────────────────────────

procedure RunTests(const AClient: TCrossHttpClient);
var
  R:          TReqResult;
  GotId:      string;
  GotA, GotB: string;
  GotUuid:    string;
  Round:      Integer;
  DelVal:     string;
  PutVal:     string;
  SeqVal:     string;
  I:          Integer;
  M1, M2:   Int64;
  P1, P2:   Int64;
  GrowthKB: Int64;
  LConc:    array[0..7] of TConcSlot;
  LAllOK:   Boolean;
  LFailed:  string;
  J:        Integer;

  procedure Section(const ATitle: string);
  begin
    Writeln('');
    Writeln('── ' + ATitle + ' ─');
  end;

  procedure Fire(const AMethod, APath, ABody: string);
  var
    LR: TReqResult;
  begin
    DoSync(AClient, AMethod, BASE_URL + APath, ABody, LR);
  end;

begin

  // ════════════════════════════════════════════════════════════════════════════
  Section('A  Single param, cross-method contamination');
  // ════════════════════════════════════════════════════════════════════════════

  if DoSync(AClient, 'GET', BASE_URL + '/ping', '', R) then
    Check('01  GET /ping -> 200 "pong"',
      (R.StatusCode = 200) and (R.Body = 'pong'),
      Format('status=%d body=%s', [R.StatusCode, R.Body]))
  else
    Check('01  GET /ping', False, 'timeout');

  if DoSync(AClient, 'DELETE', BASE_URL + '/param/first-123', '', R) then
  begin
    GotId := JsonValue(R.Body, 'id');
    Check('02  DELETE /param/first-123 -> id="first-123"',
      (R.StatusCode = 200) and (GotId = 'first-123'),
      Format('id="%s"', [GotId]));
  end
  else
    Check('02  DELETE /param/first-123', False, 'timeout');

  if DoSync(AClient, 'PUT', BASE_URL + '/param/second-456', '', R) then
  begin
    GotId := JsonValue(R.Body, 'id');
    Check('03  PUT /param/second-456 -> id="second-456" (not carried from DELETE)',
      (R.StatusCode = 200) and (GotId = 'second-456'),
      Format('id="%s"', [GotId]));
  end
  else
    Check('03  PUT /param/second-456', False, 'timeout');

  if DoSync(AClient, 'GET', BASE_URL + '/param/get-val', '', R) then
  begin
    GotId := JsonValue(R.Body, 'id');
    Check('04  GET /param/get-val -> id="get-val"',
      (R.StatusCode = 200) and (GotId = 'get-val'),
      Format('id="%s"', [GotId]));
  end
  else
    Check('04  GET /param/get-val', False, 'timeout');

  if DoSync(AClient, 'PATCH', BASE_URL + '/param/patch-val', '', R) then
  begin
    GotId := JsonValue(R.Body, 'id');
    Check('05  PATCH /param/patch-val -> id="patch-val" (not "get-val")',
      (R.StatusCode = 200) and (GotId = 'patch-val'),
      Format('id="%s"', [GotId]));
  end
  else
    Check('05  PATCH /param/patch-val', False, 'timeout');

  if DoSync(AClient, 'POST', BASE_URL + '/param/post-val', 'hello', R) then
  begin
    GotId := JsonValue(R.Body, 'id');
    Check('06  POST /param/post-val -> id="post-val"',
      (R.StatusCode = 200) and (GotId = 'post-val'),
      Format('id="%s"', [GotId]));
  end
  else
    Check('06  POST /param/post-val', False, 'timeout');

  if DoSync(AClient, 'DELETE', BASE_URL + '/param/after-post', '', R) then
  begin
    GotId := JsonValue(R.Body, 'id');
    Check('07  DELETE /param/after-post -> id="after-post" (not "post-val")',
      (R.StatusCode = 200) and (GotId = 'after-post'),
      Format('id="%s"', [GotId]));
  end
  else
    Check('07  DELETE /param/after-post', False, 'timeout');

  // ════════════════════════════════════════════════════════════════════════════
  Section('B  Five-round DELETE/PUT contamination cycle');
  // ════════════════════════════════════════════════════════════════════════════

  for Round := 1 to 5 do
  begin
    DelVal := Format('r%d-del', [Round]);
    PutVal := Format('r%d-put', [Round]);

    if DoSync(AClient, 'DELETE', BASE_URL + '/param/' + DelVal, '', R) then
    begin
      GotId := JsonValue(R.Body, 'id');
      Check(Format('Round %d  DELETE /param/%s', [Round, DelVal]),
        (R.StatusCode = 200) and (GotId = DelVal),
        Format('id="%s"', [GotId]));
    end
    else
      Check(Format('Round %d  DELETE /param/%s', [Round, DelVal]), False, 'timeout');

    if DoSync(AClient, 'PUT', BASE_URL + '/param/' + PutVal, '', R) then
    begin
      GotId := JsonValue(R.Body, 'id');
      Check(Format('Round %d  PUT    /param/%s (not "%s")', [Round, PutVal, DelVal]),
        (R.StatusCode = 200) and (GotId = PutVal),
        Format('id="%s"', [GotId]));
    end
    else
      Check(Format('Round %d  PUT    /param/%s', [Round, PutVal]), False, 'timeout');
  end;

  // ════════════════════════════════════════════════════════════════════════════
  Section('C  Two-param routes');
  // ════════════════════════════════════════════════════════════════════════════

  if DoSync(AClient, 'DELETE', BASE_URL + '/multi/del-a/del-b', '', R) then
  begin
    GotA := JsonValue(R.Body, 'a');
    GotB := JsonValue(R.Body, 'b');
    Check('18  DELETE /multi/del-a/del-b -> a="del-a", b="del-b"',
      (R.StatusCode = 200) and (GotA = 'del-a') and (GotB = 'del-b'),
      Format('a="%s" b="%s"', [GotA, GotB]));
  end
  else
    Check('18  DELETE /multi/del-a/del-b', False, 'timeout');

  if DoSync(AClient, 'PUT', BASE_URL + '/multi/put-a/put-b', '', R) then
  begin
    GotA := JsonValue(R.Body, 'a');
    GotB := JsonValue(R.Body, 'b');
    Check('19  PUT /multi/put-a/put-b -> a="put-a", b="put-b" (not del-a/del-b)',
      (R.StatusCode = 200) and (GotA = 'put-a') and (GotB = 'put-b'),
      Format('a="%s" b="%s"', [GotA, GotB]));
  end
  else
    Check('19  PUT /multi/put-a/put-b', False, 'timeout');

  // ════════════════════════════════════════════════════════════════════════════
  Section('D  Real-world URL pattern from the bug report');
  // ════════════════════════════════════════════════════════════════════════════

  if DoSync(AClient, 'DELETE',
      BASE_URL + '/product_category/uuid_product_category/uuid-del-123', '', R) then
  begin
    GotUuid := JsonValue(R.Body, 'uuid');
    Check('20  DELETE /product_category/.../uuid-del-123 -> uuid="uuid-del-123"',
      (R.StatusCode = 200) and (GotUuid = 'uuid-del-123'),
      Format('uuid="%s"', [GotUuid]));
  end
  else
    Check('20  DELETE /product_category/.../uuid-del-123', False, 'timeout');

  if DoSync(AClient, 'PUT',
      BASE_URL + '/product_category/uuid_product_category/uuid-put-456', '', R) then
  begin
    GotUuid := JsonValue(R.Body, 'uuid');
    Check('21  PUT /product_category/.../uuid-put-456 -> uuid="uuid-put-456" ** bug target **',
      (R.StatusCode = 200) and (GotUuid = 'uuid-put-456'),
      Format('uuid="%s" (contamination from uuid-del-123?)', [GotUuid]));
  end
  else
    Check('21  PUT /product_category/.../uuid-put-456', False, 'timeout');

  // ════════════════════════════════════════════════════════════════════════════
  Section('E  Same method, five sequential DELETEs');
  // ════════════════════════════════════════════════════════════════════════════

  for Round := 1 to 5 do
  begin
    SeqVal := Format('seq-%d', [Round]);
    if DoSync(AClient, 'DELETE', BASE_URL + '/param/' + SeqVal, '', R) then
    begin
      GotId := JsonValue(R.Body, 'id');
      Check(Format('%02d  DELETE /param/%s -> id="%s"', [21 + Round, SeqVal, SeqVal]),
        (R.StatusCode = 200) and (GotId = SeqVal),
        Format('id="%s"', [GotId]));
    end
    else
      Check(Format('%02d  DELETE /param/%s', [21 + Round, SeqVal]), False, 'timeout');
  end;

  // ════════════════════════════════════════════════════════════════════════════
  Section('F  Memory growth (leak detection)');
  // ════════════════════════════════════════════════════════════════════════════

  Writeln(Format('  Warming up (%d requests, pool fill + OS stabilisation)...',
    [MEM_WARMUP_COUNT]));
  for I := 1 to MEM_WARMUP_COUNT do
  begin
    case (I mod 6) of
      0: Fire('DELETE', '/param/warm-' + IntToStr(I), '');
      1: Fire('PUT',    '/param/warm-' + IntToStr(I), '');
      2: Fire('GET',    '/param/warm-' + IntToStr(I), '');
      3: Fire('PATCH',  '/param/warm-' + IntToStr(I), '');
      4: Fire('POST',   '/param/warm-' + IntToStr(I), 'body-warm-' + IntToStr(I));
      5: Fire('DELETE', '/multi/w' + IntToStr(I) + '/x' + IntToStr(I), '');
    end;
    if (I mod 50 = 0) then
      Write(Format('    %d...', [I]));
  end;
  if MEM_WARMUP_COUNT >= 50 then
    Writeln('');

  M1 := ServerMemKB(AClient);
  P1 := ServerPoolIdle(AClient);

  if M1 < 0 then
    Writeln('  Note: /mem returned -1 — working-set measurement not available on this platform.')
  else
    Writeln(Format('  Baseline: working-set = %d KB,  pool idle = %d', [M1, P1]));

  Writeln(Format('  Stress run (%d requests)...', [MEM_STRESS_COUNT]));
  for I := 1 to MEM_STRESS_COUNT do
  begin
    case (I mod 6) of
      0: Fire('DELETE', '/param/s-' + IntToStr(I), '');
      1: Fire('PUT',    '/param/s-' + IntToStr(I), '');
      2: Fire('GET',    '/param/s-' + IntToStr(I), '');
      3: Fire('PATCH',  '/param/s-' + IntToStr(I), '');
      4: Fire('POST',   '/param/s-' + IntToStr(I), 'body-s-' + IntToStr(I));
      5: Fire('DELETE', '/multi/a' + IntToStr(I) + '/b' + IntToStr(I), '');
    end;
    if (I mod 100 = 0) then
      Write(Format('    %d...', [I]));
  end;
  if MEM_STRESS_COUNT >= 100 then
    Writeln('');

  M2 := ServerMemKB(AClient);
  P2 := ServerPoolIdle(AClient);

  if M2 >= 0 then
    Writeln(Format('  Final:    working-set = %d KB,  pool idle = %d', [M2, P2]));

  if (M1 > 0) and (M2 > 0) then
  begin
    GrowthKB := M2 - M1;
    Check(
      Format('F5  Total memory growth after %d requests < %d KB',
        [MEM_STRESS_COUNT, MEM_FAIL_KB]),
      GrowthKB < MEM_FAIL_KB,
      Format('growth=%d KB  (%.1f KB/req)',
        [GrowthKB, GrowthKB / MEM_STRESS_COUNT]));
  end
  else
    Writeln('  F5  SKIP — working-set measurement unavailable');

  if (M1 > 0) and (M2 > 0) then
  begin
    GrowthKB := M2 - M1;
    Check(
      Format('F6  Per-request growth < %d KB/req', [MEM_WARN_KB]),
      (GrowthKB / MEM_STRESS_COUNT) < MEM_WARN_KB,
      Format('%.2f KB/req  (baseline=%d KB  final=%d KB  delta=%d KB)',
        [GrowthKB / MEM_STRESS_COUNT, M1, M2, GrowthKB]));
  end
  else
    Writeln('  F6  SKIP — working-set measurement unavailable');

  if P1 >= 0 then
  begin
    Check(
      'F7  Pool idle count after stress >= pool idle at baseline (no context leaks)',
      P2 >= P1,
      Format('P1=%d  P2=%d  (dropped by %d — context(s) not returned to pool)',
        [P1, P2, P1 - P2]));
  end
  else
    Writeln('  F7  SKIP — pool idle count unavailable');

  // ════════════════════════════════════════════════════════════════════════════
  Section('G  Concurrent param isolation (race condition guard)');
  // ════════════════════════════════════════════════════════════════════════════

  for J := 0 to 7 do
    LConc[J] := TConcSlot.Create(Format('conc-g%d', [J + 1]));
  try
    for J := 0 to 7 do
      FireConc(AClient, BASE_URL + '/param/' + LConc[J].ExpectedId, LConc[J]);

    for J := 0 to 7 do
      if LConc[J].Done.WaitFor(TIMEOUT_MS) <> wrSignaled then
        LConc[J].StatusCode := -1;

    LAllOK  := True;
    LFailed := '';
    for J := 0 to 7 do
    begin
      GotId := JsonValue(LConc[J].Body, 'id');
      if (LConc[J].StatusCode <> 200) or (GotId <> LConc[J].ExpectedId) then
      begin
        LAllOK  := False;
        LFailed := LFailed + Format(
          ' slot%d(exp="%s" got="%s" status=%d)',
          [J + 1, LConc[J].ExpectedId, GotId, LConc[J].StatusCode]);
      end;
    end;

    Check(
      'G1  8 simultaneous GETs — each sees only its own :id value',
      LAllOK,
      IfThen(LFailed = '', 'all correct',
        'contamination detected:' + LFailed));

  finally
    for J := 0 to 7 do
      LConc[J].Free;
  end;

  // ════════════════════════════════════════════════════════════════════════════
  Section('H  Response body delivered via stream (Res.SendFile → synchronous drain)');
  // ════════════════════════════════════════════════════════════════════════════
  //
  // The server serves these bodies from a TStream (Res.SendFile).  PATCH-SENDFILE-1
  // copies the source into a response-owned stream; the ICS bridge reads it
  // SYNCHRONOUSLY in WriteBody (no async window).  Small payload must arrive
  // byte-for-byte; the 64 KB payload must arrive with no truncation.

  if DoSync(AClient, 'GET', BASE_URL + '/stream', '', R) then
    Check('H1  GET /stream -> small stream body transferred byte-for-byte',
      (R.StatusCode = 200) and (R.Body = STREAM_SMALL_PAYLOAD),
      Format('status=%d len=%d body="%s"', [R.StatusCode, Length(R.Body), R.Body]))
  else
    Check('H1  GET /stream', False, 'timeout');

  if DoSync(AClient, 'GET', BASE_URL + '/stream/large', '', R) then
    Check(Format('H2  GET /stream/large -> %d bytes transferred intact (no truncation)',
        [STREAM_LARGE_LEN]),
      (R.StatusCode = 200) and (Length(R.Body) = STREAM_LARGE_LEN) and
      (R.Body = BuildLargePayload(STREAM_LARGE_LEN)),
      Format('status=%d len=%d (expected %d)',
        [R.StatusCode, Length(R.Body), STREAM_LARGE_LEN]))
  else
    Check('H2  GET /stream/large', False, 'timeout');

  // ════════════════════════════════════════════════════════════════════════════
  Section('I  multipart/form-data upload (text fields + file part)');
  // ════════════════════════════════════════════════════════════════════════════
  //
  // POST a multipart/form-data body with two text fields and one in-memory file
  // part.  The ICS provider decodes it via TFormDataAnalyser
  // (OverbyteIcsFormDataDecoder) and populates Req.ContentFields (text →
  // Field.AsString, file → Field.AsStream); the server echoes them back as JSON.
  // Verifies parity with the CrossSocket / mORMot multipart suites.

  if DoMultipart(AClient, BASE_URL + '/upload',
       'multipart-field-one', 'multipart-field-two-ABC',
       'upload', 'note.txt', 'FILE-CONTENT-0123456789-abcdef', R) then
  begin
    Check('I1  POST /upload -> text field1 parsed',
      (R.StatusCode = 200) and (JsonValue(R.Body, 'field1') = 'multipart-field-one'),
      Format('status=%d field1="%s"', [R.StatusCode, JsonValue(R.Body, 'field1')]));

    Check('I2  POST /upload -> text field2 parsed (not carried from field1)',
      JsonValue(R.Body, 'field2') = 'multipart-field-two-ABC',
      Format('field2="%s"', [JsonValue(R.Body, 'field2')]));

    Check('I3  POST /upload -> file part content + length intact',
      (JsonInt64(R.Body, 'fileLen') = Length('FILE-CONTENT-0123456789-abcdef')) and
      (JsonValue(R.Body, 'fileContent') = 'FILE-CONTENT-0123456789-abcdef'),
      Format('fileLen=%d fileContent="%s"',
        [JsonInt64(R.Body, 'fileLen'), JsonValue(R.Body, 'fileContent')]));
  end
  else
    Check('I1  POST /upload', False, 'timeout');

  // ════════════════════════════════════════════════════════════════════════════
  Section('J  Wildcard catch-all + SendFile (PATCH-SENDFILE-1 — content owned)');
  // ════════════════════════════════════════════════════════════════════════════
  //
  // GET an unregistered path: Horse routes it to the server's Get('/*') catch-all,
  // which serves a file via SendFile and frees the stream in a finally (the exact
  // user-reported pattern).  PATCH-SENDFILE-1 copies the source at call time, so
  // the file is delivered correctly and the FreeAndNil is harmless.

  if DoSync(AClient, 'GET', BASE_URL + '/no/such/route', '', R) then
    Check('J1  GET /no/such/route -> Get(''/*'') + SendFile delivers the file',
      (R.StatusCode = 200) and (R.Body = WILDCARD_PAYLOAD),
      Format('status=%d len=%d body="%s"',
        [R.StatusCode, Length(R.Body), Copy(R.Body, 1, 48)]))
  else
    Check('J1  GET /no/such/route (wildcard SendFile)', False, 'timeout');

  // ════════════════════════════════════════════════════════════════════════════
  Section('K  RFC 6265 cookies — multiple Set-Cookie + attributes (PATCH-COOKIE-1)');
  // ════════════════════════════════════════════════════════════════════════════
  //
  // GET /cookies sets two cookies via the typed API.  The ICS bridge emits one
  // Set-Cookie line per cookie (BuildHeaders → EmitHeader), so the client must see
  // two distinct Set-Cookie headers with correct attribute syntax.

  if DoSync(AClient, 'GET', BASE_URL + '/cookies', '', R) then
  begin
    Check('K1  GET /cookies -> 200 + both cookies present (two Set-Cookie lines)',
      (R.StatusCode = 200) and (Pos('sid=abc123', R.Cookies) > 0) and
      (Pos('theme=dark', R.Cookies) > 0),
      Format('status=%d set-cookie=<%s>', [R.StatusCode, StringReplace(R.Cookies, #10, ' | ', [rfReplaceAll])]));

    Check('K2  attributes intact (Path=/, HttpOnly, SameSite=Lax, Max-Age=3600)',
      (Pos('Path=/', R.Cookies) > 0) and (Pos('HttpOnly', R.Cookies) > 0) and
      (Pos('SameSite=Lax', R.Cookies) > 0) and (Pos('Max-Age=3600', R.Cookies) > 0),
      Format('set-cookie=<%s>', [StringReplace(R.Cookies, #10, ' | ', [rfReplaceAll])]));
  end
  else
    Check('K1  GET /cookies', False, 'timeout');

end;

// ── Entry point ────────────────────────────────────────────────────────────────

var
  LClient: TCrossHttpClient;
begin
  Writeln('Horse + OverbyteICS  —  Param isolation + feature parity test');
  Writeln(Format('  Target: %s', [BASE_URL]));
  Writeln(Format('  Warmup: %d requests  |  Stress: %d requests',
    [MEM_WARMUP_COUNT, MEM_STRESS_COUNT]));
  Writeln('');

  LClient := TCrossHttpClient.Create(2 {IoThreads});
  try
    RunTests(LClient);
  finally
    LClient.Free;
  end;

  Writeln('');
  Writeln(Format('Results: %d passed, %d failed', [GPassCount, GFailCount]));
  ExitCode := GFailCount;
end.
