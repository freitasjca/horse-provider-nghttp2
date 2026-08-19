unit Sample.Greeter.Messages;

// ============================================================================
//  Sample.Greeter.Messages — proto3 message classes for the M4b demo.
//
//  Wire-tag stability lives in [TProtoMember(N)] attributes; Delphi property
//  names may differ from the .proto field names when reserved words collide
//  (e.g. proto "message" → Delphi "text" — same tag=1 on the wire).
//
//  RTTI rules per horse/.agents/skills/horse-grpc/SKILL.md §1:
//    - {$M+} unit-wide so classes carry classic RTTI
//    - all serialisable fields in `published` (private-storage / public
//      properties get no offset info → AV in TRttiProperty.SetValue)
// ============================================================================

{$M+}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

// FPC needs explicit extended-RTTI directive alongside {$M+} — otherwise
// TRttiType.GetProperties returns 0 (see delphi-fpc-compat). Directive must
// live INSIDE `interface`, not above it (FPC rejects it at unit-scope).
{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

uses
  Nghttp2.Protobuf;   // TGrpcMessageAttribute + TProtoMemberAttribute

type
  [TGrpcMessage]
  TGreetRequest = class
  private
    Fname: string;
  published
    [TProtoMember(1)]
    property name: string read Fname write Fname;
  end;

  [TGrpcMessage]
  TGreetResponse = class
  private
    Ftext: string;
  published
    { proto3: string message = 1; renamed to `text` in Delphi because
      `message` is a directive keyword. Wire tag is what matters. }
    [TProtoMember(1)]
    property text: string read Ftext write Ftext;
  end;

  [TGrpcMessage]
  TEchoRequest = class
  private
    Fi32: Integer;
    Fi64: Int64;
    Fb:   Boolean;
    Fs:   string;
    Ff32: Single;
    Ff64: Double;
  published
    [TProtoMember(1)] property i32: Integer read Fi32 write Fi32;
    [TProtoMember(2)] property i64: Int64   read Fi64 write Fi64;
    [TProtoMember(3)] property b:   Boolean read Fb   write Fb;
    [TProtoMember(4)] property s:   string  read Fs   write Fs;
    [TProtoMember(5)] property f32: Single  read Ff32 write Ff32;
    [TProtoMember(6)] property f64: Double  read Ff64 write Ff64;
  end;

  [TGrpcMessage]
  TEchoResponse = class
  private
    Fi32: Integer;
    Fi64: Int64;
    Fb:   Boolean;
    Fs:   string;
    Ff32: Single;
    Ff64: Double;
  published
    [TProtoMember(1)] property i32: Integer read Fi32 write Fi32;
    [TProtoMember(2)] property i64: Int64   read Fi64 write Fi64;
    [TProtoMember(3)] property b:   Boolean read Fb   write Fb;
    [TProtoMember(4)] property s:   string  read Fs   write Fs;
    [TProtoMember(5)] property f32: Single  read Ff32 write Ff32;
    [TProtoMember(6)] property f64: Double  read Ff64 write Ff64;
  end;

implementation

end.
