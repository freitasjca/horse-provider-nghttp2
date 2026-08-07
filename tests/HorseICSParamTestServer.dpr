program HorseICSParamTestServer;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_ICS}

{
  Horse + OverbyteICS  —  Named-parameter isolation + feature parity test server
  =============================================================================
  Destination: horse-provider-ics/samples/tests/HorseICSParamTestServer.dpr

  ICS provider is v1 Windows + Delphi only — there is no Lazarus/FPC variant of
  this suite (unlike CrossSocket/mORMot).

  Mirrors HorseCSParamTestServer.dpr / HorseMormotParamTestServer.dpr — the full
  A–K matrix runs against ICS, including Section I (multipart/form-data), which is
  decoded via ICS's TFormDataAnalyser (OverbyteIcsFormDataDecoder) into
  Req.ContentFields, the same surface the CrossSocket / mORMot providers expose.

  Port: 9110 (distinct from CrossSocket 9100, mORMot 9200, ICS integration 9010).
  Start this server first, then run HorseICSParamTestClient.

  ReportMemoryLeaksOnShutdown is enabled so a clean Ctrl+C shutdown shows only
  genuine leaks.
}

{$IFNDEF HORSE_PROVIDER_ICS}
  {$MESSAGE FATAL 'Set HORSE_PROVIDER_ICS in Project Options → Conditional defines'}
{$ENDIF}

uses
  System.SysUtils,
  System.Classes,
{$IFDEF MSWINDOWS}
  Winapi.Windows,
  Winapi.PsAPI,
{$ENDIF}
  Horse,
  Horse.Commons,
  Horse.Core.Cookie,
  Horse.Provider.ICS,
  Horse.Provider.ICS.Pool;

const
  TEST_PORT = 9110;

  // ── Stream-body fixtures (Section H) ──────────────────────────────────────────
  // Response bodies served as a TStream via Res.SendFile.  PATCH-SENDFILE-1 makes
  // Res.SendFile COPY the source into a response-owned stream at call time; the ICS
  // response bridge then reads that owned ContentStream SYNCHRONOUSLY in WriteBody
  // (no async window — unlike CrossSocket's async Send(TStream)).  Must match
  // HorseICSParamTestClient.
  STREAM_SMALL_PAYLOAD =
    'stream-body-OK-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  STREAM_LARGE_LEN = 65536;   // large body — guards against truncation

  // ── Wildcard + SendFile regression (Section J) ────────────────────────────────
  WILDCARD_PAYLOAD = 'wildcard-sendfile-OK-0123456789-ABCDEF';

// ── Helpers ────────────────────────────────────────────────────────────────────

