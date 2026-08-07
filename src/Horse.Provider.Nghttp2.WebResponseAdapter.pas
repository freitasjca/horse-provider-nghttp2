unit Horse.Provider.Nghttp2.WebResponseAdapter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.WebResponseAdapter
//  Thin TWebResponse-compatible subclass. See WebRequestAdapter for rationale.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, fpHTTP, HTTPDefs,
{$ELSE}
  System.SysUtils, System.Classes, Web.HTTPApp,
{$ENDIF}
  Horse.Provider.RawAdapters,
  Nghttp2.Types,
  Horse.Provider.Nghttp2.RawResponse;

type
  TNghttp2WebResponse = class(TInterfacedWebResponse)
  public
    constructor Create(const AStream: INghttp2Stream); reintroduce;
  end;

implementation

constructor TNghttp2WebResponse.Create(const AStream: INghttp2Stream);
begin
  inherited Create(TNghttp2RawResponse.Create(AStream));
end;

end.
