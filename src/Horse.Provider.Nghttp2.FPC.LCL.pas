unit Horse.Provider.Nghttp2.FPC.LCL;

{
  Horse nghttp2 Provider — FPC / Lazarus LCL composition
  =======================================================

  Selects the nghttp2 transport for a Lazarus LCL GUI application. The
  THorseProviderNghttp2FPCLCL class is the THorseProvider alias resolved
  by Horse.pas when HORSE_PROVIDER_NGHTTP2 + HORSE_APPTYPE_LCL are both
  defined.

  nghttp2's Listen is non-blocking when IsConsole = False (which is true
  in an LCL Forms application), so calling THorse.Listen from FormCreate
  starts the IO threads and returns immediately, leaving the LCL message
  loop free.

  TfrmHorseNghttp2LCLHost is an optional convenience base class — the
  Lazarus counterpart of TfrmHorseNghttp2VCLHost. Users can inherit from
  it instead of writing the wiring by hand.

  Mirrors Horse.Provider.CrossSocket.FPC.LCL line-for-line so the two
  providers are interchangeable from the developer-experience angle.
}

{$MODE DELPHI}{$H+}

interface

uses
  SysUtils,
  Classes,
  Forms,
  Horse.Provider.Nghttp2;

type
  { Marker subclass — Horse.pas's THorseProvider alias resolves here when
    HORSE_PROVIDER_NGHTTP2 + HORSE_APPTYPE_LCL are defined. }
  THorseProviderNghttp2FPCLCL = class(THorseProviderNghttp2);

  { Optional convenience LCL form base class. Mirror of the Delphi VCL
    counterpart (TfrmHorseNghttp2VCLHost). Users may inherit:

      type TfrmMain = class(TfrmHorseNghttp2LCLHost)
        // declare routes in OnHorseListen, FormCreate override, etc.
      end;

    or ignore this class entirely and call THorse.Listen / .StopListen from
    their own FormCreate / FormClose. }
  TfrmHorseNghttp2LCLHost = class(TForm)
  private
    FPort:          Integer;
    FAutoStart:     Boolean;
    FOnHorseListen: TNotifyEvent;
    FListening:     Boolean;
    procedure DoFormCreate(Sender: TObject);
    procedure DoFormClose(Sender: TObject; var CloseAction: TCloseAction);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor  Destroy; override;
    { Set this BEFORE Loaded fires (typically in the .lfm) so the
      auto-start uses the right port. Default 9200 matches
      TNghttp2Config.Default.Port. }
    property Port: Integer read FPort write FPort default 9200;
    { Set False to suppress the auto Listen in FormCreate — useful if the
      app needs to register routes asynchronously before binding. }
    property AutoStart: Boolean read FAutoStart write FAutoStart default True;
    { Fires AFTER routes are auto-registered (if AutoStart) and BEFORE
      THorse.Listen returns. }
    property OnHorseListen: TNotifyEvent read FOnHorseListen write FOnHorseListen;
  end;

implementation

uses
  Horse;

{ TfrmHorseNghttp2LCLHost }

constructor TfrmHorseNghttp2LCLHost.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FPort      := 9200;   // matches TNghttp2Config.Default.Port
  FAutoStart := True;
  OnCreate := @DoFormCreate;
  OnClose  := @DoFormClose;
end;

destructor TfrmHorseNghttp2LCLHost.Destroy;
begin
  if FListening then
    THorse.StopListen;
  inherited;
end;

procedure TfrmHorseNghttp2LCLHost.DoFormCreate(Sender: TObject);
begin
  if not FAutoStart then Exit;
  if Assigned(FOnHorseListen) then
    FOnHorseListen(Self);
  THorse.Listen(FPort);   // non-blocking in an LCL app (IsConsole = False)
  FListening := True;
end;

procedure TfrmHorseNghttp2LCLHost.DoFormClose(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  if FListening then
  begin
    THorse.StopListen;    // graceful drain via SEC-30 active-request counter
    FListening := False;
  end;
end;

end.
