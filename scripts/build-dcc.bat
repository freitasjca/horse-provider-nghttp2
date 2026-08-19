@echo off
REM ===========================================================================
REM  build-dcc.bat
REM  Build the Windows test executables by invoking dcc64 DIRECTLY, bypassing
REM  MSBuild entirely.
REM
REM  ---------------------------------------------------------------------
REM  Why this exists (measured 2026-08-17, not guessed)
REM
REM  build-msbuild.bat cannot build these projects on a machine with a large
REM  IDE Library Path. Every project fails before compiling anything with:
REM
REM    warning MSB6002: The command-line for the "DCC" task is too long
REM    error   MSB6003: The specified task executable "dcc" could not be run.
REM                     The filename or extension is too long
REM
REM  The cause is NOT this repo. Captured from a plain `msbuild` run with no
REM  script involved, the generated dcc64 command line carries the IDE's whole
REM  global Library Path - ACBr (hundreds of directories), ZXing, jose-jwt,
REM  LockBox, ICS, Python4Delphi, AWS SDK, boss module caches - and the DCC
REM  task emits that entire list FOUR times, once each for -I, -O, -R and -U.
REM  Roughly 7-8 KB, four times over, against a 32000-character ceiling.
REM
REM  For scale: these .dproj files contribute 115 characters of search path
REM  between them. The projects are not the problem and editing them would not
REM  help - which is just as well, since the project rules forbid it.
REM
REM  The IDE builds the same projects fine because it does NOT use MSBuild; it
REM  drives the compiler directly and never constructs that command line. This
REM  script does the same thing, with only the paths these projects actually
REM  need. Result: a command line in the hundreds of characters.
REM
REM  Alternative fix, if you would rather keep using msbuild: trim the Win64
REM  Library Path in Tools > Options > Language > Delphi > Library. That fixes
REM  every msbuild build on the machine, not just this repo - at the cost of
REM  the IDE no longer finding those libraries for other projects.
REM  ---------------------------------------------------------------------
REM
REM  Usage:
REM    build-dcc.bat [target] [config]
REM
REM    target   tests (default) | all | grpc | <ProjectName>
REM    config   Release (default) | Debug
REM
REM  Win64 only. Linux64 has its own compile-only checker (build-linux64.bat).
REM
REM  No parenthesised blocks anywhere; see build-msbuild.bat note 1.
REM ===========================================================================
setlocal enabledelayedexpansion

set "TARGET=%~1"
set "TGTCONFIG=%~2"
if "!TARGET!"==""    set "TARGET=tests"
if "!TGTCONFIG!"=="" set "TGTCONFIG=Release"

if /I "!TGTCONFIG!"=="Release" goto :cfg_ok
if /I "!TGTCONFIG!"=="Debug"   goto :cfg_ok
echo ERROR: config must be Release or Debug, got "!TGTCONFIG!".
exit /b 2
:cfg_ok

