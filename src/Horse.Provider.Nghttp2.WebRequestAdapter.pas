unit Horse.Provider.Nghttp2.WebRequestAdapter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.WebRequestAdapter
//  Thin TWebRequest-compatible subclass. The heavy lifting (all 30+ abstract
//  method stubs) is inherited from TInterfacedWebRequest via delegation to
//  IHorseRawRequest. This unit exists only so consumers get a single-call
//  constructor and don't need to know about the interface indirection.
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
  Horse.Provider.Nghttp2.RawRequest;

type
  TNghttp2WebRequest = class(TInterfacedWebRequest)
  public
    constructor Create(const AStream: INghttp2Stream); reintroduce;
  end;

implementation

constructor TNghttp2WebRequest.Create(const AStream: INghttp2Stream);
begin
  inherited Create(TNghttp2RawRequest.Create(AStream));
end;

end.
