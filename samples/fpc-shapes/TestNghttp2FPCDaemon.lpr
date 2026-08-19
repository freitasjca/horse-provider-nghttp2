program TestNghttp2FPCDaemon;

{
  Compile + runtime smoke test for Horse.Provider.Nghttp2.FPC.Daemon.
  Proves:
    - Unit compiles on FPC trunk 3.3.1
    - THorseNghttp2FPCDaemonApp.Run wires signal handlers and blocks on Listen
    - SIGTERM causes a clean exit (exit code 0)

  Run:
    ./TestNghttp2FPCDaemon &
    SERVER_PID=$!
    sleep 0.3
    curl --http2-prior-knowledge http://localhost:9210/ping   # expects: pong
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
  Horse.Provider.Nghttp2.FPC.Daemon;

procedure GetPing(Req: THorseRequest; Res: THorseResponse; Next: TNextProc);
begin
  Res.Send('pong');
end;

procedure SetupRoutes;
begin
  THorse.Get('/ping', GetPing);
end;

begin
  WriteLn('TestNghttp2FPCDaemon - h2c on port 9210');
  WriteLn('  curl --http2-prior-knowledge http://localhost:9210/ping');
  WriteLn('  kill -TERM <pid> to stop');
  THorseNghttp2FPCDaemonApp.Run(@SetupRoutes, 9210);
  WriteLn('Stopped cleanly.');
end.
