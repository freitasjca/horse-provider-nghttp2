program HorseNghttp2GrpcDemo;

// =============================================================================
//  HorseNghttp2GrpcDemo — end-to-end gRPC-over-HTTP/2 demo (M4b).
//
//  Boots a Horse instance on h2c port 18020, co-registers a plain HTTP route
//  and two gRPC methods:
//    /greeter.Greeter/Greet   — hello-world (TGreetRequest → TGreetResponse)
//    /greeter.Greeter/Echo    — all scalar types round-trip
//
//  Port choice: 18020 avoids the 9000-9100 range that OEM audio services
//  (NahimicService et al.) silently squat on Windows loopback — see the
//  `reference_nahimic_port_squat.md` memory. Windows loopback prefers
//  specific interface binds over wildcard, so a Nahimic listener on
//  127.0.0.1:9020 shadows a wildcard bind on 0.0.0.0:9020.
//
//  Test with:
//    HorseNghttp2GrpcTestClient.exe          — Delphi-native suite
//    grpcurl -plaintext -proto greeter.proto -d "{\"name\":\"World\"}" ^
//            localhost:18020 greeter.Greeter/Greet
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
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Horse,
  Horse.Provider.Nghttp2,
  Horse.Provider.Nghttp2.Grpc.Registry,
  Sample.Greeter.Messages,
  Sample.Greeter.Service;

const
  DEMO_PORT = 18020;

procedure GetIndex(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('text/plain; charset=utf-8')
     .Send('HorseNghttp2GrpcDemo up. gRPC methods registered on /greeter.Greeter/*'#10);
end;

begin
  try
    // Register gRPC methods BEFORE Listen so the dispatcher sees them on
    // the very first request. Registry is thread-safe so late registration
    // would work too, but early is the well-behaved pattern.
    THorseGrpc.RegisterMethod(
      '/greeter.Greeter/Greet',
      TGreetRequest, TGreetResponse,
      GreeterService.Greet);

    THorseGrpc.RegisterMethod(
      '/greeter.Greeter/Echo',
      TEchoRequest, TEchoResponse,
      GreeterService.Echo);

    // Regular HTTP route — proves non-gRPC traffic still routes normally.
    THorse.Get('/', GetIndex);

    WriteLn('HorseNghttp2GrpcDemo — h2c on port ', DEMO_PORT);
    WriteLn('Registered gRPC methods: ', THorseGrpc.Count);
    WriteLn('Try:');
    WriteLn('  HorseNghttp2GrpcTestClient.exe');
    WriteLn('  grpcurl -plaintext -proto greeter.proto -d "{\"name\":\"World\"}" ^');
    WriteLn('          localhost:', DEMO_PORT, ' greeter.Greeter/Greet');
    WriteLn('Ctrl-C to stop.');

    THorse.Listen(DEMO_PORT);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, '[FATAL] ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