REM -- Locate dcc64 ----------------------------------------------------------
set "DCC="
if not "!DELPHI_ROOT!"=="" if exist "!DELPHI_ROOT!\bin\dcc64.exe" set "DCC=!DELPHI_ROOT!\bin\dcc64.exe"
if not "!BDS!"==""         if exist "!BDS!\bin\dcc64.exe"         set "DCC=!BDS!\bin\dcc64.exe"
for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V
if not defined DCC for /f "delims=" %%I in ('where dcc64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

for %%I in ("!DCC!") do set "DCCDIR=%%~dpI"
for %%I in ("!DCCDIR!..") do set "BDSROOT=%%~fI"

set "RTL=!BDSROOT!\lib\Win64\!TGTCONFIG!"
if /I "!TGTCONFIG!"=="Debug" set "RTL=!BDSROOT!\lib\Win64\debug"
if /I "!TGTCONFIG!"=="Release" set "RTL=!BDSROOT!\lib\Win64\release"
if not exist "!RTL!" goto :no_rtl

REM -- Resolve source roots --------------------------------------------------
set "HERE=%~dp0"
for %%I in ("!HERE!..") do set "ROOT=%%~fI"
if not exist "!ROOT!\src\Horse.Provider.Nghttp2.pas" goto :no_root
for %%I in ("!ROOT!\..") do set "OUTROOT=%%~fI"

if defined HORSE_SRC set "HORSE=!HORSE_SRC!"
if defined DNG_SRC   set "DNG=!DNG_SRC!"
if not defined HORSE for %%I in ("!OUTROOT!\horse\src") do set "HORSE=%%~fI"
if not defined DNG   for %%I in ("!OUTROOT!\Delphi-nghttp2\src") do set "DNG=%%~fI"

if not exist "!HORSE!\Horse.pas"            goto :no_horse
if not exist "!DNG!\Nghttp2.Socket.pas"     goto :no_dng

set "EXEDIR=!OUTROOT!\bin\Win64\!TGTCONFIG!"
set "DCUDIR=!OUTROOT!\temp\Win64\!TGTCONFIG!"
if not exist "!EXEDIR!" mkdir "!EXEDIR!" 2>nul
if not exist "!DCUDIR!" mkdir "!DCUDIR!" 2>nul

REM -- Compiler options ------------------------------------------------------
REM  Lifted from the command line MSBuild generates, minus the Library Path.
REM  --no-config stops dcc reading dcc64.cfg, which is another route by which
REM  machine-wide paths creep back in - the same class of problem this script
REM  exists to avoid.
set "UPATH=!RTL!;!ROOT!\src;!HORSE!;!DNG!"
set "NS=Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap"
set "ALIAS=Generics.Collections=System.Generics.Collections;Generics.Defaults=System.Generics.Defaults;WinTypes=Winapi.Windows;WinProcs=Winapi.Windows;DbiTypes=BDE;DbiProcs=BDE;DbiErrs=BDE"
set "DEFS=!TGTCONFIG!;HORSE_PROVIDER_NGHTTP2"
set "OPTS=--no-config -B -Q -TX.exe"
if /I "!TGTCONFIG!"=="Release" set "OPTS=!OPTS! -$D0 -$L- -$Y-"

echo dcc64:    !DCC!
echo RTL:      !RTL!
echo Sources:  !ROOT!\src
echo           !HORSE!
echo           !DNG!
echo Output:   !EXEDIR!
echo Defines:  !DEFS!
echo.
echo Search path is 4 entries. MSBuild's DCC task would emit the IDE's entire
echo global Library Path here, four times over - that is the 32000-char failure.
echo.

set FAILED=0
set BUILT=0

if /I "!TARGET!"=="tests" goto :t_tests
if /I "!TARGET!"=="grpc"  goto :t_grpc
if /I "!TARGET!"=="all"   goto :t_all
goto :t_named

:t_tests
call :build "!ROOT!\samples\tests" HorseNghttp2TestServer
call :build "!ROOT!\samples\tests" HorseNghttp2TestClient
call :build "!ROOT!\samples\tests" HorseNghttp2TlsTestServer
goto :summary

:t_grpc
call :build "!ROOT!\samples\grpc" HorseNghttp2GrpcDemo
call :build "!ROOT!\samples\grpc" HorseNghttp2GrpcTestClient
goto :summary

:t_all
call :build "!ROOT!\samples\tests" HorseNghttp2TestServer
call :build "!ROOT!\samples\tests" HorseNghttp2TestClient
call :build "!ROOT!\samples\tests" HorseNghttp2TlsTestServer
call :build "!ROOT!\samples\grpc"  HorseNghttp2GrpcDemo
call :build "!ROOT!\samples\grpc"  HorseNghttp2GrpcTestClient
goto :summary

:t_named
set "FOUND="
for /f "delims=" %%I in ('dir /b /s "!ROOT!\samples\!TARGET!.dpr" 2^>nul') do if not defined FOUND set "FOUND=%%I"
if not defined FOUND goto :no_project
for %%I in ("!FOUND!") do call :build "%%~dpI" "%%~nI"
goto :summary

REM -- Compile one .dpr ------------------------------------------------------
:build
set "SRCDIR=%~1"
set "NAME=%~2"
if not exist "!SRCDIR!\!NAME!.dpr" goto :build_missing

echo -- !NAME! ---------------------------------------------------------
pushd "!SRCDIR!"
"!DCC!" !OPTS! -A!ALIAS! -D!DEFS! -NS!NS! ^
  -U"!UPATH!" -I"!UPATH!" -R"!UPATH!" -O"!UPATH!" ^
  -E"!EXEDIR!" -N0"!DCUDIR!" -NU"!DCUDIR!" ^
  "!NAME!.dpr"
if errorlevel 1 goto :build_failed
popd
set /a BUILT+=1
echo    PASS  !NAME!
echo.
exit /b 0

:build_failed
popd
echo    FAIL  !NAME!
echo.
set FAILED=1
exit /b 1

:build_missing
echo    SKIP  !NAME!  (no !SRCDIR!\!NAME!.dpr)
echo.
set FAILED=1
exit /b 1

:try_version
if defined DCC exit /b 0
set "CAND=%ProgramFiles(x86)%\Embarcadero\Studio\%~1\bin\dcc64.exe"
if exist "!CAND!" set "DCC=!CAND!"
exit /b 0

REM -- Error paths -----------------------------------------------------------
:no_dcc
echo ERROR: dcc64.exe not found. Set DELPHI_ROOT, e.g.
echo            set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
exit /b 2

:no_rtl
echo ERROR: Win64 RTL not found at !RTL!
exit /b 2

:no_root
echo ERROR: repo root not found. Expected src\Horse.Provider.Nghttp2.pas under !ROOT!
exit /b 2

:no_horse
echo ERROR: Horse sources not found at !HORSE!
echo        Override:  set HORSE_SRC=c:\lang\Repo\horse\src
exit /b 2

:no_dng
echo ERROR: Delphi-nghttp2 sources not found at !DNG!
echo        Override:  set DNG_SRC=c:\lang\Repo\Delphi-nghttp2\src
exit /b 2

:no_project
echo ERROR: no !TARGET!.dpr under !ROOT!\samples\.
exit /b 2

:summary
echo ===========================================================================
if "!FAILED!"=="0" goto :all_ok
echo  BUILD FAILED  -  !BUILT! project(s^) built before the failure.
echo.
echo.
echo    F2039 Could not create output file '...\NAME.exe'
echo      NOT a compiler error - the compile SUCCEEDED and only the write
echo      failed. That exe is running and holding its own image. Expect this
echo      constantly: start the server, edit, rebuild. Kill it and re-run:
echo          taskkill /IM HorseNghttp2TestServer.exe /F
echo      Nothing is wrong with the source; the hints above are the real
echo      compile output and can be read as usual.
echo.
echo    Unit not found
echo      This script's 4-entry search path is missing something the project
echo      genuinely needs. Add it to UPATH rather than reaching for the IDE
echo      Library Path, which is what broke msbuild in the first place.
echo.
echo    Anything else
echo      A real compiler error - look for [dcc64 Error] above.
exit /b 1

:all_ok
echo  BUILD OK  -  !BUILT! project(s^) -^> !EXEDIR!
echo.
echo  Run the suites:
echo      cd "!EXEDIR!"
echo      start "" HorseNghttp2TestServer.exe
echo      HorseNghttp2TestClient.exe
exit /b 0
