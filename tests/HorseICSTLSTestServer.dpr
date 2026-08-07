program HorseICSTLSTestServer;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_ICS}

{
  Horse + OverbyteICS  —  TLS / mutual-TLS test server
  =====================================================
  Destination: horse-provider-ics/samples/tests/HorseICSTLSTestServer.dpr

  Delphi only (ICS is Delphi-only; Windows + POSIX/Linux). Requires the ICS
  Source/ path and the OpenSSL libraries that ship with ICS.

  Listens on HTTPS port 9111 using the shared fixture certs (tests/certs/),
  driving the ICS provider's TSslContext wiring (SslCertFile / SslPrivKeyFile /
  SslCAFile / SslVerifyPeer).

  Two modes, selected by the first command-line argument:

    (no arg)   one-way TLS  — server presents server.crt.
    mtls       mutual TLS   — server requires a client cert signed by ca.crt
                              (SslVerifyPeer ⇒ SSL_VERIFY_PEER | FAIL_IF_NO_PEER_CERT).

  Routes:
    GET  /ping   → 200 "pong"
    POST /echo   → 200, echoes the request body  (sent with Content-Length —
                   ICS rejects chunked request bodies, so the client must not
                   stream it)

  Pair with HorseICSTLSTestClient (same mode argument).
}

{$IFNDEF HORSE_PROVIDER_ICS}
  {$MESSAGE FATAL 'Set HORSE_PROVIDER_ICS in Project Options → Conditional defines'}
{$ENDIF}

uses
  System.SysUtils,
  System.StrUtils,                 // IfThen (string)
  Horse,
  Horse.Commons,
  Horse.Provider.ICS.Config,       // THorseICSConfig
  Horse.Provider.ICS;

const
  TLS_PORT = 9111;

function FindCertDir: string;
const
  CANDIDATES: array[0..3] of string = (
    'certs', '..\certs', 'tests\certs', '..\tests\certs');
var
  LBase, LCand: string;
  I: Integer;
begin
  LBase := ExtractFilePath(ParamStr(0));
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := LBase + CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'server.crt') then
      Exit(LCand);
  end;
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'server.crt') then
      Exit(LCand);
  end;
  raise Exception.Create(
    'Could not locate certs\server.crt — copy tests\certs next to the binary.');
end;

procedure RegisterRoutes;
begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong').Status(THTTPStatus.OK);
    end);

  THorse.Post('/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send(Req.Body).Status(THTTPStatus.OK);
    end);
end;

var
  Config:  THorseICSConfig;
  CertDir: string;
  MTLS:    Boolean;
begin
  try
    MTLS    := SameText(ParamStr(1), 'mtls');
    CertDir := FindCertDir;

    Config                := THorseICSConfig.Default;
    Config.SSLEnabled     := True;
    Config.SSLCertFile    := CertDir + 'server.crt';
    Config.SSLPrivKeyFile := CertDir + 'server.key';

    if MTLS then
    begin
      Config.SSLCAFile     := CertDir + 'ca.crt';
      Config.SSLVerifyPeer := True;
    end;

    RegisterRoutes;

    Writeln(Format('[ICSTLSTest] certs: %s', [CertDir]));
    Writeln(Format('[ICSTLSTest] mode : %s',
      [IfThen(MTLS, 'mutual TLS (client cert required)', 'one-way TLS')]));
    Writeln(Format('[ICSTLSTest] Listening on https://127.0.0.1:%d  [OverbyteICS]', [TLS_PORT]));
    Writeln('[ICSTLSTest] Run HorseICSTLSTestClient'
      + IfThen(MTLS, ' mtls', '') + ' in a second terminal. Ctrl+C to stop.');

    THorseProviderICS.ListenWithConfig(TLS_PORT, Config);
    Writeln('[ICSTLSTest] Server stopped.');
  except
    on E: Exception do
    begin
      Writeln('[ICSTLSTest] Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
