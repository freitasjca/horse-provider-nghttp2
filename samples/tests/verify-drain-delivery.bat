@echo off
setlocal enabledelayedexpansion
rem ============================================================================
rem  verify-drain-delivery.bat — the Windows half of the drain gate.
rem
rem  verify-drain-delivery.sh drives its cases with `nghttp`, which the Windows
rem  nghttp2 distribution does not ship (getting-nghttp2-windows.md sources the
rem  DLL from a curl build carrying curl.exe, not the nghttp2 CLI tools). That
rem  is the only reason the IOCP engine went unvalidated: no client, not a
rem  suspect server.
rem
rem  This runs the same three shapes through HorseNghttp2DrainCheck.exe, which
rem  speaks HTTP/2 via Delphi-nghttp2 itself. No WSL, no cross-boundary
rem  networking — which also sidesteps the WSL2 mirrored-networking RST race
rem  that fails cases A and C ~100%% of the time and cost this project two days.
rem
rem  Each case gets its OWN server: the drain fires once and the process exits.
rem
rem  Usage:
rem    verify-drain-delivery.bat [thread^|eventloop]
rem
rem  `eventloop` selects IOCP on Windows — the configuration this exists for.
rem ============================================================================

set ENGINE=%~1
if "%ENGINE%"=="" set ENGINE=thread

if /I "%ENGINE%"=="thread" (
    set SERVER_ARGS=
) else if /I "%ENGINE%"=="eventloop" (
    set SERVER_ARGS=eventloop
) else if /I "%ENGINE%"=="iocp" (
    set SERVER_ARGS=eventloop
) else (
    echo engine must be thread, eventloop, or iocp
    exit /b 2
)

set PORT=9010
set SLOW_MS=3000

rem The trigger is measured from SERVER START, so it must outlast everything
rem before the first byte of the request: server startup, bind, this script's
rem poll interval, the driver's startup and its connect.
rem
rem It was briefly lowered to 1000 to match the bash gate. That was WRONG and
rem the server log said so: '[shutdown] in flight at trigger: 0' - the drain
rem fired before the request arrived, so the run measured an EMPTY drain and
rem reported it as lost responses. The bash gate can use 1000 because it polls
rem every 50ms; :wait_for_bind polls with `ping`, whose floor is ~1s, and that
rem second comes out of the margin.
set TRIGGER_MS=3000
set TIMEOUT_MS=20000

set SERVER=HorseNghttp2TestServer.exe
set DRIVER=HorseNghttp2DrainCheck.exe

if not exist "%SERVER%" ( echo missing %SERVER% — build it first & exit /b 2 )
if not exist "%DRIVER%" ( echo missing %DRIVER% — build it first & exit /b 2 )

rem libnghttp2 is dynamically loaded by BOTH programs, so a missing DLL surfaces
rem as "0/N delivered" — which reads as a server that dropped every response.
rem Check it up front and say so, rather than letting the run implicate the
rem thing it is meant to be testing.
if not exist "nghttp2.dll" (
    where nghttp2.dll >nul 2>&1
    if errorlevel 1 (
        echo.
        echo nghttp2.dll not found next to the .exe files, nor on PATH.
        echo Both the server and the drain client load it at run time.
        echo See Delphi-nghttp2/doc/getting-nghttp2-windows.md.
        exit /b 2
    )
)

echo verify-drain-delivery ^(Windows^) — engine=%ENGINE%
echo   route /slow/%SLOW_MS% . trigger %TRIGGER_MS%ms . timeout %TIMEOUT_MS%ms
echo   every request is in flight when the drain starts
echo.

set PASSES=0
set FAILURES=0
set VOIDS=0

rem One CALL per case: a label cannot be reached from inside a `for ... do ( )`
rem block, and this needs three of them. Same structure run-tests.bat uses.
for %%C in (A B C) do call :run_case %%C

echo ----------------------------------------------------------------
echo !PASSES! passed, !FAILURES! failed, !VOIDS! void
rem A VOID case did not own its port, so it measured nothing. It is neither a
rem pass nor a failure of the product - but the run is not green either.
if not !VOIDS!==0 goto :voided
if !FAILURES!==0 goto :all_ok
echo Check server-A.log / server-B.log / server-C.log - each now carries its
echo [driver] RESOLVED line, because the server is allowed to exit on its own.
exit /b 1

