@echo off
REM ============================================================================
REM  run-tests.bat - the Windows harness that RUNS the suite.
REM
REM  -- Why this exists --
REM
REM  Every Windows script in this repo built and stopped. scripts\build-dcc.bat
REM  compiles the five test executables; scripts\build-msbuild.bat does the same
REM  through MSBuild; samples\tests\build-linux64.bat cross-compiles. None of
REM  them ran anything. So the live behaviour of this provider on Windows -- TLS,
REM  mTLS, gRPC, and the IOCP engine's graceful drain -- was covered by nothing
REM  at all, while build-fpc.sh covered all of it on Linux and FPC.
REM
REM  That is not a small asymmetry. IOCP is the Windows engine. It has no Linux
REM  counterpart, so "green on Linux" says nothing about it, and its drain is the
REM  one driver of three whose shutdown path nothing exercised.
REM
REM  -- What was already here --
REM
REM  Most of the machinery, unjoined. verify-drain-delivery.bat already accepts
REM  engine=thread^|eventloop^|iocp and drives HorseNghttp2DrainCheck.exe, which
REM  speaks HTTP/2 through Delphi-nghttp2 itself rather than needing nghttp. It
REM  simply had no caller -- and build-dcc.bat did not build the .exe it needs,
REM  so running it by hand failed on a missing file.
REM
REM  -- Tooling, and why the stage list is shorter than the Linux one --
REM
REM  h2load and nghttp do not ship on Windows: getting-nghttp2-windows.md sources
REM  nghttp2.dll from a curl build, which carries curl.exe and not the nghttp2
REM  CLI tools. Every stage below therefore uses our own binaries. The streaming
REM  and WS-8441 stages are NOT ported yet -- they need curl -N timing and a
REM  Python with h2 -- and this script says so out loud rather than leaving the
REM  reader to infer coverage from silence.
REM
REM  Exit codes:  0 = all gating stages passed   1 = a stage failed
REM               2 = setup problem (no dcc64, port busy, build failed)
REM               3 = libnghttp2 absent, nothing was exercised
REM ============================================================================

setlocal enabledelayedexpansion

set "HERE=%~dp0"
set "ROOT=%HERE%..\.."
cd /d "%HERE%"

set /a PASSED=0
set /a FAILED=0
set /a SKIPPED=0

set "PORT=9010"
set "TLS_PORT=9443"
set "GRPC_PORT=18020"

REM Logs go in a RELATIVE directory beside the .exe files, not under %TEMP%.
REM Two reasons, both batch-specific: `start "" /B cmd /c "..."` cannot carry a
REM quoted redirect target without the nested quotes breaking the parse, and
REM %TEMP% contains a space whenever the account name does. A relative path with
REM no spaces needs no quoting at all.
set "LOGDIR=_winlogs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1

echo ===========================================================================
echo  horse-provider-nghttp2 - Windows live suite
echo  logs: %LOGDIR%
echo ===========================================================================

REM -- Preflight 1: the native library ----------------------------------------
REM
REM Checked FIRST and loudly. The Delphi-nghttp2 suite passed for years on a
REM machine with no nghttp2.dll on it, because nothing there needed one; the
REM contradiction only surfaced when a sample failed to run beside a green
REM suite. A silent skip here would rebuild exactly that trap.
set "DLL_OK="
if exist "nghttp2.dll" set "DLL_OK=1"
if not defined DLL_OK (
    where nghttp2.dll >nul 2>&1 && set "DLL_OK=1"
)
if not defined DLL_OK (
    echo.
    echo  ======================================================================
    echo   SKIPPED - nghttp2.dll was not found beside the .exe files nor on PATH.
    echo.
    echo   NOTHING in this suite ran. Every stage below loads the library at
    echo   run time, so this is not a partial result - it is no result.
    echo.
    echo   The bitness must match the compiler: dcc64 needs the Win64 DLL.
    echo   See Delphi-nghttp2\doc\getting-nghttp2-windows.md
    echo  ======================================================================
    exit /b 3
)

