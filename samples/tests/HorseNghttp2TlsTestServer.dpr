program HorseNghttp2TlsTestServer;

// ============================================================================
//  TLS smoke-test server for horse-provider-nghttp2 (h2 over TLS with ALPN).
//
//  Same code shape as HorseNghttp2TestServer.dpr but bound to port 9443 with
//  TLS enabled. A minimal set of routes proves the TLS + ALPN + HTTP/2
//  stack works end-to-end — full-suite parity with the h2c test server
//  isn't the goal here (Phase 1 client-side TLS + a native TLS test client
//  land in v1.1).
//
//  Prerequisites:
//    1. libnghttp2 v1.40+ on the runtime DLL path (nghttp2.dll etc.)
//    2. OpenSSL 3.x or 1.1.x on the runtime DLL path (libssl-*, libcrypto-*)
//    3. Self-signed cert generated:  ./gen-tls-cert.sh
//       Expected files (relative to the .exe):  tls/cert.pem  tls/key.pem
//
//  Build (Windows, Delphi):
//    dcc32 -CC -B HorseNghttp2TlsTestServer.dpr        (or dcc64)
//
//  Run:
//    ./HorseNghttp2TlsTestServer      (starts on :9443, blocks until Ctrl-C)
//
//  Test:
//    curl --http2 --insecure https://127.0.0.1:9443/ping
//        → HTTP/2 200 + body 'pong'
//    curl --http2 --insecure -v https://127.0.0.1:9443/ping 2>&1 | grep -i 'alpn\|http/2'
//        → confirms ALPN negotiated h2 and connection speaks HTTP/2
// ============================================================================

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_NGHTTP2}

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}

uses
  {$IF DEFINED(FPC)}
  SysUtils,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  {$IFEND }
  Horse,
  Horse.Commons,
  Horse.Exception,
  Horse.Provider.Nghttp2,
  Horse.Provider.Config,
  Nghttp2.Native in '..\..\..\Delphi-nghttp2\src\Nghttp2.Native.pas',
  Nghttp2.OpenSSL in '..\..\..\Delphi-nghttp2\src\Nghttp2.OpenSSL.pas',
  Nghttp2.Server in '..\..\..\Delphi-nghttp2\src\Nghttp2.Server.pas',
  Nghttp2.Session in '..\..\..\Delphi-nghttp2\src\Nghttp2.Session.pas',
  Nghttp2.Socket in '..\..\..\Delphi-nghttp2\src\Nghttp2.Socket.pas',
  Nghttp2.Tls in '..\..\..\Delphi-nghttp2\src\Nghttp2.Tls.pas',
  Nghttp2.Types in '..\..\..\Delphi-nghttp2\src\Nghttp2.Types.pas';

{ for THorseCrossSocketConfig with SSL* fields }

const
  TEST_PORT      = 9443;
  CERT_REL_PATH  = 'tls' + PathDelim + 'cert.pem';
  KEY_REL_PATH   = 'tls' + PathDelim + 'key.pem';

// ─── Route handlers (minimal set — proves TLS + h2 end-to-end) ─────────────

procedure GetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('pong');
end;

procedure GetMethodsGet(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"method":"GET","transport":"h2","tls":true}');
end;

procedure PostEcho(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"POST","bodyLength":%d}', [Length(Req.Body)]));
end;

procedure GetInfo(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"server":"HorseNghttp2TlsTestServer","port":' + IntToStr(TEST_PORT) +
           ',"transport":"h2 over TLS","alpn":"h2 (server accepts h2 only)"}');
end;

// ─── Main ─────────────────────────────────────────────────────────────────

var
  LCfg:      THorseCrossSocketConfig;
  LExeDir:   string;
  LCertPath: string;
  LKeyPath:  string;

begin
  try
    LExeDir   := ExtractFilePath(ParamStr(0));
    LCertPath := LExeDir + CERT_REL_PATH;
    LKeyPath  := LExeDir + KEY_REL_PATH;

    if not FileExists(LCertPath) then
    begin
      WriteLn(ErrOutput, 'ERROR: cert file not found: ', LCertPath);
      WriteLn(ErrOutput, 'Run ./gen-tls-cert.sh first (see samples/tests/).');
      ExitCode := 2;
      Exit;
    end;

    if not FileExists(LKeyPath) then
    begin
      WriteLn(ErrOutput, 'ERROR: key file not found: ', LKeyPath);
      WriteLn(ErrOutput, 'Run ./gen-tls-cert.sh first (see samples/tests/).');
      ExitCode := 2;
      Exit;
    end;

    WriteLn('HorseNghttp2TlsTestServer — h2 over TLS on port ', TEST_PORT);
    WriteLn('Cert: ', LCertPath);
    WriteLn('Key:  ', LKeyPath);
    WriteLn('Test: curl --http2 --insecure https://127.0.0.1:', TEST_PORT, '/ping');
    WriteLn('      curl --http2 --insecure https://127.0.0.1:', TEST_PORT, '/info');
    WriteLn('Ctrl-C to stop.');
    WriteLn;

    // Routes ---------------------------------------------------------------
    THorse.Get ('/ping',        GetPing);
    THorse.Get ('/methods/get', GetMethodsGet);
    THorse.Post('/echo',        PostEcho);
    THorse.Get ('/info',        GetInfo);

    // TLS configuration via Horse's standard cross-provider config record.
    // The nghttp2 provider reads SSLEnabled + SSLCertFile + SSLKeyFile in
    // ListenWithConfig, builds a TTlsServerContext, attaches to the server.
    LCfg              := THorseCrossSocketConfig.Default;
    LCfg.SSLEnabled   := True;
    LCfg.SSLCertFile  := LCertPath;
    LCfg.SSLKeyFile   := LKeyPath;
    // Password-protected keys are v1.1 (needs SSL_CTX_set_default_passwd_cb).
    // mTLS (SSLCACertFile + SSLVerifyPeer) is v1.1 too.

    THorse.ListenWithConfig(TEST_PORT, LCfg);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'FATAL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
