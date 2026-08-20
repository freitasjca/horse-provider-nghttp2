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
  { STREAM-1. Lets the stream writer reach the underlying HTTP/2 stream from
    the IHorseRawResponse it is handed.

    A separate interface rather than a cast: RawRes is typed as
    IHorseRawResponse, and going from an interface reference back to the
    implementing class is not portable between Delphi and FPC. Supports() is,
    and it also answers "is this actually the nghttp2 provider?" in the same
    step — which the writer needs, because the factory is global. }
  INghttp2StreamAccess = interface
    ['{2A7C4E91-5B3D-4F6A-9C8E-7D1B0F3A5C24}']
    function GetNghttp2Stream: INghttp2Stream;
  end;

  TNghttp2RawResponse = class(TInterfacedObject, IHorseRawResponse,
                              INghttp2StreamAccess)
  private
    FStream: INghttp2Stream;
  public
    constructor Create(const AStream: INghttp2Stream);
    procedure SetCustomHeader(const AName, AValue: string);
    function GetNghttp2Stream: INghttp2Stream;
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

function TNghttp2RawResponse.GetNghttp2Stream: INghttp2Stream;
begin
  Result := FStream;
end;

end.
