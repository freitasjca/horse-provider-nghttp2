@echo off
REM ===========================================================================
REM  build-linux64.bat
REM  Compile-only check of the Delphi Linux64 code paths, run from Windows.
REM
REM  Purpose: SocketWaitReadable in Nghttp2.Socket.pas has four compiler
REM  branches. Windows and FPC/Unix are validated; the Delphi POSIX branch
REM  (Posix.SysSelect / FD_ZERO / _FD_SET / Posix.SysTime) has never been
REM  compiled. The Windows branch already shipped a bug, so this one deserves
REM  a compiler's opinion rather than an argument from similarity.
REM
REM  Compile only: emits throwaway .dcu, never links or deploys, so PAServer
REM  does NOT need to be running.
REM
REM  Usage:
REM    cd samples\tests
REM    build-linux64.bat
REM
REM  Override discovery:  set BDS=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
REM
REM  ---------------------------------------------------------------------
REM  cmd.exe rule this script obeys, learned the hard way, twice:
REM
REM    Delphi lives under "C:\Program Files (x86)\...". cmd matches parens
REM    BEFORE expanding variables, so ANY %VAR% holding that path closes a
REM    parenthesised block early — you get errors like
REM      "\Embarcadero\Studio\23.0\lib\linux64\release was unexpected".
REM    It is the variable's VALUE that breaks it, not its name, so avoiding
REM    %ProgramFiles(x86)% is not enough.
REM
REM  Therefore: no multi-line ( ) blocks anywhere — error paths use goto —
REM  and every path variable is read with delayed expansion !VAR!, which is
REM  substituted after parsing and so cannot introduce stray parens.
REM  ---------------------------------------------------------------------
REM ===========================================================================
setlocal enabledelayedexpansion

