program HorseNghttp2GrpcDemo;

// =============================================================================
//  HorseNghttp2GrpcDemo — end-to-end gRPC-over-HTTP/2 demo (M4b + M4c + M5).
//
//  Boots a Horse instance and registers a plain HTTP route plus two gRPC
//  methods (via M4c one-line RegisterService<IGreeter>):
//    /greeter.Greeter/Greet   — hello-world (TGreetRequest → TGreetResponse)
//    /greeter.Greeter/Echo    — all scalar types round-trip
//
//  Modes (selected via first CLI arg):
//    HorseNghttp2GrpcDemo            — h2c on port 18020 (default)
//    HorseNghttp2GrpcDemo tls        — h2 over TLS on port 18443
//    HorseNghttp2GrpcDemo mtls       — TLS + require client cert (mTLS)
//
//  TLS/mTLS modes need cert files in ./tls/ next to the executable:
//    tls/cert.pem, tls/key.pem                        (TLS)
//    tls/ca.pem  (additionally, for mTLS)
//  Generate with samples/grpc/gen-tls-cert.sh (or reuse the fixtures from
//  samples/tests/tls/ — same self-signed CA, same key/cert layout).
//
//  Port choice: 18020 / 18443 both avoid the 9000-9100 range that OEM audio
//  services (NahimicService et al.) silently squat on Windows loopback — see
//  `reference_nahimic_port_squat.md` memory.
//
//  Test with:
//    HorseNghttp2GrpcTestClient.exe                                — h2c local
//    HorseNghttp2GrpcTestClient.exe http://<linux-host>:18020      — h2c cross-machine
//    HorseNghttp2GrpcTestClient.exe https://127.0.0.1:18443        — TLS local
//    grpcurl -plaintext -proto greeter.proto -d '{"name":"World"}' \
//            localhost:18020 greeter.Greeter/Greet                 — h2c interop
//    grpcurl -insecure  -proto greeter.proto -d '{"name":"World"}' \
//            localhost:18443 greeter.Greeter/Greet                 — TLS interop
//
//  A non-gRPC path (/) is served by a normal Horse handler — proves the
//  dispatcher's content-type gate cleanly falls through for regular HTTP.
// =============================================================================

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_NGHTTP2}

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}

