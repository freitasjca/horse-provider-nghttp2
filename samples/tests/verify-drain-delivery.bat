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

rem The trigger is measured from SERVER START, so it must outlast this script's
rem wait-for-bind plus the driver's connect — otherwise the drain fires with
rem nothing in flight, the server exits, and the driver reports a connect
rem failure that looks like a lost response. The bash gate can use 1000ms
rem because it polls for the port; `ping` as a sleep is coarser, so allow more.
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

for %%C in (A B C) do (
    rem A fresh server per case. `start ""` returns immediately; the server
    rem self-terminates when its drain completes, so there is nothing to kill
    rem on the happy path.
    start "" /b %SERVER% %SERVER_ARGS% shutdown-after=%TRIGGER_MS% shutdown-timeout=%TIMEOUT_MS% > server-%%C.log 2>&1

    rem ~1s: long enough to bind, short enough to leave the requests in flight
    rem when TRIGGER_MS fires. Both bounds matter — too long is as wrong as too
    rem short, and fails in a way that implicates the server rather than the
    rem timing.
    ping -n 2 127.0.0.1 > nul

    %DRIVER% case=%%C port=%PORT% slowms=%SLOW_MS%
    if errorlevel 1 ( set /a FAILURES+=1 ) else ( set /a PASSES+=1 )

    rem Belt and braces: if the drain did not fire, do not leave a server
    rem holding the port for the next case.
    taskkill /IM %SERVER% /F > nul 2>&1
    ping -n 2 127.0.0.1 > nul
    echo.
)

echo ----------------------------------------------------------------
echo %PASSES% passed, %FAILURES% failed
if %FAILURES%==0 (
    echo All shapes delivered. The framework contract holds on %ENGINE%.
    exit /b 0
)
echo Check server-A.log / server-B.log / server-C.log — the resolved driver
echo line tells you whether the engine you asked for is the one that ran.
exit /b 1
