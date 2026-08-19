@echo off
REM ===========================================================================
REM  msbuild-shell.bat
REM  Open an interactive command prompt with the Delphi build environment
REM  loaded, for ad-hoc msbuild / dcc64 commands.
REM
REM  Usage:
REM    msbuild-shell.bat
REM
REM  Then, inside the new prompt:
REM    msbuild samples\tests\HorseNghttp2TestServer.dproj /t:Build /p:Config=Release /p:Platform=Win64
REM    dcc64 -B src\Horse.Provider.Nghttp2.pas
REM
REM  Why this exists as its own script rather than a "load the environment"
REM  helper the other scripts call:
REM
REM    rsvars.bat sets variables in the CURRENT shell. A helper .bat that
REM    wraps it in setlocal loses them at endlocal, and exporting them back
REM    out requires the `for %%A in ("!X!") do endlocal & set "X=%%~A"` dance
REM    for every single variable rsvars touches - fragile, and it silently
REM    drops any variable you forget. So build-msbuild.bat locates and calls
REM    rsvars itself (self-contained, same as build-linux64.bat), and this
REM    script sidesteps the problem entirely by SPAWNING a new shell that
REM    inherits the environment instead of trying to export it upward.
REM
REM  Override discovery:
REM    set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
REM
REM  No parenthesised blocks anywhere - Delphi's path contains "(x86)" and cmd
REM  matches parens before expanding variables. See build-msbuild.bat's header.
REM ===========================================================================
setlocal enabledelayedexpansion

set "RSVARS="
if not "!DELPHI_ROOT!"=="" if exist "!DELPHI_ROOT!\bin\rsvars.bat" set "RSVARS=!DELPHI_ROOT!\bin\rsvars.bat"
if not "!BDS!"==""         if exist "!BDS!\bin\rsvars.bat"         set "RSVARS=!BDS!\bin\rsvars.bat"

for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V

if not defined RSVARS goto :no_rsvars

set "HERE=%~dp0"
for %%I in ("!HERE!..") do set "ROOT=%%~fI"

echo Loading: !RSVARS!
echo Root:    !ROOT!
echo.
echo Type "exit" to leave this shell.
echo.

REM /k keeps the new shell open. Everything after it runs inside that shell,
REM so rsvars' variables survive - which is the whole point of this script.
REM
REM Quoting: cmd /k "..." strips the OUTER pair of quotes and passes the rest
REM through, so the inner quotes around the two paths survive. Kept to two
REM simple commands joined by && - pipes and redirections inside a /k string
REM need further escaping and are not worth the risk here.
cmd /k "call "!RSVARS!" && cd /d "!ROOT!""

exit /b 0

:try_version
if defined RSVARS exit /b 0
set "CAND=%ProgramFiles(x86)%\Embarcadero\Studio\%~1\bin\rsvars.bat"
if exist "!CAND!" set "RSVARS=!CAND!"
exit /b 0

:no_rsvars
echo ERROR: rsvars.bat not found.
echo        Looked at DELPHI_ROOT, BDS, and Studio 23.0/22.0/21.0/20.0/19.0
echo        under "%ProgramFiles(x86)%\Embarcadero".
echo.
echo        Set it explicitly:
echo            set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
exit /b 2