{ Minimal JSON string escaping for inline Format() calls. }
function JE(const S: string): string;
begin
  Result := StringReplace(S,  '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

{ Deterministic ASCII payload of ALen bytes (char[i] = 'A'..'Z' cycling). }
function BuildLargePayload(const ALen: Integer): string;
var
  I: Integer;
begin
  SetLength(Result, ALen);
  for I := 1 to ALen do
    Result[I] := Chr(Ord('A') + ((I - 1) mod 26));
end;

{ Current process working-set size in KB.  Windows: GetProcessMemoryInfo. }
function GetWorkingSetKB: Int64;
{$IFDEF MSWINDOWS}
var
  MC: PROCESS_MEMORY_COUNTERS;
begin
  if GetProcessMemoryInfo(GetCurrentProcess, @MC, SizeOf(MC)) then
    Result := MC.WorkingSetSize div 1024
  else
    Result := -1;
end;
{$ELSE}
begin
  Result := -1;   // ICS provider is Windows-only in v1.
end;
{$ENDIF}

// Process-lifetime stream fixtures — created once in RegisterRoutes, freed after
// Listen returns.  Res.SendFile copies them at call time (PATCH-SENDFILE-1) and
// the ICS bridge drains the owned copy synchronously, so the fixtures do not even
// need to outlive the request; freeing them after Listen keeps them out of the
// shutdown leak report.
var
  GStreamSmall: TStringStream = nil;
  GStreamLarge: TStringStream = nil;

// ── Route registration ─────────────────────────────────────────────────────────

procedure RegisterRoutes;
begin
  // Build the stream-body fixtures once (Section H).
  GStreamSmall := TStringStream.Create(STREAM_SMALL_PAYLOAD, TEncoding.UTF8);
  GStreamLarge := TStringStream.Create(
                    BuildLargePayload(STREAM_LARGE_LEN), TEncoding.UTF8);

  // ── Health ────────────────────────────────────────────────────────────────────
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send('pong');
    end
  );

  // ── Single-param routes ───────────────────────────────────────────────────────
  THorse.Delete('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"DELETE","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Put('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PUT","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Get('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"GET","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Patch('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PATCH","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Post('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"POST","id":"%s","body":"%s"}',
           [JE(Req.Params['id']), JE(Req.Body)]));
    end
  );

  // ── Two-param routes ──────────────────────────────────────────────────────────
  THorse.Delete('/multi/:a/:b',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"DELETE","a":"%s","b":"%s"}',
           [JE(Req.Params['a']), JE(Req.Params['b'])]));
    end
  );

  THorse.Put('/multi/:a/:b',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PUT","a":"%s","b":"%s"}',
           [JE(Req.Params['a']), JE(Req.Params['b'])]));
    end
  );

  // ── Real-world URL pattern from the bug report ────────────────────────────────
  THorse.Delete('/product_category/uuid_product_category/:uuid',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"DELETE","uuid":"%s"}',
           [JE(Req.Params['uuid'])]));
    end
  );

  THorse.Put('/product_category/uuid_product_category/:uuid',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PUT","uuid":"%s"}',
           [JE(Req.Params['uuid'])]));
    end
  );

  // ── Memory diagnostics ────────────────────────────────────────────────────────
  THorse.Get('/mem',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"workingSetKB":%d}', [GetWorkingSetKB]));
    end
  );

  THorse.Get('/mem/pool',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"idleCount":%d,"warmupSize":%d,"maxSize":%d}',
           [THorseContextPool.IdleCount,
            POOL_WARMUP_SIZE,
            POOL_MAX_SIZE]));
    end
  );

  // ── Stream-body transfer (Section H) ──────────────────────────────────────────
  // Body served from a TStream via Res.SendFile.  The ICS bridge reads the
  // response-owned ContentStream synchronously in WriteBody and answers it as the
  // body string.  The client asserts the body arrives byte-for-byte.
  THorse.Get('/stream',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.SendFile(GStreamSmall, 'stream-small.txt', 'text/plain; charset=utf-8');
    end
  );

  THorse.Get('/stream/large',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.SendFile(GStreamLarge, 'stream-large.bin', 'application/octet-stream');
    end
  );

  // ── multipart/form-data upload (Section I) ────────────────────────────────────
  // ICS decodes multipart via TFormDataAnalyser (OverbyteIcsFormDataDecoder) in
  // TICSRequestBridge.PopulateMultipartFields, populating Req.ContentFields exactly
  // like the CrossSocket / mORMot providers:
  //   text field → Req.ContentFields.Field(name).AsString
  //   file part  → Req.ContentFields.Field(name).AsStream
  THorse.Post('/upload',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LField1, LField2, LFileContent: string;
      LFileStream: TStream;
      LFileLen:    Int64;
      LBytes:      TBytes;
    begin
      LField1 := Req.ContentFields.Field('field1').AsString;
      LField2 := Req.ContentFields.Field('field2').AsString;

      LFileContent := '';
      LFileLen     := 0;
      LFileStream  := Req.ContentFields.Field('upload').AsStream;
      if Assigned(LFileStream) then
      begin
        LFileLen := LFileStream.Size;
        if LFileLen > 0 then
        begin
          LFileStream.Position := 0;
          SetLength(LBytes, LFileLen);
          LFileStream.ReadBuffer(LBytes[0], LFileLen);
          LFileContent := TEncoding.UTF8.GetString(LBytes);
        end;
      end;

      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"field1":"%s","field2":"%s","fileLen":%d,"fileContent":"%s"}',
           [JE(LField1), JE(LField2), LFileLen, JE(LFileContent)]));
    end
  );

  // ── RFC 6265 cookies (Section K — PATCH-COOKIE-1) ─────────────────────────────
  // Sets TWO cookies with attributes via the typed API.  The ICS response bridge
  // emits one Set-Cookie line per cookie (BuildHeaders → EmitHeader), so the
  // client must see two distinct Set-Cookie headers with correct attribute syntax.
  THorse.Get('/cookies',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Cookie('sid', 'abc123').Path('/').HttpOnly(True).SameSite(ssLax);
      Res.Cookie('theme', 'dark').MaxAge(3600);
      Res.ContentType('text/plain').Send('cookies-set');
    end
  );

  // ── Wildcard catch-all + SendFile (Section J — verifies PATCH-SENDFILE-1) ─────
  // Serves a file via SendFile and frees the stream in a finally — the exact
  // user-reported pattern.  PATCH-SENDFILE-1 makes SendFile copy the source at
  // call time, so freeing the caller's stream is harmless and the file is
  // delivered correctly (no AV/500).
  THorse.Get('/*',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LStream: TStringStream;
    begin
      try
        LStream := TStringStream.Create(WILDCARD_PAYLOAD);
        Res.SendFile(LStream, 'wildcard.bin', 'application/octet-stream').Status(200);
      finally
        try
          FreeAndNil(LStream);
        except on E: Exception do
        end;
      end;
    end
  );

end;

procedure FreeStreamFixtures;
begin
  FreeAndNil(GStreamSmall);
  FreeAndNil(GStreamLarge);
end;

// ── Ctrl+C handler (Windows only) ─────────────────────────────────────────────
// Routes Ctrl+C / window-close to THorseProviderICS.Stop so the worker pool and
// all context objects are freed before the leak report runs.
{$IFDEF MSWINDOWS}
function ConsoleCtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT:
      begin
        THorseProviderICS.Stop;
        Result := True;
      end;
  else
    Result := False;
  end;
end;
{$ENDIF}

// ── Entry point ────────────────────────────────────────────────────────────────

begin
{$IF NOT DEFINED(FPC)}
{$WARN SYMBOL_PLATFORM OFF}
  ReportMemoryLeaksOnShutdown := TRUE;
{$WARN SYMBOL_PLATFORM ON}
{$ENDIF}
{$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
{$ENDIF}
  try
    RegisterRoutes;
    Writeln(Format('[ICSParamTest] Starting on http://127.0.0.1:%d  [OverbyteICS]', [TEST_PORT]));
    Writeln('[ICSParamTest] Run HorseICSParamTestClient in a second terminal.');
    Writeln('[ICSParamTest] Press Ctrl+C to stop cleanly (leak report will follow).');
    THorseProviderICS.Listen(TEST_PORT);
    Writeln('[ICSParamTest] Server stopped.');
  except
    on E: Exception do
    begin
      Writeln('[ICSParamTest] Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
  // Free the stream fixtures after Listen returns (Stop has drained in-flight work).
  FreeStreamFixtures;
  Writeln('[ICSParamTest] CHECKPOINT: reached end. ReportMemoryLeaksOnShutdown=' +
    BoolToStr(ReportMemoryLeaksOnShutdown, True));
end.