uses
{$IF DEFINED(FPC)}
  {$IF DEFINED(UNIX)}
  cthreads,   { MUST be the first unit on FPC/Unix — installs the pthreads
                threading driver before any other unit's initialization can
                touch TThread. Listing it later gives "This binary has no
                threading support compiled in" at run time. }
  {$IFEND}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Horse,
  Horse.Provider.Nghttp2,
  Nghttp2.Grpc.Registry,
  Horse.Provider.Config,                     { THorseCrossSocketConfig with SSL* fields (TLS/mTLS modes) }
  Sample.Greeter.Interfaces,                 { M4c: IGreeter interface + [TGrpcService] }
  Sample.Greeter.Messages,
  Sample.Greeter.Service;

const
  DEMO_PORT_H2C = 18020;   // cleartext HTTP/2 (h2c prior knowledge)
  DEMO_PORT_TLS = 18443;   // HTTP/2 over TLS (h2 with ALPN)
  CERT_REL_PATH = 'tls' + PathDelim + 'cert.pem';
  KEY_REL_PATH  = 'tls' + PathDelim + 'key.pem';
  CA_REL_PATH   = 'tls' + PathDelim + 'ca.pem';   // mTLS mode only

procedure GetIndex(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('text/plain; charset=utf-8')
     .Send('HorseNghttp2GrpcDemo up. gRPC methods registered on /greeter.Greeter/*'#10);
end;

var
  LUseTls, LUseMTls: Boolean;
  LExeDir, LCertPath, LKeyPath, LCaPath: string;
  LPort: Integer;
  LCfg:  THorseCrossSocketConfig;
  I:     Integer;
  LGreeter: IGreeter;
begin
  try
    LUseTls  := False;
    LUseMTls := False;
    for I := 1 to ParamCount do
    begin
      if SameText(ParamStr(I), 'tls')  then LUseTls  := True;
      if SameText(ParamStr(I), 'mtls') then begin LUseTls := True; LUseMTls := True; end;
    end;

    { Register the whole IGreeter service in one call — M4c ergonomic API.
      RegisterService<T> walks IGreeter via RTTI, reads [TGrpcService('greeter.Greeter')]
      for the path prefix, extracts request/response classes from each method's
      signature, and registers /greeter.Greeter/Greet + /greeter.Greeter/Echo.
      Wire behaviour is identical to the two-call M4a form below (commented). }
    LGreeter := TGreeterServiceImpl.Create;
    THorseGrpc.RegisterService<IGreeter>(LGreeter);

    { M4a procedural equivalent (kept in a comment for reference):
        THorseGrpc.RegisterMethod('/greeter.Greeter/Greet',
          TGreetRequest, TGreetResponse, GreeterService.Greet);
        THorseGrpc.RegisterMethod('/greeter.Greeter/Echo',
          TEchoRequest, TEchoResponse, GreeterService.Echo);
    }

    { M6a — server-streaming. Registered explicitly rather than through
      RegisterService<T>: a streaming RPC returns a sequence, not a value, so
      it has no natural IInvokable shape to reflect over. AResponseClass is the
      type of EACH streamed message. }
    THorseGrpc.RegisterServerStream('/greeter.Greeter/ListGreetings',
      TGreetRequest, TGreetResponse, GreeterService.ListGreetings);

    { M6b — the two inbound-streaming shapes. Registering either makes the
      transport dispatch that path on HEADERS instead of END_STREAM, so the
      handler runs while the peer is still sending. }
    THorseGrpc.RegisterClientStream('/greeter.Greeter/JoinNames',
      TGreetRequest, TGreetResponse, GreeterService.JoinNames);
    THorseGrpc.RegisterBidiStream('/greeter.Greeter/ChatGreetings',
      TGreetRequest, TGreetResponse, GreeterService.ChatGreetings);

    // Regular HTTP route — proves non-gRPC traffic still routes normally.
    THorse.Get('/', GetIndex);

    if LUseTls then
    begin
      LPort     := DEMO_PORT_TLS;
      LExeDir   := ExtractFilePath(ParamStr(0));
      LCertPath := LExeDir + CERT_REL_PATH;
      LKeyPath  := LExeDir + KEY_REL_PATH;
      LCaPath   := LExeDir + CA_REL_PATH;

      if not FileExists(LCertPath) then
        raise Exception.CreateFmt(
          'TLS mode: cert file not found: %s (run gen-tls-cert.sh first)', [LCertPath]);
      if not FileExists(LKeyPath) then
        raise Exception.CreateFmt(
          'TLS mode: key file not found: %s (run gen-tls-cert.sh first)', [LKeyPath]);
      if LUseMTls and not FileExists(LCaPath) then
        raise Exception.CreateFmt(
          'mTLS mode: CA file not found: %s (run gen-tls-cert.sh first)', [LCaPath]);
    end
    else
      LPort := DEMO_PORT_H2C;

    if LUseTls then
    begin
      if LUseMTls then
        WriteLn('HorseNghttp2GrpcDemo — h2 over TLS + client cert required (mTLS) on port ', LPort)
      else
        WriteLn('HorseNghttp2GrpcDemo — h2 over TLS on port ', LPort);
      WriteLn('  cert:  ', LCertPath);
      WriteLn('  key:   ', LKeyPath);
      if LUseMTls then
        WriteLn('  CA:    ', LCaPath);
    end
    else
      WriteLn('HorseNghttp2GrpcDemo — h2c on port ', LPort);
    WriteLn('Registered gRPC methods: ', THorseGrpc.Count);
    WriteLn('Try (local):');
    { grpcurl needs -import-path pointing at the SOURCE tree. The old hint
      printed `-proto greeter.proto` with no path, which cannot resolve: this
      binary is built into bin/<Platform>/<Config> while the .proto stays in
      samples/grpc. grpcurl then reports
        service "greeter.Greeter" does not include a method named "..."
      which reads as a server fault and is in fact a client-side schema
      mismatch — the server is never consulted about what it offers. }
    if LUseTls then
    begin
      WriteLn('  HorseNghttp2GrpcTestClient.exe https://127.0.0.1:', LPort);
      WriteLn('  grpcurl -insecure -import-path <repo>/horse-provider-nghttp2/samples/grpc \');
      WriteLn('          -proto greeter.proto -d ''{"name":"World"}'' localhost:',
              LPort, ' greeter.Greeter/Greet');
    end
    else
    begin
      WriteLn('  HorseNghttp2GrpcTestClient.exe');
      WriteLn('  grpcurl -plaintext -import-path <repo>/horse-provider-nghttp2/samples/grpc \');
      WriteLn('          -proto greeter.proto -d ''{"name":"World"}'' localhost:',
              LPort, ' greeter.Greeter/Greet');
      WriteLn('  ... same, ending greeter.Greeter/ListGreetings   (server-streaming, 5 msgs)');
    end;
    WriteLn('Ctrl-C to stop.');

    if LUseTls then
    begin
      // Pass cert+key via the shared cross-provider config record. The nghttp2
      // provider's ListenWithConfig reads SSLEnabled/SSLCertFile/SSLKeyFile
      // (and SSLCACertFile+SSLVerifyPeer for mTLS), builds a TTlsServerContext,
      // attaches it to the server. ALPN negotiation ensures h2 selection.
      LCfg             := THorseCrossSocketConfig.Default;
      LCfg.SSLEnabled  := True;
      LCfg.SSLCertFile := LCertPath;
      LCfg.SSLKeyFile  := LKeyPath;
      if LUseMTls then
      begin
        LCfg.SSLCACertFile := LCaPath;
        LCfg.SSLVerifyPeer := True;
      end;
      THorse.ListenWithConfig(LPort, LCfg);
    end
    else
      THorse.Listen(LPort);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, '[FATAL] ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
