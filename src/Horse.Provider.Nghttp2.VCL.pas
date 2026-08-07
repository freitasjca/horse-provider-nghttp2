unit Horse.Provider.Nghttp2.VCL;

{
  Horse nghttp2 Provider — Delphi VCL composition
  ================================================

  Selects the nghttp2 transport for a VCL Forms application. The
  THorseProviderNghttp2VCL class is the THorseProvider alias resolved by
  Horse.pas when HORSE_PROVIDER_NGHTTP2 + HORSE_APPTYPE_VCL are both
  defined.

  Rationale: nghttp2's accept-loop thread is spawned inside
  THorseProviderNghttp2.InternalListen and only BLOCKS the calling thread
  when IsConsole = True. In a VCL Forms app IsConsole is False, so
  THorse.Listen from FormCreate starts the IO thread(s) and returns
  immediately, leaving the VCL message loop free to run.

  TfrmHorseNghttp2VCLHost is an optional convenience base class that
  pre-wires FormCreate / FormClose to THorse.Listen / THorse.StopListen
  with a configurable Port property. Users can inherit from it instead of
  writing the wiring by hand. Mirrors horse-provider-crosssocket's
  TfrmHorseVCLHost line-for-line so the two providers are interchangeable
  from the developer-experience angle.
}

interface

uses
  System.SysUtils,
  System.Classes,
  Vcl.Forms,
  Horse.Provider.Nghttp2;

type
  { Marker subclass — Horse.pas's THorseProvider alias resolves here when
    HORSE_PROVIDER_NGHTTP2 + HORSE_APPTYPE_VCL are defined. Inherits all
    transport behaviour from THorseProviderNghttp2; the VCL aspect is
    expressed in the lifecycle helper class below, not in this class. }
  THorseProviderNghttp2VCL = class(THorseProviderNghttp2);

  { Optional convenience form base class for VCL apps. Users may inherit:

      type TfrmMain = class(TfrmHorseNghttp2VCLHost)
        // declare routes in OnHorseListen, OnFormCreate, etc.
      end;

    or ignore this class entirely and call THorse.Listen / .StopListen from
    their own FormCreate / FormClose. The class adds no new state beyond
    Port + the auto-wired event. }
  TfrmHorseNghttp2VCLHost = class(TForm)
  private
    FPort:          Integer;
    FAutoStart:     Boolean;
    FOnHorseListen: TNotifyEvent;
    FListening:     Boolean;
    procedure DoFormCreate(Sender: TObject);
    procedure DoFormClose(Sender: TObject; var Action: TCloseAction);
  protected
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    { Set this BEFORE Loaded fires (typically in the .dfm or in an override
      of Create) so the auto-start uses the right port. Default 9200 matches
      THorseNghttp2Config.Default.Port. }
    property Port: Integer read FPort write FPort default 9200;
    { Set False to suppress the auto Listen in FormCreate — useful if the
      app needs to register routes asynchronously before binding. }
    property AutoStart: Boolean read FAutoStart write FAutoStart default True;
    { Fires BEFORE THorse.Listen is called. Use this to register routes and
      middleware — anything set here is live from the very first request. }
    property OnHorseListen: TNotifyEvent read FOnHorseListen write FOnHorseListen;
  end;

implementation

uses
  Horse;

{ TfrmHorseNghttp2VCLHost }

constructor TfrmHorseNghttp2VCLHost.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPort      := 9200;   // matches THorseNghttp2Config.Default.Port
  FAutoStart := True;
  OnCreate := DoFormCreate;
  OnClose  := DoFormClose;
end;

destructor TfrmHorseNghttp2VCLHost.Destroy;
begin
  // Belt-and-braces — DoFormClose already ran in the normal path, but if
  // the app is being torn down without a proper Close (e.g. Application
  // termination), this guarantees the server drains and joins.
  if FListening then
    THorse.StopListen;
  inherited;
end;

procedure TfrmHorseNghttp2VCLHost.Loaded;
begin
  inherited;
  // Loaded runs after the .dfm has streamed in, so Port carries the
  // .dfm-set value by now. Nothing to do here — DoFormCreate handles the
  // actual Listen call.
end;

procedure TfrmHorseNghttp2VCLHost.DoFormCreate(Sender: TObject);
begin
  if not FAutoStart then Exit;
  if Assigned(FOnHorseListen) then
    FOnHorseListen(Self);
  // Non-blocking in a VCL app (IsConsole = False). THorseProviderNghttp2's
  // InternalListen skips the "block on FStopEvent" branch and returns
  // immediately after the accept thread starts.
  THorse.Listen(FPort);
  FListening := True;
end;

procedure TfrmHorseNghttp2VCLHost.DoFormClose(Sender: TObject; var Action: TCloseAction);
begin
  if FListening then
  begin
    // Graceful drain via SEC-30 active-request counter (see
    // THorseProviderNghttp2.StopListenGraceful for the polling detail).
    // Plain StopListen still walks the same teardown path just without a
    // caller-supplied timeout.
    THorse.StopListen;
    FListening := False;
  end;
end;

end.
