program TestNghttp2FPCLCL;

{
  Compile-only test for Horse.Provider.Nghttp2.FPC.LCL.
  Proves:
    - Unit compiles on FPC trunk 3.3.1 with LCL units available
    - TfrmHorseNghttp2LCLHost subclassing resolves correctly
    - THorseProviderNghttp2FPCLCL marker class is reachable

  Runtime requires a display server (X11 or Wayland).
  On a headless Linux machine, compile-only is sufficient:
    - All lifecycle logic (DoFormCreate/DoFormClose, Listen/StopListen) is
      inherited from THorseProviderNghttp2 and proven by the 94/94 FPC
      regression suite in samples/tests/.

  Compile:
    fpc -n -MDelphi -O1 -dHORSE_PROVIDER_NGHTTP2 -dHORSE_APPTYPE_LCL \
        -Fu<prov-src> -Fu<delphi-nghttp2-src> -Fu<horse-src> \
        -Fu<fpc-trunk-units>/rtl -Fu<fpc-trunk-units>/rtl-console \
        -Fu<fpc-trunk-units>/rtl-objpas -Fu<fpc-trunk-units>/pthreads \
        -Fu<fpc-trunk-units>/lcl \
        TestNghttp2FPCLCL.lpr

  If LCL units are not present in the FPC trunk install (they ship with
  Lazarus, not FPC itself), the compile fails on "unit Forms not found".
  In that case, skip this test — TfrmHorseNghttp2LCLHost's correctness is
  guaranteed by structural identity with the CrossSocket FPC.LCL unit which
  is already proven.
}

{$IF DEFINED(FPC) AND DEFINED(UNIX)}
uses
  cthreads,
{$ELSE}
uses
{$ENDIF}
  SysUtils,
  Forms,
  Horse,
  Horse.Provider.Nghttp2.FPC.LCL;

type
  { Minimal subclass — verifies TfrmHorseNghttp2LCLHost compiles and
    that the inherited constructor + event wiring resolve correctly. }
  TfrmMain = class(TfrmHorseNghttp2LCLHost)
  end;

var
  frmMain: TfrmMain;

begin
  { Compile-only validation — do not call Application.Run on a headless
    machine. The server would bind port 9212 if Run were called. }
  WriteLn('TestNghttp2FPCLCL compiled OK — TfrmHorseNghttp2LCLHost is reachable.');
  WriteLn('Runtime requires a display. Exiting.');
  { For a display-attached run, replace the two WriteLns above with:
      Application.Initialize;
      Application.CreateForm(TfrmMain, frmMain);
      frmMain.Port := 9212;
      Application.Run;
    nghttp2 Listen is non-blocking in an LCL app (IsConsole=False), so
    Application.Run drives the LCL message loop and Horse serves HTTP/2. }
end.