:voided
echo !VOIDS! case(s) VOID: the port was held by another process, so those
echo cases proved nothing about the drain. Clear port %PORT% and re-run.
exit /b 2

:all_ok
echo All shapes delivered. The framework contract holds on %ENGINE%.
exit /b 0

rem ==========================================================================
rem  Subroutines. Everything below runs only via CALL - the exits above stop
rem  execution falling into them.
rem ==========================================================================

:run_case
set "CASE=%~1"
rem The port must be OURS before this case means anything. Windows
rem SO_REUSEADDR lets a SECOND server bind a port a first one already holds
rem (Nghttp2.Socket.pas: 'Windows has no SO_REUSEPORT; SO_REUSEADDR there
rem already permits the rebind'), and CreateListenerSocket does no post-bind
rem ownership check. So a stale server from an earlier run does not cause a
rem bind ERROR - the new server starts, prints its banner, and quietly serves
rem nothing while the driver's connections land on the stale one.
rem
rem That is exactly what happened on 2026-09-17: three runs reported
rem '0/3 in-flight responses lost' while the fresh server logged
rem 'in flight at trigger: 0' - it never saw a single request.
rem
rem The bash half has had freeport() since it was written. This did not.
call :ensure_port_free
if errorlevel 1 goto :run_case_void
rem Delete first: a stale log from a previous run would be read by
rem :assert_driver and reported as this run's evidence.
del /q "server-!CASE!.log" > nul 2>&1
rem Timestamps, because 'the harness is too slow' has been asserted twice
rem without being measured. The gap between these two lines IS the detection
rem latency that the trigger budget has to absorb.
echo     harness: server start  %TIME%
start "" /b %SERVER% %SERVER_ARGS% shutdown-after=%TRIGGER_MS% shutdown-timeout=%TIMEOUT_MS% > "server-!CASE!.log" 2>&1

call :wait_for_bind
if errorlevel 1 goto :run_case_nobind
echo     harness: bound        %TIME%

echo     harness: driver start %TIME%
%DRIVER% case=!CASE! port=%PORT% slowms=%SLOW_MS%
echo     harness: driver done  %TIME%
if errorlevel 1 goto :run_case_failed
set /a PASSES+=1
goto :run_case_after

:run_case_failed
set /a FAILURES+=1

:run_case_after
rem THE FIX THAT MATTERS. The old code ran `taskkill /IM ... /F` here, which
rem killed the server mid-drain. Two consequences, both of which destroyed the
rem evidence needed to diagnose a failure:
rem   1. The server joins its trigger thread to print a verdict and set its
rem      exit code (HorseNghttp2TestServer.dpr, 'Join before exiting or the
rem      process can race past its own result'). /F denies it that.
rem   2. Windows block-buffers a redirected stdout. Killed, the buffer dies
rem      unflushed - every server-*.log truncated at exactly 896 bytes, mid-word
rem      in '[driver] RE', so the resolved-engine line was unreadable in the one
rem      artifact that names it.
rem The bash twin waits (finish_server: tail --pid, then wait). So does this.
call :wait_for_exit
call :assert_driver
echo.
goto :eof

:run_case_nobind
set /a FAILURES+=1
echo     harness: server never bound port %PORT% - case !CASE! proves nothing
call :wait_for_exit
echo.
goto :eof

:run_case_void
set /a VOIDS+=1
echo     VOID: port %PORT% is held by a process this case did not start.
echo           Windows lets a second bind succeed, so the run would have
echo           measured a server nobody was talking to. Not counted.
echo.
goto :eof

:ensure_port_free
rem Mirrors freeport() in verify-drain-delivery.sh: kill stragglers, then
rem confirm the port is actually free before claiming it.
netstat -an | findstr /C:":%PORT% " | findstr /I "LISTENING" > nul 2>&1
if errorlevel 1 exit /b 0
echo     harness: port %PORT% already held - clearing stale server(s)
taskkill /IM %SERVER% /F > nul 2>&1
set /a FREE_TRIES=0
:ensure_port_free_loop
ping -n 2 127.0.0.1 > nul
netstat -an | findstr /C:":%PORT% " | findstr /I "LISTENING" > nul 2>&1
if errorlevel 1 exit /b 0
set /a FREE_TRIES+=1
if !FREE_TRIES! GEQ 10 exit /b 1
goto :ensure_port_free_loop

:wait_for_bind
rem Poll for the listener rather than sleeping a fixed ~1s and hoping. The old
rem `ping -n 2` was a guess in both directions, and this script's own header
rem warned that too long is as wrong as too short.
set /a BIND_TRIES=0
:wait_for_bind_loop
netstat -an | findstr /C:":%PORT% " | findstr /I "LISTENING" > nul 2>&1
if not errorlevel 1 exit /b 0
set /a BIND_TRIES+=1
if !BIND_TRIES! GEQ 20 exit /b 1
ping -n 2 127.0.0.1 > nul
goto :wait_for_bind_loop

:wait_for_exit
rem Waits for the LISTENER to disappear, not for a process name.
rem
rem The previous version matched `tasklist` output against %SERVER% and never
rem matched: tasklist's table format truncates Image Name to 25 chars, and
rem HorseNghttp2TestServer.exe is 26. So it returned 'already gone' instantly,
rem every case, and the three servers ran CONCURRENTLY on one port - all three
rem logs flushed within the same second and :assert_driver read a file still
rem sitting in a buffer.
rem
rem That is the Windows twin of the trap this gate's bash half documents:
rem `pkill -x` fails there because Linux truncates comm to 15 chars and the
rem name is 22. Same defect, same gate, different OS.
rem
rem The port is the right thing to wait on anyway: it is what the next case
rem needs freed, and it cannot be truncated.
set /a EXIT_TRIES=0
set /a GONE_TRIES=0
:wait_for_exit_loop
netstat -an | findstr /C:":%PORT% " | findstr /I "LISTENING" > nul 2>&1
rem Port free is only HALF the wait -- fall through to the process check,
rem do not return here. Returning at this point is what left the log still
rem buffered and the engine unproven on an otherwise green 3/3 run.
if errorlevel 1 goto :wait_for_gone_loop
set /a EXIT_TRIES+=1
if !EXIT_TRIES! GEQ 30 goto :wait_for_exit_kill
ping -n 2 127.0.0.1 > nul
goto :wait_for_exit_loop
rem The port going quiet is NOT the process exiting. StopAcceptingNewConnections
rem closes the listener at the START of the drain, so the port frees ~200ms
rem before the process ends -- and the log is still in a buffer at that point.
rem Measured 2026-09-17: case B started 40ms after case A's driver returned,
rem while A's server was still draining, so :assert_driver read a half-written
rem file and reported the engine as UNKNOWN on a run that had just passed 3/3.
rem
rem /FO CSV is load-bearing: the default TABLE format truncates Image Name to
rem 25 chars and HorseNghttp2TestServer.exe is 26, which is what made the
rem first version of this wait return 'already gone' instantly.
:wait_for_gone_loop
tasklist /FO CSV /NH /FI "IMAGENAME eq %SERVER%" 2>nul | findstr /I /C:"%SERVER%" > nul 2>&1
if errorlevel 1 exit /b 0
set /a GONE_TRIES+=1
if !GONE_TRIES! GEQ 20 goto :wait_for_exit_kill
ping -n 2 127.0.0.1 > nul
goto :wait_for_gone_loop

:wait_for_exit_kill
echo     harness: port %PORT% still LISTENING ~30s after the case - the drain
echo              did NOT complete. Killing; treat server-!CASE!.log as partial.
taskkill /IM %SERVER% /F > nul 2>&1
ping -n 2 127.0.0.1 > nul
exit /b 0

:assert_driver
rem The engine is REQUESTED, not guaranteed: eventloop degrades silently to the
rem thread driver on a build without the engine linked. The bash gate asserts
rem this; the old .bat merely told the reader to go look, at a log it had just
rem truncated. A run that cannot name its own engine measured an unknown one.
findstr /C:"[driver] RESOLVED" "server-!CASE!.log" > nul 2>&1
if errorlevel 1 goto :assert_driver_missing
for /f "tokens=*" %%L in ('findstr /C:"[driver] RESOLVED" "server-!CASE!.log"') do echo     %%L
goto :eof
:assert_driver_missing
echo     harness: no [driver] RESOLVED line in server-!CASE!.log
echo              the engine that ran is UNKNOWN - do not read this as %ENGINE%
goto :eof
