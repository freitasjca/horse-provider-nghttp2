@echo off
REM ===========================================================================
REM  build-msbuild.bat
REM  Build the horse-provider-nghttp2 Delphi projects from the command line.
REM
REM  This is the MSBuild counterpart to samples\tests\build-linux64.bat.
REM  That script drives dcclinux64 directly and only COMPILES units; this one
REM  drives msbuild over the .dproj files and produces linked executables, so
REM  it is what you want before running the Windows suites.
REM
REM  Usage:
REM    build-msbuild.bat [target] [config] [platform] [mode]
REM
REM    target    tests (default) | all | grpc | demos | <ProjectName>
REM    config    Release (default) | Debug
REM    platform  Win64 (default) | Win32
REM    mode      full (default) | fast | clean
REM
REM  Examples:
REM    build-msbuild.bat                       tests, Release, Win64, full
REM    build-msbuild.bat all                   all 8 projects
REM    build-msbuild.bat tests Debug Win32     Debug Win32
REM    build-msbuild.bat grpc Release Win64 fast    incremental
REM    build-msbuild.bat HorseNghttp2TestServer     one project by name
REM
REM  Override Delphi discovery:
REM    set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
REM
REM  ---------------------------------------------------------------------
REM  Three things this script does deliberately, each learned the hard way.
REM
REM  1. NO PARENTHESISED BLOCKS.
REM     Delphi lives under "C:\Program Files (x86)\...". cmd matches parens
REM     BEFORE expanding variables, so ANY %VAR% holding that path closes a
REM     ( ) block early. It is the variable's VALUE that breaks it, not its
REM     name, so avoiding %ProgramFiles(x86)% is not enough. Error paths use
REM     goto, the version scan calls a :label per iteration, and every path
REM     variable is read with delayed expansion !VAR!.
REM
REM     The equivalent script in horse-provider-crosssocket has this bug live:
REM     its rsvars scan assigns that path inside a for ( ) block, so the loop
REM     only works when DELPHI_ROOT is already set.
REM
REM  2. DEFAULT IS A FULL BUILD - BY WIPING THE DCU DIRECTORY, NOT BY
REM     /p:DCC_BuildAllUnits.
REM     A {$DEFINE} in a .dpr does not invalidate DCUs built with different
REM     defines, and the failure is silent - you get a binary compiled against
REM     the wrong provider with no diagnostic. So a full build is the default.
REM
REM     It used to ask for that with /p:DCC_BuildAllUnits=true (dcc's -B).
REM     That does not work on these projects: MSBuild's DCC task expands the
REM     unit closure onto the command line and blows the 32000-character limit,
REM       warning MSB6002: The command-line for the "DCC" task is too long
REM       error   MSB6003: The specified task executable "dcc" could not be run
REM     on every project, before compiling anything.
REM
REM     Wiping the shared DCU directory first gets the same guarantee: with no
REM     .dcu to reuse, dcc recompiles from source whatever the flags say. It is
REM     also STRONGER here than -B would have been on one project, because that
REM     directory is c:\lang\Repo\temp\<Platform>\<Config> - shared by every
REM     repo under that parent, so a stale unit can arrive from a build of a
REM     DIFFERENT repo entirely. Wiping it is the only thing that covers that.
REM
REM     Cost: the first build after a wipe recompiles everything, and other
REM     repos sharing the directory will do the same on their next build.
REM
REM     Use "fast" only when you know nothing outside the project changed.
REM     After copying patched units from patches\, never use "fast".
REM
REM  3. THE TARGET VARIABLES ARE CALLED TGTCONFIG / TGTPLATFORM, NOT
REM     CONFIG / PLATFORM.
REM     rsvars.bat CLEARS %PLATFORM%. This script parses its arguments first
REM     and calls rsvars afterwards, so a variable named PLATFORM is empty by
REM     the time msbuild runs - and msbuild then fails with
REM       error : Invalid PLATFORM variable "". PLATFORM must be one of ...
REM     naming Win32/Win64/... as if the argument had been bad. It had not;
REM     rsvars ate it. The banner is the tell: the platform slot prints blank.
REM     Names the RAD Studio toolchain owns are not safe as script variables,
REM     so both are prefixed. Do not "simplify" them back.
REM
REM  4. NO /m (PARALLEL MSBUILD).
REM     All eight projects share one DCU directory (temp\$(Platform)\$(Config))
REM     and one output directory (bin\$(Platform)\$(Config)). They also share
REM     most of their units. Building them concurrently races on the same .dcu
REM     files. Sequential is a few seconds slower and correct.
REM  ---------------------------------------------------------------------
REM ===========================================================================
setlocal enabledelayedexpansion

REM -- Arguments -------------------------------------------------------------
set "TARGET=%~1"
set "TGTCONFIG=%~2"
set "TGTPLATFORM=%~3"
set "MODE=%~4"

if "!TARGET!"==""   set "TARGET=tests"
if "!TGTCONFIG!"==""   set "TGTCONFIG=Release"
if "!TGTPLATFORM!"=="" set "TGTPLATFORM=Win64"
if "!MODE!"==""     set "MODE=full"

if /I "!TGTCONFIG!"=="Release" goto :cfg_ok
if /I "!TGTCONFIG!"=="Debug"   goto :cfg_ok
goto :bad_config
:cfg_ok

if /I "!TGTPLATFORM!"=="Win64" goto :plat_ok
if /I "!TGTPLATFORM!"=="Win32" goto :plat_ok
if /I "!TGTPLATFORM!"=="Linux64" goto :linux_note
goto :bad_platform
:plat_ok

REM No DCC_BuildAllUnits - see note 2. The DCU wipe below does the job.
REM
REM IMPORTANT: DCC_UseMSBuildExternally makes CodeGear.Delphi.Targets write
REM the DCC arguments to a .cmds response file instead of putting the complete
REM compiler invocation on MSBuild's process command line. This is essential
REM on machines whose IDE Library Path is large: Delphi's MSBuild targets can
REM expand that global path into the DCC task command line and exceed Windows'
REM ~32K command-line limit before dcc64.exe is even started.
REM
REM This does NOT change the compiler search path or the IDE configuration.
REM It only changes how the DCC task transports its arguments to dcc64.
set "BUILDARGS=/p:DCC_UseMSBuildExternally=true"
set "DOWIPE=0"
if /I "!MODE!"=="full"  set "DOWIPE=1"
if /I "!MODE!"=="clean" set "DOWIPE=1"
if /I "!MODE!"=="full"  goto :mode_ok
if /I "!MODE!"=="fast"  goto :mode_ok
if /I "!MODE!"=="clean" goto :mode_ok
goto :bad_mode
:mode_ok

REM -- Locate rsvars.bat -----------------------------------------------------
REM  rsvars.bat is what puts msbuild on PATH and sets BDS/FrameworkDir.
REM  Without it msbuild either is not found or cannot resolve
REM  CodeGear.Delphi.Targets, which surfaces as a confusing XML error.
set "RSVARS="
if not "!DELPHI_ROOT!"=="" if exist "!DELPHI_ROOT!\bin\rsvars.bat" set "RSVARS=!DELPHI_ROOT!\bin\rsvars.bat"
if not "!BDS!"==""         if exist "!BDS!\bin\rsvars.bat"         set "RSVARS=!BDS!\bin\rsvars.bat"

REM Newest first. One :label call per version keeps the "(x86)" path out of
REM any parenthesised block - see note 1 in the header.
for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V

if not defined RSVARS goto :no_rsvars

REM -- Resolve repo root -----------------------------------------------------
set "HERE=%~dp0"
for %%I in ("!HERE!..") do set "ROOT=%%~fI"
if not exist "!ROOT!\src\Horse.Provider.Nghttp2.pas" goto :no_root

REM  Output lands ABOVE the repo, not inside it.
REM
REM  Every .dproj sets DCC_ExeOutput to ..\..\..\bin\$(Platform)\$(Config) and
REM  DCC_DcuOutput to ..\..\..\temp\$(Platform)\$(Config). Counted from a
REM  project in samples\<kind>\, three levels up is the repo's PARENT - so on
REM  a standard checkout the binaries go to c:\lang\Repo\bin\Win64\Release and
REM  the DCUs to c:\lang\Repo\temp\Win64\Release, both SHARED WITH EVERY OTHER
REM  REPO under that parent.
REM
REM  Two consequences, and they are why this is spelled out rather than
REM  hardcoded: reporting !ROOT!\bin here would name a directory that does not
REM  exist, and a stale DCU can arrive from a DIFFERENT repo's build - which
REM  makes the full-build default (note 2 in the header) more important here
REM  than it would be for a self-contained project.
for %%I in ("!ROOT!\..") do set "OUTROOT=%%~fI"
set "EXEDIR=!OUTROOT!\bin\!TGTPLATFORM!\!TGTCONFIG!"

REM -- Load the Delphi environment -------------------------------------------
echo Delphi:   !RSVARS!
call "!RSVARS!" > nul
REM echo BDS=!BDS!
REM echo DelphiLibraryPath=!DelphiLibraryPath!
REM echo DCC_UnitSearchPath=!DCC_UnitSearchPath!
REM echo DCC_IncludePath=!DCC_IncludePath!
REM echo DCC_ResourcePath=!DCC_ResourcePath!
REM echo DCC_ObjPath=!DCC_ObjPath!
where msbuild > nul 2>&1
if errorlevel 1 goto :no_msbuild

REM rsvars just ran. Prove it did not eat the target settings - see note 3.
if "!TGTPLATFORM!"=="" goto :env_ate_platform
if "!TGTCONFIG!"==""  goto :env_ate_platform

echo Repo:     !ROOT!
echo Build:    !TARGET!  !TGTCONFIG!  !TGTPLATFORM!  (!MODE!)
echo Output:   !EXEDIR!
echo           ^(above the repo - the .dproj files write to ..\..\..\bin^)
echo.
if /I "!MODE!"=="fast" echo   NOTE: incremental build. If you copied patched units or changed a
if /I "!MODE!"=="fast" echo         define, stop and re-run without "fast" - a stale DCU fails silently.
if /I "!MODE!"=="fast" echo.

set FAILED=0
set BUILT=0

REM Wipe the shared DCU directory ONCE, before any project builds. Doing it
REM per project would make every project after the first recompile the shared
REM units from scratch - correct but needlessly slow.
REM
REM Guarded: the path is built from a root already validated by the
REM src\Horse.Provider.Nghttp2.pas check, it always contains \temp\, and it is
REM only removed if it exists. This is build output; nothing else lives here.
set "DCUDIR=!OUTROOT!\temp\!TGTPLATFORM!\!TGTCONFIG!"
if "!DOWIPE!"=="0" goto :no_wipe
if not exist "!DCUDIR!" goto :no_wipe
echo Wiping DCUs: !DCUDIR!
rd /s /q "!DCUDIR!"
echo.
:no_wipe

REM -- Expand the target into projects ---------------------------------------
if /I "!TARGET!"=="tests" goto :t_tests
if /I "!TARGET!"=="grpc"  goto :t_grpc
if /I "!TARGET!"=="demos" goto :t_demos
if /I "!TARGET!"=="all"   goto :t_all
goto :t_named

:t_tests
call :build "samples\tests\HorseNghttp2TestServer.dproj"
call :build "samples\tests\HorseNghttp2TestClient.dproj"
call :build "samples\tests\HorseNghttp2TlsTestServer.dproj"
goto :summary

:t_grpc
call :build "samples\grpc\HorseNghttp2GrpcDemo.dproj"
call :build "samples\grpc\HorseNghttp2GrpcTestClient.dproj"
goto :summary

:t_demos
call :build "samples\daemon\HorseNghttp2DaemonDemo.dproj"
call :build "samples\service\HorseNghttp2ServiceDemo.dproj"
call :build "samples\vcl\HorseNghttp2VclDemo.dproj"
goto :summary

:t_all
call :build "samples\tests\HorseNghttp2TestServer.dproj"
call :build "samples\tests\HorseNghttp2TestClient.dproj"
call :build "samples\tests\HorseNghttp2TlsTestServer.dproj"
call :build "samples\grpc\HorseNghttp2GrpcDemo.dproj"
call :build "samples\grpc\HorseNghttp2GrpcTestClient.dproj"
call :build "samples\daemon\HorseNghttp2DaemonDemo.dproj"
call :build "samples\service\HorseNghttp2ServiceDemo.dproj"
call :build "samples\vcl\HorseNghttp2VclDemo.dproj"
goto :summary

REM  A bare project name, with or without .dproj, found anywhere under samples\.
:t_named
set "WANTED=!TARGET!"
if /I not "!WANTED:~-6!"==".dproj" set "WANTED=!WANTED!.dproj"
set "FOUND="
for /f "delims=" %%I in ('dir /b /s "!ROOT!\samples\!WANTED!" 2^>nul') do if not defined FOUND set "FOUND=%%I"
if not defined FOUND goto :no_project
call :build "!FOUND!"
goto :summary

REM -- Build one project -----------------------------------------------------
:build
set "PROJ=%~1"
REM Accept both a repo-relative path and an absolute one (from :t_named).
if not exist "!PROJ!" set "PROJ=!ROOT!\%~1"
for %%I in ("!PROJ!") do set "PROJNAME=%%~nI"
if not exist "!PROJ!" goto :build_missing

echo -- !PROJNAME! ---------------------------------------------------------
if /I "!MODE!"=="clean" call :do_clean "!PROJ!"

msbuild "!PROJ!" /t:Build /p:Config=!TGTCONFIG! /p:Platform=!TGTPLATFORM! !BUILDARGS! /nologo /v:minimal
if errorlevel 1 goto :build_failed
set /a BUILT+=1
echo    PASS  !PROJNAME!
echo.
exit /b 0

:do_clean
msbuild "%~1" /t:Clean /p:Config=!TGTCONFIG! /p:Platform=!TGTPLATFORM! /nologo /v:quiet
exit /b 0

:build_failed
echo    FAIL  !PROJNAME!
echo.
set FAILED=1
exit /b 1

:build_missing
echo    SKIP  !PROJNAME!  (not found: !PROJ!)
echo.
set FAILED=1
exit /b 1

REM -- Try one Studio version ------------------------------------------------
:try_version
if defined RSVARS exit /b 0
set "CAND=%ProgramFiles(x86)%\Embarcadero\Studio\%~1\bin\rsvars.bat"
if exist "!CAND!" set "RSVARS=!CAND!"
exit /b 0

REM -- Error paths (goto, never parenthesised blocks) ------------------------
:bad_config
echo ERROR: config must be Release or Debug, got "!TGTCONFIG!".
exit /b 2

:bad_platform
echo ERROR: platform must be Win64 or Win32, got "!TGTPLATFORM!".
exit /b 2

:bad_mode
echo ERROR: mode must be full, fast or clean, got "!MODE!".
exit /b 2

:linux_note
echo ERROR: Linux64 through msbuild needs a running PAServer and a configured
echo        SDK, and it LINKS and DEPLOYS rather than just compiling.
echo.
echo        For a compile-only check of the Linux64 code paths use:
echo            cd samples\tests
echo            build-linux64.bat
echo.
echo        That drives dcclinux64 directly, needs no PAServer, and is the
echo        script that compiles Nghttp2.Engine.Epoll with LINUX defined.
exit /b 2

:no_rsvars
echo ERROR: rsvars.bat not found.
echo        Looked at DELPHI_ROOT, BDS, and Studio 23.0/22.0/21.0/20.0/19.0
echo        under "%ProgramFiles(x86)%\Embarcadero".
echo.
echo        Set it explicitly:
echo            set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
exit /b 2

:env_ate_platform
echo ERROR: the Delphi environment cleared this script's target settings.
echo        After calling rsvars.bat:  platform="!TGTPLATFORM!"  config="!TGTCONFIG!"
echo        Both are set from ARGUMENTS, before rsvars runs. rsvars.bat clears
echo        %%PLATFORM%%, which is why they are named TGTPLATFORM/TGTCONFIG here -
echo        see note 3 in the header. If this fires, something else in the
echo        environment is clearing those too.
exit /b 2

:no_msbuild
echo ERROR: msbuild is not on PATH even after calling rsvars.bat:
echo            !RSVARS!
echo        That usually means the .NET Framework directory it points at is
echo        missing. Open a "RAD Studio Command Prompt" and run msbuild there
echo        to confirm the installation.
exit /b 2

:no_root
echo ERROR: repo root not found. Expected src\Horse.Provider.Nghttp2.pas under:
echo            !ROOT!
echo        Run this script from the repo's scripts\ directory.
exit /b 2

:no_project
echo ERROR: no project named "!WANTED!" under !ROOT!\samples\.
echo.
echo        Known projects:
echo            HorseNghttp2TestServer      HorseNghttp2TestClient
echo            HorseNghttp2TlsTestServer   HorseNghttp2GrpcDemo
echo            HorseNghttp2GrpcTestClient  HorseNghttp2DaemonDemo
echo            HorseNghttp2ServiceDemo     HorseNghttp2VclDemo
exit /b 2

REM -- Summary ---------------------------------------------------------------
:summary
echo ===========================================================================
if "!FAILED!"=="0" goto :all_ok
echo  BUILD FAILED  -  !BUILT! project(s^) built before the failure.
echo.
echo  Common causes, in order:
echo.
echo    - MSB6002 + MSB6003 "command-line for the DCC task is too long" /
echo      "The specified task executable dcc could not be run":
echo      NOT caused by this script and NOT caused by the .dproj - that file
echo      holds only ~115 chars of search paths and 4 Include items, measured.
echo      MSBuild is composing a ^>32000-char command line from somewhere else,
echo      almost certainly the environment (MSBuild seeds properties FROM
echo      environment variables, and the Delphi targets append them into the
echo      path properties it passes to dcc).
echo      Diagnose - capture the real command line:
echo          msbuild "^<project^>.dproj" /t:Build /p:Config=Release
echo                  /p:Platform=Win64 /flp:logfile=dcc-diag.log;verbosity=diagnostic
echo          powershell -c "gc dcc-diag.log ^| %% { $_.Length } ^| sort -desc ^| select -first 3"
echo      Then look at what fills the longest line.
echo      This script already enables DCC_UseMSBuildExternally, which makes
echo      CodeGear.Delphi.Targets put the DCC arguments in a .cmds response
echo      file instead of the MSBuild process command line. If this error still
echo      appears, check that the installed CodeGear.Delphi.Targets supports
echo      DCC_UseMSBuildExternally and inspect the generated .cmds file.
echo.
echo    - Stale DCU: re-run without "fast" so the shared DCU directory is
echo      wiped first. A DCU built with different defines is not invalidated
echo      by changing them, and that directory is shared across repos.
echo    - Unit not found: check DCC_UnitSearchPath in the .dproj. Do NOT
echo      edit the .dproj to fix it - fix the checkout layout instead.
echo    - Compiler error: look for [dcc64 Error] lines above.
exit /b 1

:all_ok
echo  BUILD OK  -  !BUILT! project(s^) -^> !EXEDIR!
echo.
echo  Next, the Windows suites:
echo      cd "!EXEDIR!"
echo      start "" HorseNghttp2TestServer.exe
echo      HorseNghttp2TestClient.exe
exit /b 0
