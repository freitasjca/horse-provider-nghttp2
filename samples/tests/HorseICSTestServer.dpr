program HorseICSTestServer;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_ICS}

{
  Horse + OverbyteICS  —  Integration Test Server
  ================================================
  Routes are identical to HorseCSTestServer.dpr so the shared, provider-
  neutral HorseCSTestClient can drive both providers without modification.

  Run this program first (Windows + Delphi only — ICS provider is v1
  Windows-locked), then run HorseCSTestClient.

  Routes exercised by the client test suite — same set as the CrossSocket
  and mORMot test servers; see HorseCSTestServer.dpr for the rationale per
  route.
}

uses
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
  Horse,
  Horse.Commons,
  Horse.Provider.ICS,
  Horse.Core.Param,
  Horse.Core.Param.Field;

const
  TEST_PORT           = 9010;
  LARGE_RESPONSE_SIZE = 65536;

function JE(const S: string): string;
begin
  Result := StringReplace(S,  '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

function JB(const B: Boolean): string;
begin
  if B then Result := 'true' else Result := 'false';
end;

procedure RegisterRoutes;
begin
  // Health
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send('pong');
    end);

  // Method probes
  THorse.Get('/methods/get',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"method":"GET"}');
    end);

  THorse.Post('/methods/post',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"POST","body":"%s"}', [JE(Req.Body)]));
    end);

  THorse.Put('/methods/put/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PUT","id":"%s"}', [JE(Req.Params['id'])]));
    end);

  THorse.Delete('/methods/delete/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"DELETE","id":"%s"}', [JE(Req.Params['id'])]));
    end);

  THorse.Patch('/methods/patch/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PATCH","id":"%s"}', [JE(Req.Params['id'])]));
    end);

  THorse.Head('/methods/head',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.AddHeader('X-Head-Ok', 'true');
    end);

  // Params
  THorse.Get('/params/path/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"id":"%s"}', [JE(Req.Params['id'])]));
    end);

  THorse.Get('/params/query',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"name":"%s","value":"%s"}',
           [JE(Req.Query['name']), JE(Req.Query['value'])]));
    end);

  THorse.Get('/params/multi/:a/:b',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"a":"%s","b":"%s"}',
           [JE(Req.Params['a']), JE(Req.Params['b'])]));
    end);

  // Cookies
  THorse.Get('/cookies/set',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.AddHeader('Set-Cookie', 'session=abc123; Path=/');
      Res.AddHeader('Set-Cookie', 'user=tester; Path=/');
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"status":"cookies set"}');
    end);

  THorse.Get('/cookies/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"session":"%s","user":"%s"}',
           [JE(Req.Cookie['session']), JE(Req.Cookie['user'])]));
    end);

  // Upload — v1 ICS provider does not implement multipart decoding; this
  // route still answers but returns size=0 when ICS is the transport.
  // The shared test client tolerates a structured failure here.
  THorse.Post('/upload',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LStream: TStream;
      LName:   string;
    begin
      LStream := Req.ContentFields.Field('file').AsStream;
      LName   := Req.ContentFields['fieldname'];
      if Assigned(LStream) then
        Res.ContentType('application/json; charset=utf-8')
           .Send(Format('{"received":true,"name":"%s","size":%d}',
             [JE(LName), LStream.Size]))
      else
        Res.Status(THTTPStatus.BadRequest)
           .ContentType('application/json; charset=utf-8')
           .Send('{"received":false,"error":"no file field"}');
    end);

  THorse.Get('/download',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8')
         .AddHeader('Content-Disposition', 'attachment; filename="testfile.txt"')
         .Send('Hello from Horse CrossSocket test download!');
    end);

  THorse.Get('/headers/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"X-Test-Header":"%s"}',
           [JE(Req.Headers['X-Test-Header'])]));
    end);

  THorse.Post('/echo/body',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: string;
    begin
      LBody := Req.Body;
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"body":"%s","size":%d}',
           [JE(LBody), Length(TEncoding.UTF8.GetBytes(LBody))]));
    end);

  THorse.Get('/status/:code',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LCode: Integer;
    begin
      LCode := StrToIntDef(Req.Params['code'], 200);
      if (LCode < 100) or (LCode > 599) then
        LCode := 400;
      Res.ContentType('application/json; charset=utf-8')
         .Status(LCode)
         .Send(Format('{"status":%d}', [LCode]));
    end);

  THorse.Get('/response/large',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8')
         .Send(StringOfChar('X', LARGE_RESPONSE_SIZE));
    end);

  // RawWebRequest adapter probe
  THorse.Get('/raw/webrequest',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TWebRequest;
    begin
      LRaw := Req.RawWebRequest;
      if not Assigned(LRaw) then
      begin
        Res.ContentType('application/json; charset=utf-8').Status(500)
           .Send('{"hasAdapter":false,"error":"RawWebRequest is nil"}');
        Exit;
      end;
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format(
           '{"hasAdapter":true,"method":"%s","host":"%s","pathInfo":"%s",'
         + '"customHeader":"%s","remoteAddrNonEmpty":%s}',
           [JE(LRaw.Method),
            JE(LRaw.Host),
            JE(LRaw.PathInfo),
            JE(LRaw.GetFieldByName('X-Test-Header')),
            JB(LRaw.RemoteAddr <> '')]));
    end);

  // CORS-style route
  THorse.All('/raw/cors',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw:    TWebRequest;
      LMethod: string;
    begin
      LRaw := Req.RawWebRequest;
      if not Assigned(LRaw) then
      begin
        Res.ContentType('text/plain').Status(500).Send('raw-cors:nil-adapter');
        Exit;
      end;
      LMethod := LRaw.Method;
      if SameText(LMethod, 'OPTIONS') then
      begin
        Res.AddHeader('Access-Control-Allow-Origin',  '*');
        Res.AddHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
        Res.ContentType('text/plain').Status(THTTPStatus.NoContent).Send('');
        Exit;
      end;
      Res.ContentType('text/plain').Send('cors-route:' + LMethod);
    end);

  // RawWebResponse adapter probe
  THorse.Get('/raw/webresponse',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TWebResponse;
    begin
      LRaw := Res.RawWebResponse;
      if not Assigned(LRaw) then
      begin
        Res.ContentType('application/json; charset=utf-8').Status(500)
           .Send('{"hasAdapter":false,"error":"RawWebResponse is nil"}');
        Exit;
      end;
      LRaw.SetCustomHeader('X-Via-RawResponse', 'PATCH-RES-6-OK');
      Res.AddHeader('X-Via-AddHeader', 'AddHeader-OK');
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"hasAdapter":true}');
    end);

  // PATCH-REQ-9 double-read
  THorse.Post('/echo/body-twice',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LFirst, LSecond: string;
    begin
      LFirst  := Req.Body;
      LSecond := Req.Body;
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"first":"%s","second":"%s","equal":%s}',
           [JE(LFirst), JE(LSecond), JB(LFirst = LSecond)]));
    end);

  // COMPAT-1
  THorse.Get('/compat/rawbody',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TWebResponse;
    begin
      LRaw := Res.RawWebResponse;
      if Assigned(LRaw) then
        LRaw.Content := 'raw-should-not-appear';
      Res.ContentType('text/plain; charset=utf-8')
         .Send('shadow-wins');
    end);

  // Worker pool burst
  THorse.Post('/pool/burst',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: string;
    begin
      LBody := Req.Body;
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"body":"%s","size":%d}',
           [JE(LBody), Length(TEncoding.UTF8.GetBytes(LBody))]));
    end);

  // Streaming — ICS v1 does not support pull-model chunked streaming.
  // 501 stubs let a shared test client probe capability without hanging.
  THorse.Get('/stream/pull',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Status(501).ContentType('application/json; charset=utf-8')
         .Send('{"error":"chunked streaming not implemented on ICS transport"}');
    end);

  THorse.Get('/stream/content-type',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Status(501).ContentType('application/json; charset=utf-8')
         .Send('{"error":"chunked streaming not implemented on ICS transport"}');
    end);

  THorse.Get('/stream/empty',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Status(501).ContentType('application/json; charset=utf-8')
         .Send('{"error":"chunked streaming not implemented on ICS transport"}');
    end);
end;

begin
  try
    RegisterRoutes;
    THorseProviderICS.Listen(TEST_PORT);
    Writeln(Format('[HorseICSTest] Server listening on http://127.0.0.1:%d  [OverbyteICS]',
      [TEST_PORT]));
    Writeln('[HorseICSTest] Run HorseCSTestClient to execute the test suite.');
    Writeln('[HorseICSTest] Press ENTER to stop...');
    Readln;
    THorseProviderICS.Stop;
    Writeln('[HorseICSTest] Server stopped.');
  except
    on E: Exception do
    begin
      Writeln('[HorseICSTest] Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