REM -- Preflight 2: nothing already on our ports -------------------------------
REM
REM An orphaned server from an interrupted run answers this run's traffic while
REM the server started here fails to bind. That reads as a server fault which it
REM is not, and it cost time on the Linux side before require_port_free existed.
for %%P in (%PORT% %TLS_PORT% %GRPC_PORT%) do (
    netstat -ano -p TCP | findstr /R /C:"LISTENING" | findstr /C:":%%P " >nul 2>&1
    if !ERRORLEVEL! EQU 0 (
        echo.
        echo ERROR: something is already listening on port %%P.
        echo        Usually an orphaned HorseNghttp2TestServer from an
        echo        interrupted run. Clear it with:
        echo            taskkill /F /IM HorseNghttp2TestServer.exe
        exit /b 2
    )
)

REM -- Build ------------------------------------------------------------------
echo.
echo -- building -------------------------------------------------------------
REM "all", not the default: build-dcc.bat defaults to TARGET=tests, which
REM builds the four HTTP programs and skips the gRPC pair entirely. The gRPC
REM stage would then SKIP on a missing .exe and the run would still look
REM complete.
call "%ROOT%\scripts\build-dcc.bat" all Release > "%LOGDIR%\build.log" 2>&1
if !ERRORLEVEL! NEQ 0 (
    echo   FAIL  build-dcc.bat returned !ERRORLEVEL!
    echo   ---- last 20 lines ----
    powershell -NoProfile -Command "Get-Content '%LOGDIR%\build.log' -Tail 20" 2>nul
    echo   full log: %HERE%%LOGDIR%\build.log
    exit /b 2
)
REM build-dcc.bat writes to <repo-parent>\bin\Win64\Release, which is outside
REM the repo. The TLS fixtures (tls\*.pem) and verify-drain-delivery.bat both
REM live HERE and both use relative paths, so the binaries are staged beside
REM them rather than the other way round. That is also why the pre-existing
REM drain script only ever worked after an IDE build: it assumes cwd.
for %%I in ("%ROOT%\..") do set "OUTROOT=%%~fI"
set "EXEDIR=!OUTROOT!\bin\Win64\Release"
if not exist "!EXEDIR!" (
    echo   FAIL  build output directory does not exist:
    echo           !EXEDIR!
    echo         build-dcc.bat returned 0 but produced nothing - read the log,
    echo         its early-exit paths ^(no dcc64, no horse, no Delphi-nghttp2^)
    echo         print a reason there.
    echo   full log: %HERE%%LOGDIR%\build.log
    exit /b 2
)
for %%E in (HorseNghttp2TestServer.exe HorseNghttp2TestClient.exe HorseNghttp2DrainCheck.exe HorseNghttp2GrpcDemo.exe HorseNghttp2GrpcTestClient.exe) do (
    if exist "!EXEDIR!\%%E" copy /Y "!EXEDIR!\%%E" "%%E" >nul 2>&1
)
for %%E in (HorseNghttp2TestServer.exe HorseNghttp2TestClient.exe HorseNghttp2DrainCheck.exe) do (
    if not exist "%%E" (
        echo   FAIL  %%E was not produced by the build
        echo         looked in !EXEDIR!
        echo         see %LOGDIR%\build.log
        exit /b 2
    )
)
echo   built and staged from !EXEDIR!

REM ===========================================================================
REM  Stages
REM ===========================================================================

REM -- 5. the 114-check suite, thread driver, h2c ------------------------------
call :run_suite "114-check suite (h2c, thread driver)" suite-h2c "" "http://127.0.0.1:%PORT%"

REM -- 6. graceful shutdown, THREAD driver -------------------------------------
REM Delegated to verify-drain-delivery.bat, which already drives the three
REM connection shapes through our own drain client. Exit 2 there means a missing
REM binary rather than a lost reply, so it is reported as a setup skip.
call :run_drain "graceful shutdown (thread driver)" thread

