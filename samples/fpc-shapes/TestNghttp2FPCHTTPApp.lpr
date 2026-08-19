program TestNghttp2FPCHTTPApp;

{
  Compile + runtime smoke test for Horse.Provider.Nghttp2.FPC.HTTPApplication.
  Proves:
    - Unit compiles on FPC trunk 3.3.1
    - THorseNghttp2FPCHTTPApp.Run type-aliases and delegates correctly to the
      Daemon helper (same signal-handler + blocking-Listen lifecycle)

  NOTE: Do NOT call Application.Run — nghttp2 owns the loop, not fphttpapp.

  Run:
    ./TestNghttp2FPCHTTPApp &
    SERVER_PID=$!
    sleep 0.3
    curl --http2-prior-knowledge http://localhost:9211/ping   # expects: pong
    kill -TERM $SERVER_PID
    wait $SERVER_PID && echo "PASS exit 0" || echo "FAIL exit $?"
}

{$IF DEFINED(FPC) AND DEFINED(UNIX)}
uses
  cthreads,
{$ELSE}
uses
{$ENDIF}
  SysUtils,
  Horse,
  Horse.Provider.Nghttp2.FPC.HTTPApplication;

procedure GetPing(Req: THorseRequest; Res: THorseResponse; Next: TNextProc);
begin
  Res.Send('pong');
end;

procedure SetupRoutes;
begin
  THorse.Get('/ping', GetPing);
end;

begin
  WriteLn('TestNghttp2FPCHTTPApp - h2c on port 9211');
  WriteLn('  curl --http2-prior-knowledge http://localhost:9211/ping');
  WriteLn('  kill -TERM <pid> to stop');
  THorseNghttp2FPCHTTPApp.Run(@SetupRoutes, 9211);
  WriteLn('Stopped cleanly.');
end.