REM ── Locate dcclinux64 ─────────────────────────────────────────────────────
set "DCC="
if not "!BDS!"=="" if exist "!BDS!\bin\dcclinux64.exe" set "DCC=!BDS!\bin\dcclinux64.exe"
if not defined DCC for /f "delims=" %%I in ('where dcclinux64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

REM Derive BDS from ...\Studio\NN.0\bin\dcclinux64.exe (up two levels).
REM !DCC! not %DCC% — the value contains "(x86)".
for %%I in ("!DCC!") do set "DCCDIR=%%~dpI"
for %%I in ("!DCCDIR!..") do set "BDS=%%~fI"

set "RTL=!BDS!\lib\linux64\release"
if not exist "!RTL!" goto :no_rtl

REM ── Source paths ──────────────────────────────────────────────────────────
REM  Two checkout layouts have to work here and they differ in depth:
REM    Windows repos   c:\lang\Repo\{horse, Delphi-nghttp2, horse-provider-nghttp2}
REM                    -> all three are siblings, horse is 3 levels up
REM    devcontainer    <root>\patches\{Delphi-nghttp2, horse-provider-nghttp2}
REM                    with horse\ at <root>  -> horse is 4 levels up
REM  So each root is probed against a marker file rather than assumed, and
REM  any of them can be overridden from the environment.
set "HERE=%~dp0"
set "OUT=%TEMP%\nghttp2-linux64-check"

if defined DNG_SRC   set "DNG=!DNG_SRC!"
if defined PROV_SRC  set "PROV=!PROV_SRC!"
if defined HORSE_SRC set "HORSE=!HORSE_SRC!"

if not defined DNG for %%I in ("!HERE!..\..\..\Delphi-nghttp2\src") do set "DNG=%%~fI"
if not exist "!DNG!\Nghttp2.Socket.pas" for %%I in ("!HERE!..\..\..\..\patches\Delphi-nghttp2\src") do set "DNG=%%~fI"

if not defined PROV for %%I in ("!HERE!..\..\src") do set "PROV=%%~fI"

REM horse\src: sibling layout first, then the devcontainer's extra level.
if not defined HORSE for %%I in ("!HERE!..\..\..\horse\src") do set "HORSE=%%~fI"
if not exist "!HORSE!\Horse.pas" for %%I in ("!HERE!..\..\..\..\horse\src") do set "HORSE=%%~fI"

REM Validate every root up front. A missing one used to surface as a
REM confusing F2613 three stages later, naming a unit rather than the path.
if not exist "!DNG!\Nghttp2.Socket.pas"        goto :no_dng
if not exist "!PROV!\Horse.Provider.Nghttp2.pas" goto :no_prov
if not exist "!HORSE!\Horse.pas"               goto :no_horse

if exist "!OUT!" rd /s /q "!OUT!"
mkdir "!OUT!" 2>nul

set "UNITS=!RTL!;!DNG!;!PROV!;!HORSE!"
set "SCOPES=System;System.Win;Posix;Xml;Data;Web;Soap"

echo DCC:    !DCC!
echo RTL:    !RTL!
echo Source: !DNG!
echo         !PROV!
echo         !HORSE!
echo Output: !OUT!   (throwaway .dcu - nothing is linked or deployed)
echo.

set FAILED=0

echo -- 1  Nghttp2.Socket  (SocketWaitReadable Delphi POSIX branch) ----------
call :compile "!DNG!\Nghttp2.Socket.pas"
if errorlevel 1 goto :stage1_failed
echo.

echo -- 2  Nghttp2.Session + Nghttp2.Server  (async dispatch core) -----------
call :compile "!DNG!\Nghttp2.Session.pas"
call :compile "!DNG!\Nghttp2.Server.pas"
echo.

echo -- 2b  Nghttp2.Engine.Epoll  (event-loop driver, Linux only) ----------
rem  Nothing references this unit - Nghttp2.Server holds only a function
rem  pointer, so linking it is what enables it. No program pulls it in,
rem  which means it is only ever compiled if named explicitly here.
call :compile "!DNG!\Nghttp2.Engine.Epoll.pas"
echo.

echo -- 3  Horse.Provider.Nghttp2  (worker pool + graceful drain) ------------
call :compile "!PROV!\Horse.Provider.Nghttp2.pas"
echo.
goto :summary

REM ── error paths (goto, never parenthesised blocks) ────────────────────────
:no_dcc
echo ERROR: dcclinux64.exe not found on PATH and BDS is not set.
echo        Run from a Delphi command prompt, or set BDS, e.g.
echo            set BDS=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
exit /b 2

:no_rtl
echo ERROR: Linux64 RTL units not found at:
echo        !RTL!
echo        Install the Linux64 platform via the Delphi installer.
exit /b 2

:no_dng
echo ERROR: Delphi-nghttp2 sources not found. Tried:
echo        !DNG!
echo        Expected Nghttp2.Socket.pas there. Override with:
echo            set DNG_SRC=c:\path\to\Delphi-nghttp2\src
exit /b 2

:no_prov
echo ERROR: provider sources not found. Tried:
echo        !PROV!
echo        Expected Horse.Provider.Nghttp2.pas there. Override with:
echo            set PROV_SRC=c:\path\to\horse-provider-nghttp2\src
exit /b 2

:no_horse
echo ERROR: Horse sources not found. Tried:
echo        !HORSE!
echo        Expected Horse.pas there. Override with:
echo            set HORSE_SRC=c:\lang\Repo\horse\src
exit /b 2

:stage1_failed
echo.
echo   Most likely causes, in order:
echo     E2003 Undeclared identifier '_FD_SET'  - name differs from what
echo           Posix.SysSelect exports; check that unit's declarations.
echo     E2036 Variable required                - a POSIX signature wants the
echo           variable itself, not its address; drop the '@'.
echo     Unit not found Posix.SysSelect/SysTime - Linux64 RTL path is wrong.
echo.
goto :summary

:summary
if "%FAILED%"=="0" goto :all_ok
echo One or more Linux64 compile checks FAILED - see errors above.
exit /b 1

:all_ok
echo All Linux64 compile checks PASSED.
echo.
echo That closes the last of the four SocketWaitReadable branches.
echo Going further: cross-compile HorseNghttp2DaemonDemo, deploy via
echo PAServer, and run the 94-check suite against it.
exit /b 0

REM ── compile one unit ──────────────────────────────────────────────────────
:compile
set "SRC=%~1"
for %%I in ("!SRC!") do set "SRCNAME=%%~nxI"
echo   compiling !SRCNAME! ...
"!DCC!" -B -Q -NS!SCOPES! -U"!UNITS!" -N0"!OUT!" -dHORSE_PROVIDER_NGHTTP2 "!SRC!"
if errorlevel 1 goto :compile_failed
echo   PASS  !SRCNAME!
exit /b 0

:compile_failed
echo   FAIL  !SRCNAME!
set FAILED=1
exit /b 1