REM -- 6c. graceful shutdown, IOCP --------------------------------------------
REM THE stage this harness exists for. IOCP is Windows-only, so no Linux run can
REM reach it; before this, the drain path of the engine that serves every
REM Windows deployment was exercised by nothing.
call :run_drain "graceful shutdown (IOCP event loop)" iocp

REM -- 9. TLS ------------------------------------------------------------------
call :run_suite "114-check suite over TLS" suite-tls "tls" "https://127.0.0.1:%TLS_PORT%"

REM -- 10. mTLS, positive and negative -----------------------------------------
call :run_mtls

REM -- 10b. TLS 1.2 cipher rules on the wire (TLSCIPHER-1) ---------------------
REM openssl s_client is the independent peer, as in build-fpc.sh stage 10b.
REM Same order: a control first, then each refusal preceded by a positive on
REM the same server. The two startup cases need no openssl at all.
call :run_ciphers

REM -- 10c. TLS 1.3 suites + minimum TLS version on the wire (1.11.0) ----------
REM Same peer and order as 10b; see :run_suites13 below.
call :run_suites13

REM -- 11. gRPC over h2c -------------------------------------------------------
call :run_grpc

REM -- 12. the suite via the IOCP event loop -----------------------------------
call :run_suite "114-check suite via IOCP event loop" suite-iocp "eventloop" "http://127.0.0.1:%PORT%"

REM -- not ported ---------------------------------------------------------------
echo.
echo -- NOT PORTED from build-fpc.sh -----------------------------------------
echo   streaming timing + backpressure  (needs curl -N timing harness)
echo   WS-8441 upgrade                  (needs Python with the h2 package)
echo   These are covered on Linux/FPC only. Stated here rather than omitted,
echo   because a stage list that simply ends reads as full coverage.
set /a SKIPPED+=2

REM ===========================================================================
echo.
echo ===========================================================================
if %FAILED% GTR 0 (
    echo  %FAILED% STAGE^(S^) FAILED   ^(%PASSED% passed, %SKIPPED% skipped^)
    echo ===========================================================================
    exit /b 1
)
if %SKIPPED% GTR 0 (
    echo  ALL GATING STAGES PASSED  --  %PASSED% passed, %SKIPPED% SKIPPED
    echo  A skipped stage verified NOTHING. See the SKIP lines above.
    echo ===========================================================================
    exit /b 0
)
echo  ALL STAGES PASSED  ^(%PASSED%^)
echo ===========================================================================
exit /b 0

REM ===========================================================================
REM  Helpers
REM ===========================================================================

REM Every program below is given `< nul`. The test programs end with a
REM "Press ENTER to exit..." prompt, so without it each stage parks waiting for
REM a keystroke and the harness cannot run unattended. build-fpc.sh solves the
REM same problem with `< /dev/null`; `nul` is the Windows spelling.
REM
REM run_suite <label> <logname> <server-args> <target-url> [client args...]
:run_suite
set "RS_LABEL=%~1"
set "RS_LOG=%~2"
set "RS_SRVARGS=%~3"
set "RS_TARGET=%~4"
echo.
echo -- %RS_LABEL%
start "" /B cmd /c "HorseNghttp2TestServer.exe %RS_SRVARGS% < nul > %LOGDIR%\%RS_LOG%-server.log 2>&1"
call :wait_bind
HorseNghttp2TestClient.exe %RS_TARGET% < nul > "%LOGDIR%\%RS_LOG%-client.log" 2>&1
set "RS_RC=!ERRORLEVEL!"
call :stop_server
if "!RS_RC!"=="0" (
    call :pass "%RS_LABEL%"
) else (
    call :fail "%RS_LABEL%"
    powershell -NoProfile -Command "Get-Content '%LOGDIR%\%RS_LOG%-client.log' -Tail 6" 2>nul
)
findstr /C:"passed," "%LOGDIR%\%RS_LOG%-client.log" 2>nul
exit /b 0

