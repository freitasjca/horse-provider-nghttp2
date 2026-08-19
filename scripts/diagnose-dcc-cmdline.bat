@echo off
REM ===========================================================================
REM  diagnose-dcc-cmdline.bat
REM  Find out WHAT is making MSBuild's DCC command line exceed 32000 chars.
REM
REM    warning MSB6002: The command-line for the "DCC" task is too long
REM    error   MSB6003: The specified task executable "dcc" could not be run.
REM                     The filename or extension is too long
REM
REM  Written after three plausible causes were tested and eliminated:
REM
REM    the .dproj search paths  63-115 chars across all 8 projects, 3-5 entries
REM    nested/duplicate repos   c:\lang\Repo is 10 flat siblings, no nesting
REM    DCC_* environment vars   `set DCC` reports none defined
REM
REM  So the bloat is generated during the build, not read from the project or
REM  the environment, and no amount of further reasoning from outside will
REM  identify it. This captures a diagnostic MSBuild log and reports what
REM  actually fills the line: its length, its opening, which switch dominates,
REM  and - the useful one - which arguments REPEAT. A path repeated hundreds of
REM  times looks completely different from one very long list, and the fix
REM  differs accordingly.
REM
REM  Usage:
REM    diagnose-dcc-cmdline.bat [ProjectName] [Config] [Platform]
REM    diagnose-dcc-cmdline.bat                 (defaults: HorseNghttp2TestServer Release Win64)
REM
REM  Leaves dcc-diag.log next to this script. It is large (tens of MB) - the
REM  summary is what to share, not the log.
REM
REM  No parenthesised blocks; see build-msbuild.bat note 1 for why.
REM ===========================================================================
setlocal enabledelayedexpansion

set "PROJNAME=%~1"
set "TGTCONFIG=%~2"
set "TGTPLATFORM=%~3"
if "!PROJNAME!"==""    set "PROJNAME=HorseNghttp2TestServer"
if "!TGTCONFIG!"==""   set "TGTCONFIG=Release"
if "!TGTPLATFORM!"=="" set "TGTPLATFORM=Win64"

set "RSVARS="
if not "!DELPHI_ROOT!"=="" if exist "!DELPHI_ROOT!\bin\rsvars.bat" set "RSVARS=!DELPHI_ROOT!\bin\rsvars.bat"
if not "!BDS!"==""         if exist "!BDS!\bin\rsvars.bat"         set "RSVARS=!BDS!\bin\rsvars.bat"
for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V
if not defined RSVARS goto :no_rsvars

set "HERE=%~dp0"
for %%I in ("!HERE!..") do set "ROOT=%%~fI"

set "FOUND="
for /f "delims=" %%I in ('dir /b /s "!ROOT!\samples\!PROJNAME!.dproj" 2^>nul') do if not defined FOUND set "FOUND=%%I"
if not defined FOUND goto :no_project

set "LOG=!HERE!dcc-diag.log"

echo Project:  !FOUND!
echo Target:   !TGTCONFIG! !TGTPLATFORM!
echo Log:      !LOG!
echo.
echo Building with diagnostic logging. This is slow and the log is large.
echo.

call "!RSVARS!" > nul
msbuild "!FOUND!" /t:Build /p:Config=!TGTCONFIG! /p:Platform=!TGTPLATFORM! ^
  /nologo /v:quiet /flp:logfile="!LOG!";verbosity=diagnostic

echo.
echo ===========================================================================
echo  Analysing the log
echo ===========================================================================
echo.

if not exist "!LOG!" goto :no_log
powershell -NoProfile -ExecutionPolicy Bypass -File "!HERE!diagnose-dcc-cmdline.ps1" -LogPath "!LOG!"
goto :done

:try_version
if defined RSVARS exit /b 0
set "CAND=%ProgramFiles(x86)%\Embarcadero\Studio\%~1\bin\rsvars.bat"
if exist "!CAND!" set "RSVARS=!CAND!"
exit /b 0

:no_rsvars
echo ERROR: rsvars.bat not found. Set DELPHI_ROOT and retry.
exit /b 2

:no_project
echo ERROR: no project "!PROJNAME!.dproj" under !ROOT!\samples\.
exit /b 2

:no_log
echo ERROR: msbuild produced no log at !LOG!.
exit /b 2

:done
echo.
echo Share the summary above, not dcc-diag.log itself.
exit /b 0
