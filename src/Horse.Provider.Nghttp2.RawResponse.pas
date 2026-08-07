unit Horse.Provider.Nghttp2.RawResponse;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.RawResponse
//  IHorseRawResponse implementation wrapping one HTTP/2 stream.
//
//  Most response state flows through TInterfacedWebResponse.CustomHeaders +
//  THorseResponse shadow fields — the response bridge reads them at flush
//  time. SetCustomHeader is only intercepted here for middleware (like
//  Horse.CORS) that writes headers directly on RawWebResponse.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  Horse.Provider.RawInterfaces,
  Nghttp2.Types;

type
  TNghttp2RawResponse = class(TInterfacedObject, IHorseRawResponse)
  private
    FStream: INghttp2Stream;
  public
    constructor Create(const AStream: INghttp2Stream);
    procedure SetCustomHeader(const AName, AValue: string);
  end;

implementation

constructor TNghttp2RawResponse.Create(const AStream: INghttp2Stream);
begin
  inherited Create;
  FStream := AStream;
end;

procedure TNghttp2RawResponse.SetCustomHeader(const AName, AValue: string);
begin
  // Mirror the header into the stream so middleware that writes to
  // Res.RawWebResponse.SetCustomHeader (e.g. Horse.CORS) reaches the wire.
  // TInterfacedWebResponse's own CustomHeaders: TStrings still holds the
  // value; ResponseBridge.Flush dedups when it iterates CustomHeaders.
  if Assigned(FStream) then
    FStream.Header[LowerCase(AName)] := AValue;
end;

end.