REM run_drain <label> <engine>
:run_drain
echo.
echo -- %~1
call verify-drain-delivery.bat %~2 < nul > "%LOGDIR%\drain-%~2.log" 2>&1
set "RD_RC=!ERRORLEVEL!"
if "!RD_RC!"=="0" (
    findstr /R /C:"^  [ABC] " "%LOGDIR%\drain-%~2.log" 2>nul
    call :pass "%~1"
) else if "!RD_RC!"=="2" (
    call :skip "%~1 - setup incomplete (missing binary or DLL)"
    powershell -NoProfile -Command "Get-Content '%LOGDIR%\drain-%~2.log' -Tail 4" 2>nul
) else (
    findstr /R /C:"^  [ABC] " "%LOGDIR%\drain-%~2.log" 2>nul
    call :fail "%~1 - in-flight replies lost"
)
exit /b 0

REM mTLS: positive then negative. The negative case is the one that proves
REM enforcement -- a clean run there would mean the server is NOT enforcing.
:run_mtls
echo.
echo -- mTLS (positive + negative)
start "" /B cmd /c "HorseNghttp2TestServer.exe mtls < nul > %LOGDIR%\mtls-server.log 2>&1"
call :wait_bind
HorseNghttp2TestClient.exe https://127.0.0.1:%TLS_PORT% --client-cert tls\client-cert.pem --client-key tls\client-key.pem < nul > "%LOGDIR%\mtls-pos.log" 2>&1
if !ERRORLEVEL! EQU 0 ( call :pass "mTLS positive (client cert presented)" ) else ( call :fail "mTLS positive" )
findstr /C:"passed," "%LOGDIR%\mtls-pos.log" 2>nul
HorseNghttp2TestClient.exe https://127.0.0.1:%TLS_PORT% < nul > "%LOGDIR%\mtls-neg.log" 2>&1
if !ERRORLEVEL! EQU 0 (
    call :fail "mTLS negative - uncertified client was ACCEPTED"
) else (
    call :pass "mTLS negative - uncertified client refused"
)
call :stop_server
exit /b 0

:run_grpc
echo.
echo -- gRPC over h2c
if not exist "HorseNghttp2GrpcDemo.exe" (
    call :skip "gRPC - HorseNghttp2GrpcDemo.exe not built"
    exit /b 0
)
start "" /B cmd /c "HorseNghttp2GrpcDemo.exe < nul > %LOGDIR%\grpc-server.log 2>&1"
call :wait_bind
HorseNghttp2GrpcTestClient.exe < nul > "%LOGDIR%\grpc-client.log" 2>&1
if !ERRORLEVEL! EQU 0 ( call :pass "gRPC suite (h2c)" ) else ( call :fail "gRPC suite (h2c)" )
findstr /C:"passed," "%LOGDIR%\grpc-client.log" 2>nul
taskkill /F /IM HorseNghttp2GrpcDemo.exe >nul 2>&1
REM GRPC-ERRMSG-1: client test 07 proves the class name no longer reaches the
REM CLIENT; this proves it still reaches the SERVER log via OnHandlerError.
findstr /L /C:"[grpc-error] /greeter.Greeter/Fail EArgumentException: 100%% invalid" "%LOGDIR%\grpc-server.log" >nul 2>&1
if !ERRORLEVEL! EQU 0 ( call :pass "gRPC handler error: class name logged server-side - OnHandlerError" ) else ( call :fail "gRPC handler error: OnHandlerError did not log the class name" )
exit /b 0

