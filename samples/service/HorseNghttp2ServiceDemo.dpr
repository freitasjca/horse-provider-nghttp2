program HorseNghttp2ServiceDemo;

// ============================================================================
//  Windows Service demo for horse-provider-nghttp2.
//
//  Selects HORSE_PROVIDER_NGHTTP2 + HORSE_APPTYPE_DAEMON on Delphi/Windows,
//  which routes to Horse.Provider.Nghttp2.Daemon ? THorseNghttp2Service
//  (Vcl.SvcMgr.TService base with worker-thread Listen).
//
//  Build (Windows):
//    Delphi IDE ? open .dpr ? Project ? Build (produces .exe)
//
//  Install / start / stop / uninstall (admin CMD):
//    HorseNghttp2ServiceDemo.exe /install
//    sc start HorseNghttp2Demo
//    sc query HorseNghttp2Demo         ? STATE = RUNNING
//    curl --http2-prior-knowledge http://127.0.0.1:9200/ping
//    sc stop HorseNghttp2Demo
//    HorseNghttp2ServiceDemo.exe /uninstall
//
//  Full docs: see README.md next to this file.
// ============================================================================

{$DEFINE HORSE_PROVIDER_NGHTTP2}
{$DEFINE HORSE_APPTYPE_DAEMON}

uses
  Vcl.SvcMgr,
  DemoService in 'DemoService.pas' {HorseDemoSvc: TService},
  Nghttp2.Types in '..\..\..\Delphi-nghttp2\src\Nghttp2.Types.pas',
  Nghttp2.Tls in '..\..\..\Delphi-nghttp2\src\Nghttp2.Tls.pas',
  Nghttp2.Socket in '..\..\..\Delphi-nghttp2\src\Nghttp2.Socket.pas',
  Nghttp2.Session in '..\..\..\Delphi-nghttp2\src\Nghttp2.Session.pas',
  Nghttp2.Server in '..\..\..\Delphi-nghttp2\src\Nghttp2.Server.pas',
  Nghttp2.OpenSSL in '..\..\..\Delphi-nghttp2\src\Nghttp2.OpenSSL.pas',
  Nghttp2.Native in '..\..\..\Delphi-nghttp2\src\Nghttp2.Native.pas';

{$R *.res}

begin
  if not Vcl.SvcMgr.Application.DelayInitialize or Vcl.SvcMgr.Application.Installing then
    Vcl.SvcMgr.Application.Initialize;
  Vcl.SvcMgr.Application.CreateForm(THorseDemoSvc, HorseDemoSvc);
  Vcl.SvcMgr.Application.Run;
end.
