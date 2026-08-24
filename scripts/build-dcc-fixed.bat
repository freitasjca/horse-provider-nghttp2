@echo off
REM ===========================================================================
REM  build-dcc.bat
REM  Build the Windows test executables by invoking dcc32/dcc64 DIRECTLY,
REM  bypassing MSBuild entirely.
REM
REM  Supports Win32 and Win64, Debug and Release.
REM
REM  Usage:
REM    build-dcc.bat [target] [config] [platform]
REM
REM    target   tests (default) | all | grpc | <ProjectName>
REM    config   Release (default) | Debug
REM    platform Win64 (default) | Win32
REM
REM  Examples:
REM    build-dcc.bat                     tests, Release, Win64
REM    build-dcc.bat all Debug Win32     all projects, Debug, Win32
REM    build-dcc.bat grpc Release Win64  grpc projects, Release, Win64
REM
REM  Override source locations:
REM    set HORSE_SRC=c:\path\to\horse\src
REM    set DNG_SRC=c:\path\to\Delphi-nghttp2\src
REM
REM  No parenthesised blocks anywhere; see build-msbuild.bat note 1.
REM ===========================================================================
setlocal enabledelayedexpansion

REM -- Arguments -------------------------------------------------------------
set "TARGET=%~1"
set "TGTCONFIG=%~2"
set "TGTPLATFORM=%~3"

if "!TARGET!"==""    set "TARGET=tests"
if "!TGTCONFIG!"=="" set "TGTCONFIG=Release"
if "!TGTPLATFORM!"=="" set "TGTPLATFORM=Win64"

if /I "!TGTCONFIG!"=="Release" goto :cfg_ok
if /I "!TGTCONFIG!"=="Debug"   goto :cfg_ok
echo ERROR: config must be Release or Debug, got "!TGTCONFIG!".
exit /b 2
:cfg_ok

if /I "!TGTPLATFORM!"=="Win64" goto :plat_ok
if /I "!TGTPLATFORM!"=="Win32" goto :plat_ok
echo ERROR: platform must be Win64 or Win32, got "!TGTPLATFORM!".
exit /b 2
:plat_ok

REM -- Select compiler -------------------------------------------------------
set "DCC_EXE=dcc64.exe"
if /I "!TGTPLATFORM!"=="Win32" set "DCC_EXE=dcc32.exe"

set "DCC="
if not "!DELPHI_ROOT!"=="" if exist "!DELPHI_ROOT!\bin\!DCC_EXE!" set "DCC=!DELPHI_ROOT!\bin\!DCC_EXE!"
if not "!BDS!"==""         if exist "!BDS!\bin\!DCC_EXE!"         set "DCC=!BDS!\bin\!DCC_EXE!"
for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V
if not defined DCC for /f "delims=" %%I in ('where !DCC_EXE! 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

for %%I in ("!DCC!") do set "DCCDIR=%%~dpI"
for %%I in ("!DCCDIR!..") do set "BDSROOT=%%~fI"

REM -- RTL path --------------------------------------------------------------
set "RTL=!BDSROOT!\lib\!TGTPLATFORM!\!TGTCONFIG!"
if /I "!TGTCONFIG!"=="Debug" set "RTL=!BDSROOT!\lib\!TGTPLATFORM!\debug"
if /I "!TGTCONFIG!"=="Release" set "RTL=!BDSROOT!\lib\!TGTPLATFORM!\release"
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

set "EXEDIR=!OUTROOT!\bin\!TGTPLATFORM!\!TGTCONFIG!"
set "DCUDIR=!OUTROOT!\temp\!TGTPLATFORM!\!TGTCONFIG!"
if not exist "!EXEDIR!" mkdir "!EXEDIR!" 2>nul
if not exist "!DCUDIR!" mkdir "!DCUDIR!" 2>nul

REM -- Compiler options ------------------------------------------------------
set "UPATH=!RTL!;!ROOT!\src;!HORSE!;!DNG!"
set "NS=Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap"
set "ALIAS=Generics.Collections=System.Generics.Collections;Generics.Defaults=System.Generics.Defaults;WinTypes=Winapi.Windows;WinProcs=Winapi.Windows;DbiTypes=BDE;DbiProcs=BDE;DbiErrs=BDE"
set "DEFS=!TGTCONFIG!;HORSE_PROVIDER_NGHTTP2"
set "OPTS=--no-config -B -Q -TX.exe"
if /I "!TGTCONFIG!"=="Release" set "OPTS=!OPTS! -$D0 -$L- -$Y-"

echo dcc:      !DCC!
echo RTL:      !RTL!
echo Platform: !TGTPLATFORM!
echo Config:   !TGTCONFIG!
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
call :build "!ROOT!\samples\tests" HorseNghttp2AdmitProbe
goto :summary

:t_grpc
call :build "!ROOT!\samples\grpc" HorseNghttp2GrpcDemo
call :build "!ROOT!\samples\grpc" HorseNghttp2GrpcTestClient
goto :summary

:t_all
call :build "!ROOT!\samples\tests" HorseNghttp2TestServer
call :build "!ROOT!\samples\tests" HorseNghttp2TestClient
call :build "!ROOT!\samples\tests" HorseNghttp2TlsTestServer
call :build "!ROOT!\samples\tests" HorseNghttp2AdmitProbe
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
set "CAND=%ProgramFiles(x86)%\Embarcadero\Studio\%~1\bin\!DCC_EXE!"
if exist "!CAND!" set "DCC=!CAND!"
exit /b 0

REM -- Error paths -----------------------------------------------------------
:no_dcc
echo ERROR: !DCC_EXE! not found. Set DELPHI_ROOT, e.g.
echo            set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
exit /b 2

:no_rtl
echo ERROR: RTL not found at !RTL!
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
echo      A real compiler error - look for [dcc32/dcc64 Error] above.
exit /b 1

:all_ok
echo  BUILD OK  -  !BUILT! project(s^) -^> !EXEDIR!
echo.
echo  Run the suites:
echo      cd "!EXEDIR!"
echo      start "" HorseNghttp2TestServer.exe
echo      HorseNghttp2TestClient.exe
exit /b 0