REM Stage 10b. SSLCipherList was accepted and NEVER APPLIED until provider
REM 1.10.0 (TLSCIPHER-1), and SSLVerifyPeer without SSLCACertFile started a
REM server with NO client verification (FIX-NGHTTP2-VERIFYPEER-1). Judged by
REM s_client's EXIT CODE plus its "Cipher is" / "ALPN protocol" lines - never
REM by OpenSSL error text, which differs between 3.0 and 3.6.
REM
REM A startup refusal is checked on the PORT, not the process: tasklist
REM truncates image names past 25 characters, and HorseNghttp2TestServer.exe
REM is 26. A listener on the TLS port after the wait means the server started
REM with a configuration it should have refused.
:run_ciphers
echo.
echo -- TLS 1.2 cipher rules on the wire (openssl s_client peer)
set "C_ALLOW=ECDHE-RSA-AES256-GCM-SHA384"
set "C_DENY=ECDHE-RSA-AES128-GCM-SHA256"
set "OPENSSL="
for /f "delims=" %%I in ('where openssl.exe 2^>nul') do if not defined OPENSSL set "OPENSSL=%%I"
if not defined OPENSSL (
    call :skip "cipher rules on the wire - openssl.exe not on PATH; SSLCipherList NOT exercised"
    goto :rc_startup
)

REM A - control: the DEFAULT server accepts the client B2 must be refused.
start "" /B cmd /c "HorseNghttp2TestServer.exe tls < nul > %LOGDIR%\ciphers-a-server.log 2>&1"
call :wait_bind
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_2 -cipher !C_DENY! -alpn h2 < nul > "%LOGDIR%\ciphers-a.log" 2>&1
if !ERRORLEVEL! NEQ 0 goto :rc_a_fail
findstr /L /C:"Cipher is !C_DENY!" "%LOGDIR%\ciphers-a.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :rc_a_fail
call :pass "control: default server negotiates !C_DENY! over TLS 1.2"
goto :rc_a_done
:rc_a_fail
call :fail "control: default server did NOT accept a !C_DENY! client - B2 proves nothing"
:rc_a_done
call :stop_server

REM B - server restricted to C_ALLOW.
start "" /B cmd /c "HorseNghttp2TestServer.exe ciphers12=!C_ALLOW! < nul > %LOGDIR%\ciphers-b-server.log 2>&1"
call :wait_bind
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_2 -cipher !C_ALLOW! -alpn h2 < nul > "%LOGDIR%\ciphers-b1.log" 2>&1
if !ERRORLEVEL! NEQ 0 goto :rc_b1_fail
findstr /L /C:"Cipher is !C_ALLOW!" "%LOGDIR%\ciphers-b1.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :rc_b1_fail
findstr /L /C:"ALPN protocol: h2" "%LOGDIR%\ciphers-b1.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :rc_b1_fail
call :pass "configured cipher negotiated over TLS 1.2, ALPN h2"
goto :rc_b1_done
:rc_b1_fail
call :fail "configured cipher !C_ALLOW! was NOT negotiated - see %LOGDIR%\ciphers-b1.log"
:rc_b1_done
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_2 -cipher !C_DENY! -alpn h2 < nul > "%LOGDIR%\ciphers-b2.log" 2>&1
if !ERRORLEVEL! EQU 0 (
    call :fail "excluded cipher !C_DENY! was ACCEPTED - SSLCipherList not enforced"
) else (
    call :pass "excluded cipher !C_DENY! refused at the handshake"
)
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_3 -alpn h2 < nul > "%LOGDIR%\ciphers-b3.log" 2>&1
if !ERRORLEVEL! NEQ 0 goto :rc_b3_fail
findstr /L /C:"TLSv1.3" "%LOGDIR%\ciphers-b3.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :rc_b3_fail
call :pass "TLS 1.3 still negotiates - TLS 1.2 rules left it alone"
goto :rc_b3_done
:rc_b3_fail
call :fail "TLS 1.3 broken by a TLS 1.2 cipher rule - see %LOGDIR%\ciphers-b3.log"
:rc_b3_done
call :stop_server

:rc_startup
REM C / D - configurations the provider must refuse to start with.
call :expect_refusal "invalid SSLCipherList" ciphers-c BOGUSCIPHER "ciphers12=BOGUSCIPHER"
call :expect_refusal "SSLVerifyPeer without SSLCACertFile" ciphers-d SSLCACertFile "verify-no-ca"
exit /b 0

REM Stage 10c. SSLCipherSuitesTLS13 + SSLMinVersion (HashLoad/horse #597,
REM provider 1.11.0). Same judging as 10b: exit code plus the "Cipher is" /
REM "TLSv1.x" lines. A is the control for B2; 10b's control A already showed
REM the default server serving TLS 1.2, which M2 must refuse.
:run_suites13
echo.
echo -- TLS 1.3 suites + minimum TLS version on the wire (openssl s_client peer)
set "S_ALLOW=TLS_CHACHA20_POLY1305_SHA256"
set "S_DENY=TLS_AES_128_GCM_SHA256"
set "S_TYPO=TLS_AES_256_GCM_SHA348"
if not defined OPENSSL (
    call :skip "TLS 1.3 suites / minimum version - openssl.exe not on PATH; NOT exercised"
    exit /b 0
)

REM A - control: the DEFAULT server serves the TLS 1.3 client B2 must be refused.
start "" /B cmd /c "HorseNghttp2TestServer.exe tls < nul > %LOGDIR%\suites-a-server.log 2>&1"
call :wait_bind
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_3 -ciphersuites !S_DENY! -alpn h2 < nul > "%LOGDIR%\suites-a.log" 2>&1
if !ERRORLEVEL! NEQ 0 goto :s13_a_fail
findstr /L /C:"Cipher is !S_DENY!" "%LOGDIR%\suites-a.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :s13_a_fail
call :pass "control: default server negotiates !S_DENY! over TLS 1.3"
goto :s13_a_done
:s13_a_fail
call :fail "control: default server did NOT accept a !S_DENY! client - B2 proves nothing"
:s13_a_done
call :stop_server

REM B - server restricted to S_ALLOW.
start "" /B cmd /c "HorseNghttp2TestServer.exe suites13=!S_ALLOW! < nul > %LOGDIR%\suites-b-server.log 2>&1"
call :wait_bind
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_3 -ciphersuites !S_ALLOW! -alpn h2 < nul > "%LOGDIR%\suites-b1.log" 2>&1
if !ERRORLEVEL! NEQ 0 goto :s13_b1_fail
findstr /L /C:"Cipher is !S_ALLOW!" "%LOGDIR%\suites-b1.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :s13_b1_fail
findstr /L /C:"ALPN protocol: h2" "%LOGDIR%\suites-b1.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :s13_b1_fail
call :pass "configured TLS 1.3 suite negotiated, ALPN h2"
goto :s13_b1_done
:s13_b1_fail
call :fail "configured TLS 1.3 suite !S_ALLOW! was NOT negotiated - see %LOGDIR%\suites-b1.log"
:s13_b1_done
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_3 -ciphersuites !S_DENY! -alpn h2 < nul > "%LOGDIR%\suites-b2.log" 2>&1
if !ERRORLEVEL! EQU 0 (
    call :fail "excluded TLS 1.3 suite !S_DENY! was ACCEPTED - SSLCipherSuitesTLS13 not enforced"
) else (
    call :pass "excluded TLS 1.3 suite !S_DENY! refused at the handshake"
)
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_2 -alpn h2 < nul > "%LOGDIR%\suites-b3.log" 2>&1
if !ERRORLEVEL! NEQ 0 goto :s13_b3_fail
findstr /L /C:"TLSv1.2" "%LOGDIR%\suites-b3.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :s13_b3_fail
call :pass "TLS 1.2 still negotiates - the TLS 1.3 setting left it alone"
goto :s13_b3_done
:s13_b3_fail
call :fail "TLS 1.2 broken by a TLS 1.3 suite setting - see %LOGDIR%\suites-b3.log"
:s13_b3_done
call :stop_server

REM C - a typo beside a valid name: only the read-back can refuse it.
call :expect_refusal "TLS 1.3 suite typo beside a valid name" suites-c !S_TYPO! "suites13=!S_TYPO!:!S_ALLOW!"

REM M - minimum version. minver13 refuses TLS 1.2; minver12 is a floor, not a pin.
start "" /B cmd /c "HorseNghttp2TestServer.exe minver13 < nul > %LOGDIR%\minver13-server.log 2>&1"
call :wait_bind
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_3 -alpn h2 < nul > "%LOGDIR%\minver-m1.log" 2>&1
if !ERRORLEVEL! NEQ 0 goto :mv_m1_fail
findstr /L /C:"TLSv1.3" "%LOGDIR%\minver-m1.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :mv_m1_fail
call :pass "minver13: a TLS 1.3 client is served"
goto :mv_m1_done
:mv_m1_fail
call :fail "minver13: TLS 1.3 client NOT served - see %LOGDIR%\minver-m1.log"
:mv_m1_done
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_2 -alpn h2 < nul > "%LOGDIR%\minver-m2.log" 2>&1
if !ERRORLEVEL! EQU 0 (
    call :fail "minver13: a TLS 1.2 client was ACCEPTED - SSLMinVersion not enforced"
) else (
    call :pass "minver13: a TLS 1.2 client is REFUSED"
)
call :stop_server
start "" /B cmd /c "HorseNghttp2TestServer.exe minver12 < nul > %LOGDIR%\minver12-server.log 2>&1"
call :wait_bind
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_2 -alpn h2 < nul > "%LOGDIR%\minver-m3.log" 2>&1
if !ERRORLEVEL! NEQ 0 goto :mv_m3_fail
findstr /L /C:"TLSv1.2" "%LOGDIR%\minver-m3.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :mv_m3_fail
call :pass "minver12: a TLS 1.2 client is served"
goto :mv_m3_done
:mv_m3_fail
call :fail "minver12: TLS 1.2 client NOT served - see %LOGDIR%\minver-m3.log"
:mv_m3_done
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% -servername localhost -tls1_3 -alpn h2 < nul > "%LOGDIR%\minver-m4.log" 2>&1
if !ERRORLEVEL! NEQ 0 goto :mv_m4_fail
findstr /L /C:"TLSv1.3" "%LOGDIR%\minver-m4.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :mv_m4_fail
call :pass "minver12 is a MINIMUM: TLS 1.3 is still served"
goto :mv_m4_done
:mv_m4_fail
call :fail "minver12 pinned the version - TLS 1.3 NOT served - see %LOGDIR%\minver-m4.log"
:mv_m4_done
call :stop_server
exit /b 0

REM expect_refusal <label> <logname> <must-contain> <server-args>
:expect_refusal
start "" /B cmd /c "HorseNghttp2TestServer.exe %~4 < nul > %LOGDIR%\%~2.log 2>&1"
call :wait_bind
netstat -ano | findstr /R /C:":%TLS_PORT% .*LISTENING" >nul 2>&1
if !ERRORLEVEL! EQU 0 (
    call :fail "%~1 - the server STARTED and ran; the setting was accepted"
    call :stop_server
    exit /b 0
)
findstr /L /C:"FATAL" "%LOGDIR%\%~2.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :er_fail
findstr /L /C:"%~3" "%LOGDIR%\%~2.log" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :er_fail
call :pass "%~1 - refused at startup, naming %~3"
exit /b 0
:er_fail
call :fail "%~1 - no FATAL line naming %~3; see %LOGDIR%\%~2.log"
exit /b 0

REM A fixed sleep, not a poll. `ping` is the portable batch sleep and is coarse,
REM which is why verify-drain-delivery.bat raises its own trigger for the same
REM reason. 2s covers the TLS listener and the driver probe that reports the
REM resolved engine ~400ms in.
:wait_bind
ping -n 3 127.0.0.1 >nul 2>&1
exit /b 0

:stop_server
taskkill /F /IM HorseNghttp2TestServer.exe >nul 2>&1
ping -n 2 127.0.0.1 >nul 2>&1
exit /b 0

:pass
echo   PASS  %~1
set /a PASSED+=1
exit /b 0

:fail
echo   FAIL  %~1
set /a FAILED+=1
exit /b 0

:skip
echo   SKIP  %~1
echo         NOT a pass: this stage verified nothing.
set /a SKIPPED+=1
exit /b 0
