{
 WCHTTP2Server:
   Classes and other routings to deal with HTTP2 connections,
   frames and streams
   plus cross-protocols conversions HTTP2 <-> HTTP1.1 for
   fpHTTP/fpweb compability

   Part of WCHTTPServer project

   Copyright (c) 2020-2021 by Ilya Medvedkov

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
}

unit wchttp2server;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$ifdef linux}
{epoll mode appeared thanks to the lNet project
 CopyRight (C) 2004-2008 Ales Katona}
{$define socket_epoll_mode}
{.$define socket_select_mode}
{$else}
{$define socket_select_mode}
{$endif}

interface

uses
  Classes, SysUtils,
  ECommonObjs, OGLFastList,
  fphttp, HTTPDefs, httpprotocol, abstracthttpserver,
  BufferedStream,
  ssockets,
  sockets,
  {$ifdef unix}
    BaseUnix,Unix,
  {$endif}
  {$ifdef linux}{$ifdef socket_epoll_mode}
    Linux,
  {$endif}{$endif}
  {$ifdef windows}
    winsock2, windows,
  {$endif}
  {$ifdef DEBUG}
  debug_vars,
  {$endif}
  uhpack,
  http2consts,
  http2http1conv;

const
  WC_INITIAL_READ_BUFFER_SIZE = 4096;

type

  TWCHTTPStreams = class;
  TWCHTTPRefConnection = class;
  TWCHTTP2Connection = class;
  TWCHTTPRefConnections = class;
  TWCHTTPStream = class;

  TWCConnectionState = (wcCONNECTED, wcDROPPED, wcDEAD);
  TWCProtocolVersion = (wcUNK, wcHTTP1, wcHTTP1_1, wcHTTP2);

  { TWCHTTP2FrameHeader }

  TWCHTTP2FrameHeader = class
  public
    PayloadLength : Integer; //24 bit
    FrameType : Byte;
    FrameFlag : Byte;
    StreamID  : Cardinal;
    Reserved  : Byte;
    procedure LoadFromStream(Str : TStream);
    procedure SaveToStream(Str : TStream);
  end;

  { TWCHTTPRefProtoFrame }

  TWCHTTPRefProtoFrame = class
  public
    procedure SaveToStream(Str : TStream); virtual; abstract;
    function Size : Int64; virtual; abstract;
  end;

  { TWCHTTPStringFrame }

  TWCHTTPStringFrame = class(TWCHTTPRefProtoFrame)
  private
    FStr : String;
  public
    constructor Create(const S : String);
    procedure SaveToStream(Str : TStream); override;
    function Size : Int64; override;
  end;

  { TWCHTTPStringsFrame }

  TWCHTTPStringsFrame = class(TWCHTTPRefProtoFrame)
  private
    Strm : TMemoryStream;
  public
    constructor Create(Strs : TStrings);
    destructor Destroy; override;
    procedure SaveToStream(Str : TStream); override;
    function Size : Int64; override;
  end;

  { TWCHTTPStreamFrame }

  TWCHTTPStreamFrame = class(TWCHTTPRefProtoFrame)
  private
    FStrm : TStream;
  public
    constructor Create(Strm: TStream; Sz: Cardinal; Owned: Boolean);
    destructor Destroy; override;
    procedure SaveToStream(Str : TStream); override;
    function Size : Int64; override;
  end;

  { TWCHTTPRefStreamFrame }

  TWCHTTPRefStreamFrame = class(TWCHTTPRefProtoFrame)
  private
    FStrm : TReferencedStream;
    Fsz, Fpos : Int64;
  public
    constructor Create(Strm : TReferencedStream; Pos, Sz : Int64);
    constructor Create(Strm : TReferencedStream); overload;
    destructor Destroy; override;
    procedure SaveToStream(Str : TStream); override;
    function Size : Int64; override;
  end;

  TWCHTTP2Frame = class(TWCHTTPRefProtoFrame)
  public
    Header  : TWCHTTP2FrameHeader;
    constructor Create(aFrameType : Byte;
                       StrID : Cardinal;
                       aFrameFlags : Byte);
    destructor Destroy; override;
    procedure SaveToStream(Str : TStream); override;
    function Size : Int64; override;
  end;
  
  { TWCHTTP2DataFrame }
  
  TWCHTTP2DataFrame = class(TWCHTTP2Frame)
  public
    Payload : Pointer;
    OwnPayload : Boolean;
    constructor Create(aFrameType : Byte; 
                       StrID : Cardinal; 
                       aFrameFlags : Byte; 
                       aData : Pointer; 
                       aDataSize : Cardinal;
                       aOwnPayload : Boolean = True);
    destructor Destroy; override;
    procedure SaveToStream(Str : TStream); override;
  end;

  { TWCHTTP2RefFrame }

  TWCHTTP2RefFrame = class(TWCHTTP2Frame)
  public
    FStrm : TReferencedStream;
    Fpos : Int64;
    constructor Create(aFrameType : Byte;
                       StrID : Cardinal;
                       aFrameFlags : Byte;
                       aData : TReferencedStream;
                       aStrmPos : Int64;
                       aDataSize : Cardinal);
    destructor Destroy; override;
    procedure SaveToStream(Str : TStream); override;
  end;

  { TWCHTTP2AdvFrame }

  TWCHTTP2AdvFrame = class(TWCHTTPRefProtoFrame)
  public
    procedure SaveToStream(Str : TStream); override;
    function Size : Int64; override;
  end;

  { TWCHTTP2UpgradeResponseFrame }

  TWCHTTP2UpgradeResponseFrame = class(TWCHTTPRefProtoFrame)
  private
    FMode : THTTP2OpenMode;
  public
    constructor Create(Mode : THTTP2OpenMode);
    procedure SaveToStream(Str : TStream); override;
    function Size : Int64; override;
  end;

  { TWCHTTP2Block }

  TWCHTTP2Block = class
  private
    FCurDataBlock  : Pointer;
    FDataBlockSize : Integer;
    FConnection    : TWCHTTP2Connection;
    FStream        : TWCHTTPStream;
  public
    constructor Create(aConnection : TWCHTTP2Connection;
                       aStream : TWCHTTPStream); virtual;
    destructor Destroy; override;
    // avaible data
    procedure PushData(Data : Pointer; sz : Cardinal); overload;
    procedure PushData(Strm: TStream; startAt: Int64); overload;
    procedure PushData(Strings: TStrings); overload;
    property  DataBlock : Pointer read FCurDataBlock;
    property  DataBlockSize : Integer read FDataBlockSize;
  end;

  { TWCHTTP2SerializeStream }

  TWCHTTP2SerializeStream = class(TStream)
  private
    FConn  : TWCHTTP2Connection;
    FStrmID  : Cardinal;
    FCurFrame : TWCHTTP2DataFrame;
    FFirstFrameType, FNextFramesType : Byte;
    FFlags, FFinalFlags : Byte;
    FRestFrameSz : Longint;
    FChuncked : Boolean;
    FFirstFramePushed : Boolean;
  public
    constructor Create(aConn: TWCHTTP2Connection; aStrm: Cardinal;
                       aFirstFrameType : Byte;
                       aNextFramesType : Byte;
                       aFlags, aFinalFlags: Byte);
    function Write(const Buffer; Count: Longint): Longint; override;
    destructor Destroy; override;

    property FirstFrameType : Byte read FFirstFrameType write FFirstFrameType;
    property NextFramesType : Byte read FNextFramesType write FNextFramesType;
    property Flags : Byte read FFlags write FFlags;
    property FinalFlags : Byte read FFinalFlags write FFinalFlags;
    property Chuncked : Boolean read FChuncked write FChuncked;
  end;

  { TThreadSafeHPackEncoder }

  TThreadSafeHPackEncoder = class(TNetReferencedObject)
  private
    FEncoder : THPackEncoder;
  public
    constructor Create(TableSize : Cardinal);
    destructor Destroy; override;
    procedure EncodeHeader(aOutStream: TStream;
                       const aName: RawByteString;
                       const aValue: RawByteString; const aSensitive: Boolean);
  end;

  { TThreadSafeHPackDecoder }

  TThreadSafeHPackDecoder = class(TNetReferencedObject)
  private
    FDecoder : THPackDecoder;
    function GetDecodedHeaders: THPackHeaderTextList;
  public
    constructor Create(HeadersListSize, TableSize: Cardinal);
    destructor Destroy; override;
    procedure Decode(aStream: TStream);
    function  EndHeaderBlockTruncated: Boolean;
    property  DecodedHeaders: THPackHeaderTextList read GetDecodedHeaders;
  end;

  { TWCHTTP2ResponseHeaderPusher }

  TWCHTTP2ResponseHeaderPusher = class
  private
    FMem : TMemoryStream;
    FHPackEncoder : TThreadSafeHPackEncoder;
  protected
    property HPackEncoder : TThreadSafeHPackEncoder read FHPackEncoder write FHPackEncoder;
  public
    constructor Create(aHPackEncoder : TThreadSafeHPackEncoder);
    destructor Destroy; override;
    procedure PushHeader(const H, V : String); virtual; abstract;
    procedure PushAll(R: TResponse);
  end;

  { TWCHTTP2BufResponseHeaderPusher }

  TWCHTTP2BufResponseHeaderPusher = class(TWCHTTP2ResponseHeaderPusher)
  private
    FBuf : Pointer;
    FCapacity : Cardinal;
    FSize : Cardinal;
    FBufGrowValue : Cardinal;
  public
    constructor Create(aHPackEncoder : TThreadSafeHPackEncoder;
                       aBuffer : Pointer;
                       aBufferSize,
                       aBufGrowValue : Cardinal);
    procedure PushHeader(const H, V : String); override;
    property Buffer : Pointer read FBuf;
    property Size : Cardinal read FSize;
  end;

  { TWCHTTP2StrmResponseHeaderPusher }

  TWCHTTP2StrmResponseHeaderPusher = class(TWCHTTP2ResponseHeaderPusher)
  private
    FStrm : TStream;
  public
    constructor Create(aHPackEncoder : TThreadSafeHPackEncoder; aStrm : TStream);
    procedure PushHeader(const H, V : String); override;
  end;

  { TWCHTTP2Response }

  TWCHTTP2Response = class(TWCHTTP2Block)
  private
    FCurHeadersBlock : Pointer;
    FHeadersBlockSize : Longint;
  public
    constructor Create(aConnection : TWCHTTP2Connection;
                       aStream : TWCHTTPStream); override;
    destructor Destroy; override;
    procedure CopyFromHTTP1Response(R : TResponse);
    procedure Close;
    procedure SerializeResponse;
    procedure SerializeHeaders(closeStrm: Boolean);
    procedure SerializeData(closeStrm: Boolean);
    procedure SerializeResponseHeaders(R : TResponse; closeStrm: Boolean);
    procedure SerializeResponseData(R : TResponse; closeStrm: Boolean);
    procedure SerializeRefStream(R: TReferencedStream; closeStrm: Boolean);
  end;

  { TWCHTTP2Request }

  TWCHTTP2Request = class(TWCHTTP2Block)
  private
    FComplete : Boolean;
    FResponse : TWCHTTP2Response;
    FHeaders  : THPackHeaderTextList;
    function GetResponse: TWCHTTP2Response;
  public
    constructor Create(aConnection : TWCHTTP2Connection;
                       aStream : TWCHTTPStream); override;
    destructor Destroy; override;
    procedure CopyHeaders(aHPackDecoder : TThreadSafeHPackDecoder);
    procedure CopyToHTTP1Request(ARequest : TRequest);
    property  Response : TWCHTTP2Response read GetResponse;
    property  Complete : Boolean read FComplete write FComplete;
  end;

  { TWCHTTPStream }

  TWCHTTPStream = class(TNetReferencedObject)
  private
    FID : Cardinal;
    FConnection : TWCHTTP2Connection;
    FStreamState : THTTP2StreamState;
    FCurRequest : TWCHTTP2Request;
    FPriority : Byte;
    FRecursedPriority : ShortInt;
    FParentStream : Cardinal;
    FFinishedCode : Cardinal;
    FWaitingForContinueFrame : Boolean;
    FWaitingRemoteStream : Cardinal;
    FHeadersComplete : Boolean;
    FResponseProceed : Boolean;
    function GetRecursedPriority: Byte;
    function GetResponseProceed: Boolean;
    procedure ResetRecursivePriority;
    procedure PushRequest;
    procedure SetResponseProceed(AValue: Boolean);
    procedure SetWaitingForContinueFrame(AValue: Boolean);
    procedure UpdateState(Head : TWCHTTP2FrameHeader);
  protected
    property WaitingForContinueFrame : Boolean read FWaitingForContinueFrame write
                                         SetWaitingForContinueFrame;
    procedure PushData(Data : Pointer; sz : Cardinal);
    procedure FinishHeaders(aDecoder : TThreadSafeHPackDecoder);
  public
    constructor Create(aConnection : TWCHTTP2Connection; aStreamID : Cardinal);
    destructor Destroy; override;
    procedure Release;
    property ID : Cardinal read FID;
    property StreamState : THTTP2StreamState read FStreamState;
    property ParentStream : Cardinal read FParentStream;
    property Priority :  Byte read FPriority;
    property RecursedPriority : Byte read GetRecursedPriority;
    // avaible request
    function RequestReady : Boolean;
    property Request : TWCHTTP2Request read FCurRequest;
    property ResponseProceed : Boolean read GetResponseProceed write SetResponseProceed;
  end;

  TSocketState = (ssCanRead, ssCanSend, ssReading, ssSending, ssError);
  TSocketStates = set of TSocketState;

  { TWCHTTPSocketReference }

  TWCHTTPSocketReference = class(TNetReferencedObject)
  private
    {$ifdef socket_select_mode}
    FReadFDSet,
      FWriteFDSet,
      FErrorFDSet: PFDSet;
    FWaitTime : TTimeVal;
    {$endif}
    FSocket : TSocketStream;
    FSocketStates: TSocketStates;
  public
    constructor Create(aSocket : TSocketStream);
    destructor Destroy; override;

    {$ifdef socket_select_mode}
    procedure GetSocketStates;
    {$endif}
    procedure SetCanRead;
    procedure SetCanSend;
    procedure PushError;

    function  CanRead : Boolean;
    function  CanSend : Boolean;
    function  StartReading : Boolean;
    procedure StopReading;
    function  StartSending : Boolean;
    procedure StopSending;

    function Write(const Buffer; Size : Integer) : Integer;
    function Read(var Buffer; Size : Integer) : Integer;
    property Socket : TSocketStream read FSocket;
    property States : TSocketStates read FSocketStates;
  end;

  THttpRefSocketConsume = procedure (SockRef : TWCHTTPSocketReference) of object;
  THttpRefSendData = procedure (aConnection : TWCHTTPRefConnection) of object;

  { TWCHTTPConnection }

  TWCHTTPConnection = class(TAbsHTTPConnection)
  private
    FHTTPRefCon  : TWCHTTPRefConnection;
    FHTTP2Str  : TWCHTTPStream;
    FSocketRef : TWCHTTPSocketReference;
    procedure SetHTTPRefCon(AValue: TWCHTTPRefConnection);
    procedure SetHTTP2Stream(AValue: TWCHTTPStream);
  protected
    procedure DoSocketAttach(ASocket : TSocketStream); override;
    function  GetSocket : TSocketStream; override;
  public
    Constructor Create(AServer : TAbsCustomHTTPServer; ASocket : TSocketStream); override;
    Constructor CreateRefered(AServer : TAbsCustomHTTPServer; ASocketRef : TWCHTTPSocketReference); virtual;
    destructor Destroy; override;
    procedure IncSocketReference;
    procedure DecSocketReference;
    property SocketReference : TWCHTTPSocketReference read FSocketRef;
    property HTTPRefCon: TWCHTTPRefConnection read FHTTPRefCon write SetHTTPRefCon;
    property HTTP2Str: TWCHTTPStream read FHTTP2Str write SetHTTP2Stream;
  end;

  { TThreadSafeConnSettings }

  TThreadSafeConnSettings = class(TThreadSafeObject)
  private
    FConSettings : Array [1..HTTP2_SETTINGS_MAX] of Cardinal;
    function GetConnSetting(id : Word): Cardinal;
    procedure SetConnSetting(id : Word; AValue: Cardinal);
  public
    property ConnSettings[id : Word] : Cardinal read GetConnSetting write SetConnSetting; default;
  end;

  { TThreadSafeConnectionState }

  TThreadSafeConnectionState = class(TThreadSafeObject)
  private
    FState : TWCConnectionState;
    function GetConnState: TWCConnectionState;
    procedure SetConnState(id : TWCConnectionState);
  public
    constructor Create(avalue : TWCConnectionState);
    property Value : TWCConnectionState read GetConnState write SetConnState;
  end;

  { TWCHTTPRefConnection }

  TWCHTTPRefConnection = class(TNetReferencedObject)
  private
    FOwner : TWCHTTPRefConnections;
    FConnectionState : TThreadSafeConnectionState;
    FReadBuffer, FWriteBuffer : TThreadPointer;
    FReadBufferSize, FWriteBufferSize : Cardinal;
    FReadTailSize, FWriteTailSize : Integer;
    FSocket : Cardinal;
    FTimeStamp, FReadStamp, FWriteStamp : TThreadQWord;
    FReadDelay, FWriteDelay : TThreadInteger;
    FFramesToSend : TThreadSafeFastSeq;
    FErrorData : Pointer;
    FErrorDataSize : Cardinal;
    FLastError : Cardinal;
    FSocketRef : TWCHTTPSocketReference;
    FSocketConsume : THttpRefSocketConsume;
    FSendData      : THttpRefSendData;
    FDataSending, FDataReading : TThreadBoolean;

    function GetConnectionState: TWCConnectionState;
    procedure SetConnectionState(CSt: TWCConnectionState);
    function ReadyToReadWrite(const TS : QWord) : Boolean;
    function ReadyToRead(const TS : QWord) : Boolean;
    function ReadyToWrite(const TS : QWord) : Boolean;
    procedure Refresh(const TS: QWord); virtual;
    procedure TryToConsumeFrames(const TS: Qword);
    procedure TryToSendFrames(const TS: Qword);
    procedure InitializeBuffers;
    procedure HoldDelayValue(aDelay : TThreadInteger);
    procedure RelaxDelayValue(aDelay : TThreadInteger);
  protected
    function GetInitialReadBufferSize : Cardinal; virtual; abstract;
    function GetInitialWriteBufferSize : Cardinal; virtual; abstract;
    function CanExpandWriteBuffer(aCurSize, aNeedSize : Cardinal) : Boolean; virtual; abstract;
    function RequestsWaiting : Boolean; virtual; abstract;
  public
    constructor Create(aOwner: TWCHTTPRefConnections;
        aSocket: TWCHTTPSocketReference;
        aSocketConsume: THttpRefSocketConsume; aSendData: THttpRefSendData); virtual;
    procedure ConsumeNextFrame(Mem : TBufferedStream); virtual; abstract;
    procedure ReleaseRead(WithSuccess: Boolean); virtual;
    procedure SendFrames; virtual;
    destructor Destroy; override;
    class function CheckProtocolVersion(Data : Pointer; sz : integer) :
                                             TWCProtocolVersion;
    class function Protocol : TWCProtocolVersion; virtual; abstract;
    procedure PushFrame(fr : TWCHTTPRefProtoFrame); overload;
    procedure PushFrame(const S : String); overload;
    procedure PushFrame(Strm : TStream; Sz : Cardinal; Owned : Boolean); overload;
    procedure PushFrame(Strs : TStrings); overload;
    procedure PushFrame(Strm : TReferencedStream); overload;
    function TryToIdleStep(const TS: Qword): Boolean; virtual;
    property Socket : Cardinal read FSocket;
    // lifetime in seconds
    function GetLifeTime(const TS : QWord): Cardinal;
    // error
    property LastError : Cardinal read FLastError;
    property ErrorDataSize : Cardinal read FErrorDataSize;
    property ErrorData : Pointer read FErrorData;
    //
    property ConnectionState : TWCConnectionState read GetConnectionState write SetConnectionState;
  end;

  { TWCHTTP11Connection }

  TWCHTTP11Connection = class(TWCHTTPRefConnection)
  protected
    function GetInitialReadBufferSize : Cardinal; override;
    function GetInitialWriteBufferSize : Cardinal; override;
    function CanExpandWriteBuffer(aCurSize, aNeedSize : Cardinal) : Boolean; override;
    function RequestsWaiting: Boolean; override;
  private
    procedure ConsumeNextFrame(Mem : TBufferedStream); override;
  public
    constructor Create(aOwner: TWCHTTPRefConnections;
        aSocket: TWCHTTPSocketReference;
        aSocketConsume: THttpRefSocketConsume; aSendData: THttpRefSendData); override;
    class function Protocol : TWCProtocolVersion; override;
  end;

  { TWCHTTP2Connection }

  TWCHTTP2Connection = class(TWCHTTPRefConnection)
  private
    FLastStreamID : Cardinal;
    FStreams : TWCHTTPStreams;
    FConSettings : TThreadSafeConnSettings;
    FErrorStream : Cardinal;
    FHPackDecoder : TThreadSafeHPackDecoder;
    FHPackEncoder : TThreadSafeHPackEncoder;

    function AddNewStream(aStreamID: Cardinal): TWCHTTPStream;
    function GetConnSetting(id : Word): Cardinal;
  protected
    procedure ResetHPack;
    procedure InitHPack;
    property  CurHPackDecoder : TThreadSafeHPackDecoder read FHPackDecoder;
    property  CurHPackEncoder : TThreadSafeHPackEncoder read FHPackEncoder;
    function GetInitialReadBufferSize : Cardinal; override;
    function GetInitialWriteBufferSize : Cardinal; override;
    function CanExpandWriteBuffer(aCurSize, aNeedSize : Cardinal) : Boolean; override;
    function RequestsWaiting: Boolean; override;
  public
    constructor Create(aOwner: TWCHTTPRefConnections;
        aSocket: TWCHTTPSocketReference; aOpenningMode: THTTP2OpenMode;
        aSocketConsume: THttpRefSocketConsume; aSendData: THttpRefSendData); overload;
    class function Protocol : TWCProtocolVersion; override;
    procedure ConsumeNextFrame(Mem : TBufferedStream); override;
    destructor Destroy; override;
    procedure PushFrame(aFrameType : Byte;
                        StrID : Cardinal;
                        aFrameFlags : Byte;
                        aData : Pointer;
                        aDataSize : Cardinal;
                        aOwnPayload : Boolean = true); overload;
    procedure PushFrame(aFrameType : Byte;
                        StrID : Cardinal;
                        aFrameFlags : Byte;
                        aData : TReferencedStream;
                        aStrmPos : Int64;
                        aDataSize : Cardinal); overload;
    function PopRequestedStream : TWCHTTPStream;
    function TryToIdleStep(const TS: Qword): Boolean; override;
    property Streams : TWCHTTPStreams read FStreams;
    // error
    property ErrorStream : Cardinal read FErrorStream;
    //
    property ConnSettings[id : Word] : Cardinal read GetConnSetting;
  end;

  { TWCHTTPStreams }

  TWCHTTPStreams = class(TThreadSafeFastSeq)
  private
    function IsStreamClosed(aStrm: TObject; data: pointer): Boolean;
    procedure AfterStrmExtracted(aObj : TObject);
  public
    destructor Destroy; override;
    function GetByID(aID : Cardinal) : TWCHTTPStream;
    function GetNextStreamWithRequest : TWCHTTPStream;
    function HasStreamWithRequest: Boolean;
    procedure CloseOldIdleStreams(aMaxId : Cardinal);
    procedure RemoveClosedStreams;
  end;

  { TWCHTTP2ServerSettings }

  TWCHTTP2ServerSettings = class(TNetCustomLockedObject)
  private
    HTTP2ServerSettings : PHTTP2SettingsPayload;
    HTTP2ServerSettingsSize : Cardinal;
    function GetCount: Integer;
    function GetSetting(index : integer): THTTP2SettingsBlock;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure Add(Id : Word; Value : Cardinal);
    function CopySettingsToMem(var Mem : Pointer) : Integer;
    property Count : Integer read GetCount;
    property Setting[index : integer] : THTTP2SettingsBlock read GetSetting; default;
  end;

  {$ifdef socket_epoll_mode}
  PEpollEvent = ^epoll_event;
  TEpollEvent = epoll_event;
  PEpollData = ^epoll_data;
  TEpollData = epoll_data;
  {$endif}

  { TWCHTTPREfConnections }

  TWCHTTPRefConnections = class(TThreadSafeFastSeq)
  private
    FLastUsedConnection : TIteratorObject;
    FMaintainStamp : QWord;
    FSettings : TWCHTTP2ServerSettings;
    FGarbageCollector : TNetReferenceList;
    FNeedToRemoveDeadConnections : TThreadBoolean;
    {$ifdef socket_epoll_mode}
    FTimeout: cInt;
    FEvents: array of TEpollEvent;
    FEventsRead: array of TEpollEvent;
    FEpollReadFD: THandle;   // this one monitors LT style for READ
    FEpollFD: THandle;       // this one monitors ET style for other
    FEpollMasterFD: THandle; // this one monitors the first two
    FEpollLocker : TNetCustomLockedObject;
    procedure AddSocketEpoll(ASocket : TWCHTTPSocketReference);
    procedure RemoveSocketEpoll(ASocket : TWCHTTPSocketReference);
    procedure ResetReadingSocket(ASocket : TWCHTTPSocketReference);
    procedure Inflate;
    procedure CallActionEpoll(aCount : Integer);
    {$endif}
    function IsConnDead(aConn: TObject; data: pointer): Boolean;
    procedure AfterConnExtracted(aObj : TObject);
  public
    constructor Create(aGarbageCollector : TNetReferenceList);
    destructor Destroy; override;
    procedure  AddConnection(FConn : TWCHTTPRefConnection);
    function   GetByHandle(aSocket : Cardinal) : TWCHTTPRefConnection;
    procedure RemoveDeadConnections(const TS: QWord; MaxLifeTime: Cardinal);
    procedure Idle(const TS: QWord);
    procedure  PushSocketError;
    property HTTP2Settings : TWCHTTP2ServerSettings read FSettings;
    property GarbageCollector : TNetReferenceList read FGarbageCollector write
                                         FGarbageCollector;
  end;

implementation

uses uhpackimp;

const
  HTTP1HeadersAllowed = [$0A,$0D,$20,$21,$24,$25,$27..$39,$40..$5A,$61..$7A];
  HTTP1_INITIAL_WRITE_BUFFER_SIZE = $FFFF;
  HTTP1_MAX_WRITE_BUFFER_SIZE     = $9600000;
{$ifdef socket_epoll_mode}
  BASE_SIZE = 100;
{$endif}

type
  TWCLifeTimeChecker = record
    CurTime : QWord;
    MaxLifeTime : Cardinal;
  end;

PWCLifeTimeChecker = ^TWCLifeTimeChecker;

{ TWCHTTPRefStreamFrame }

constructor TWCHTTPRefStreamFrame.Create(Strm: TReferencedStream;
                    Pos, Sz: Int64 );
begin
  Strm.IncReference;
  FStrm := Strm;
  Fsz:= Sz;
  Fpos:=Pos;
end;

constructor TWCHTTPRefStreamFrame.Create(Strm: TReferencedStream);
begin
  Strm.IncReference;
  FStrm := Strm;
  Fsz:= Strm.Stream.Size;
  Fpos:=0;
end;

destructor TWCHTTPRefStreamFrame.Destroy;
begin
  FStrm.DecReference;
  inherited Destroy;
end;

procedure TWCHTTPRefStreamFrame.SaveToStream(Str: TStream);
begin
  FStrm.WriteTo(Str, Fpos, FSz);
end;

function TWCHTTPRefStreamFrame.Size: Int64;
begin
  Result := Fsz;
end;

{ TWCHTTPStringFrame }

constructor TWCHTTPStringFrame.Create(const S: String);
begin
  FStr := S;
end;

procedure TWCHTTPStringFrame.SaveToStream(Str: TStream);
begin
  Str.WriteBuffer(FStr[1], Size);
end;

function TWCHTTPStringFrame.Size: Int64;
begin
  Result := Length(FStr);
end;

{ TWCHTTPStringsFrame }

constructor TWCHTTPStringsFrame.Create(Strs: TStrings);
begin
  Strm := TMemoryStream.Create;
  Strs.SaveToStream(Strm);
end;

destructor TWCHTTPStringsFrame.Destroy;
begin
  Strm.Free;
  inherited Destroy;
end;

procedure TWCHTTPStringsFrame.SaveToStream(Str: TStream);
begin
  Str.WriteBuffer(Strm.Memory^, Strm.Size);
end;

function TWCHTTPStringsFrame.Size: Int64;
begin
  Result := Strm.Size;
end;

{ TWCHTTPStreamFrame }

constructor TWCHTTPStreamFrame.Create(Strm: TStream; Sz: Cardinal;
  Owned: Boolean);
begin
  if Owned then FStrm := Strm else
  begin
     FStrm := TMemoryStream.Create;
     FStrm.CopyFrom(Strm, Sz);
     FStrm.Position:=0;
  end;
end;

destructor TWCHTTPStreamFrame.Destroy;
begin
  FStrm.Free;
  inherited Destroy;
end;

procedure TWCHTTPStreamFrame.SaveToStream(Str: TStream);
begin
  Str.CopyFrom(FStrm, 0);
end;

function TWCHTTPStreamFrame.Size: Int64;
begin
  Result := FStrm.Size;
end;

{ TWCHTTP11Connection }

function TWCHTTP11Connection.GetInitialReadBufferSize: Cardinal;
begin
  Result := 0;
end;

function TWCHTTP11Connection.GetInitialWriteBufferSize: Cardinal;
begin
  Result := HTTP1_INITIAL_WRITE_BUFFER_SIZE;
end;

function TWCHTTP11Connection.CanExpandWriteBuffer(aCurSize,
  aNeedSize: Cardinal): Boolean;
begin
  Result := aNeedSize < HTTP1_MAX_WRITE_BUFFER_SIZE;
end;

function TWCHTTP11Connection.RequestsWaiting: Boolean;
begin
  Result := False;
end;

procedure TWCHTTP11Connection.ConsumeNextFrame(Mem: TBufferedStream);
begin
  // do nothing for now
end;

constructor TWCHTTP11Connection.Create(aOwner: TWCHTTPRefConnections;
  aSocket: TWCHTTPSocketReference; aSocketConsume: THttpRefSocketConsume;
  aSendData: THttpRefSendData);
begin
  inherited Create(aOwner, aSocket, aSocketConsume, aSendData);
  InitializeBuffers;
end;

class function TWCHTTP11Connection.Protocol: TWCProtocolVersion;
begin
  Result := wcHTTP1_1;
end;

{ TWCHTTP2ServerSettings }

function TWCHTTP2ServerSettings.GetCount: Integer;
begin
  Lock;
  try
    Result := HTTP2ServerSettingsSize div H2P_SETTINGS_BLOCK_SIZE;
  finally
    UnLock;
  end;
end;

function TWCHTTP2ServerSettings.GetSetting(index : integer
  ): THTTP2SettingsBlock;
begin
  Lock;
  try
    Result := HTTP2ServerSettings^[index];
  finally
    UnLock;
  end;
end;

constructor TWCHTTP2ServerSettings.Create;
begin
  inherited Create;
  HTTP2ServerSettings := nil;
  HTTP2ServerSettingsSize := 0;
end;

destructor TWCHTTP2ServerSettings.Destroy;
begin
  if assigned(HTTP2ServerSettings) then Freemem(HTTP2ServerSettings);
  inherited Destroy;
end;

procedure TWCHTTP2ServerSettings.Reset;
begin
  Lock;
  try
    if assigned(HTTP2ServerSettings) then FreeMem(HTTP2ServerSettings);
    HTTP2ServerSettings := GetMem(HTTP2_SETTINGS_MAX_SIZE);
    HTTP2ServerSettingsSize := 0;
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2ServerSettings.Add(Id: Word; Value: Cardinal);
var l, Sz : Integer;
    S : PHTTP2SettingsPayload;
begin
  Lock;
  try
    if not Assigned(HTTP2ServerSettings) then
      Reset;
    S := HTTP2ServerSettings;
    Sz := HTTP2ServerSettingsSize div H2P_SETTINGS_BLOCK_SIZE;
    for l := 0 to Sz - 1 do
    begin
      if S^[l].Identifier = Id then begin
        S^[l].Value := Value;
        Exit;
      end;
    end;
    if HTTP2ServerSettingsSize < HTTP2_SETTINGS_MAX_SIZE then
    begin
      S^[Sz].Identifier := Id;
      S^[Sz].Value := Value;
      Inc(HTTP2ServerSettingsSize, H2P_SETTINGS_BLOCK_SIZE);
    end;
  finally
    UnLock;
  end;
end;

function TWCHTTP2ServerSettings.CopySettingsToMem(var Mem: Pointer): Integer;
begin
  Lock;
  try
    Result := HTTP2ServerSettingsSize;
    if HTTP2ServerSettingsSize > 0 then
    begin
      Mem := GetMem(HTTP2ServerSettingsSize);
      Move(HTTP2ServerSettings^, Mem^, HTTP2ServerSettingsSize);
    end else Mem := nil;
  finally
    UnLock;
  end;
end;

{ TThreadSafeConnectionState }

function TThreadSafeConnectionState.GetConnState: TWCConnectionState;
begin
  lock;
  try
    Result := FState;
  finally
    UnLock;
  end;
end;

procedure TThreadSafeConnectionState.SetConnState(id: TWCConnectionState);
begin
  lock;
  try
    FState := id;
  finally
    UnLock;
  end;
end;

constructor TThreadSafeConnectionState.Create(avalue: TWCConnectionState);
begin
  inherited Create;
  FState:= aValue;
end;

{ TThreadSafeConnSettings }

function TThreadSafeConnSettings.GetConnSetting(id : Word): Cardinal;
begin
  lock;
  try
    Result := FConSettings[id];
  finally
    UnLock;
  end;
end;

procedure TThreadSafeConnSettings.SetConnSetting(id : Word; AValue: Cardinal);
begin
  lock;
  try
    FConSettings[id] := AValue;
  finally
    UnLock;
  end;
end;

{ TThreadSafeHPackEncoder }

constructor TThreadSafeHPackEncoder.Create(TableSize: Cardinal);
begin
  inherited Create;
  FEncoder := THPackEncoder.Create(TableSize);
end;

destructor TThreadSafeHPackEncoder.Destroy;
begin
  FEncoder.Free;
  inherited Destroy;
end;

procedure TThreadSafeHPackEncoder.EncodeHeader(aOutStream: TStream;
  const aName: RawByteString; const aValue: RawByteString;
  const aSensitive: Boolean);
begin
  Lock;
  try
    FEncoder.EncodeHeader(aOutStream, aName, aValue, aSensitive);
  finally
    UnLock;
  end;
end;

{ TThreadSafeHPackDecoder }

function TThreadSafeHPackDecoder.GetDecodedHeaders: THPackHeaderTextList;
begin
  Lock;
  try
    Result := FDecoder.DecodedHeaders;
  finally
    UnLock;
  end;
end;

constructor TThreadSafeHPackDecoder.Create(HeadersListSize, TableSize: Cardinal
  );
begin
  Inherited Create;
  FDecoder := THPackDecoder.Create(HeadersListSize, TableSize);
end;

destructor TThreadSafeHPackDecoder.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

procedure TThreadSafeHPackDecoder.Decode(aStream: TStream);
begin
  Lock;
  try
    FDecoder.Decode(aStream);
  finally
    UnLock;
  end;
end;

function TThreadSafeHPackDecoder.EndHeaderBlockTruncated: Boolean;
begin
  Lock;
  try
    Result := FDecoder.EndHeaderBlockTruncated;
  finally
    UnLock;
  end;
end;

{ TWCHTTPSocketReference }

constructor TWCHTTPSocketReference.Create(aSocket: TSocketStream);
begin
  inherited Create;
  FSocket := aSocket;
  {$ifdef socket_select_mode}
  {$ifdef windows}
  FReadFDSet:= GetMem(Sizeof(Cardinal) + Sizeof(TSocket)*1);
  FWriteFDSet:= GetMem(Sizeof(Cardinal) + Sizeof(TSocket)*1);
  FErrorFDSet:= GetMem(Sizeof(Cardinal) + Sizeof(TSocket)*1);
  {$endif}
  {$ifdef linux}
  FReadFDSet:= GetMem(Sizeof(TFDSet));
  FWriteFDSet:= GetMem(Sizeof(TFDSet));
  FErrorFDSet:= GetMem(Sizeof(TFDSet));
  {$endif}
  //FD_ZERO(FReadFDSet);
  //FD_ZERO(FWriteFDSet);
  //FD_ZERO(FErrorFDSet);
  FWaitTime.tv_sec := 0;
  FWaitTime.tv_usec := 1000;
  {$endif}
  FSocketStates:=[ssCanSend, ssCanRead];
end;

destructor TWCHTTPSocketReference.Destroy;
begin
  if assigned(FSocket) then FreeAndNil(FSocket);
  {$ifdef socket_select_mode}
  FreeMem(FReadFDSet);
  FreeMem(FWriteFDSet);
  FreeMem(FErrorFDSet);
  {$endif}
  inherited Destroy;
end;

{$ifdef socket_select_mode}
procedure TWCHTTPSocketReference.GetSocketStates;
var
  n : integer;
  err : integer;
begin
  Lock;
  try
    {$ifdef unix}
    fpFD_ZERO(FReadFDSet^);
    fpFD_ZERO(FWriteFDSet^);
    fpFD_ZERO(FErrorFDSet^);
    fpFD_SET(Socket.Handle, FReadFDSet^);
    fpFD_SET(Socket.Handle, FWriteFDSet^);
    fpFD_SET(Socket.Handle, FErrorFDSet^);
    n := fpSelect(Socket.Handle+1, FReadFDSet, FWriteFDSet, FErrorFDSet, @FWaitTime);
    {$endif}
    {$ifdef windows}
    FReadFDSet^.fd_count := 1;
    FReadFDSet^.fd_array[0]  := Socket.Handle;
    FWriteFDSet^.fd_count := 1;
    FWriteFDSet^.fd_array[0] := Socket.Handle;
    FErrorFDSet^.fd_count := 1;
    FErrorFDSet^.fd_array[0] := Socket.Handle;
    n := Select(Socket.Handle+1, FReadFDSet, FWriteFDSet, FErrorFDSet, @FWaitTime);
    {$endif}
    FSocketStates:=[];
    if n < 0 then
    begin
      err := socketerror;
      if (err = EsockENOTSOCK) then
      begin
        FSocketStates := FSocketStates + [ssError];
        Raise ESocketError.Create(seListenFailed,[Socket.Handle,err]);
      end;
    end else
    if n > 0 then
    begin
      {$ifdef windows}
      if FD_ISSET(Socket.Handle, FReadFDSet^) then
         FSocketStates:=FSocketStates + [ssCanRead];
      if FD_ISSET(Socket.Handle, FWriteFDSet^) then
         FSocketStates:=FSocketStates + [ssCanSend];
      if FD_ISSET(Socket.Handle, FErrorFDSet^) then
         FSocketStates:=FSocketStates + [ssError];
      {$endif}
      {$ifdef unix}
      if fpFD_ISSET(Socket.Handle, FReadFDSet^)>0 then
         FSocketStates:=FSocketStates + [ssCanRead];
      if fpFD_ISSET(Socket.Handle, FWriteFDSet^)>0 then
         FSocketStates:=FSocketStates + [ssCanSend];
      if fpFD_ISSET(Socket.Handle, FErrorFDSet^)>0 then
         FSocketStates:=FSocketStates + [ssError];
      {$endif}
    end;
  finally
    UnLock;
  end;
end;
{$endif}

procedure TWCHTTPSocketReference.SetCanRead;
begin
  Lock;
  try
    FSocketStates:=FSocketStates + [ssCanRead];
  finally
    UnLock;
  end;
end;

procedure TWCHTTPSocketReference.SetCanSend;
begin
  Lock;
  try
    FSocketStates:=FSocketStates + [ssCanSend];
  finally
    UnLock;
  end;
end;

function TWCHTTPSocketReference.CanRead: Boolean;
begin
  Lock;
  try
    Result := ([ssCanRead, ssReading,
                ssSending, ssError] * FSocketStates) = [ssCanRead];
  finally
    UnLock;
  end;
end;

function TWCHTTPSocketReference.CanSend: Boolean;
begin
  Lock;
  try
    Result := ([ssCanSend, ssReading,
                ssSending, ssError] * FSocketStates) = [ssCanSend];
  finally
    UnLock;
  end;
end;

function TWCHTTPSocketReference.StartReading : Boolean;
begin
  Lock;
  try
  if CanRead then begin
    FSocketStates := FSocketStates + [ssReading];
    Result := true;
  end else Result := false;
  finally
    UnLock;
  end;
end;

procedure TWCHTTPSocketReference.StopReading;
begin
  Lock;
  try
    FSocketStates := FSocketStates - [ssReading];
  finally
    UnLock;
  end;
end;

function TWCHTTPSocketReference.StartSending: Boolean;
begin
  Lock;
  try
  if CanSend then begin
    FSocketStates := FSocketStates + [ssSending];
    Result := true;
  end else Result := false;
  finally
    UnLock;
  end;
end;

procedure TWCHTTPSocketReference.StopSending;
begin
  Lock;
  try
    FSocketStates := FSocketStates - [ssSending];
  finally
    UnLock;
  end;
end;

procedure TWCHTTPSocketReference.PushError;
begin
  Lock;
  try
    FSocketStates := FSocketStates + [ssError];
  finally
    UnLock;
  end;
end;

function TWCHTTPSocketReference.Write(const Buffer; Size: Integer): Integer;
begin
  if StartSending then
  try
    Result := FSocket.Write(Buffer, Size);
    {$IFDEF SOCKET_EPOLL_MODE}
    if (Result <= 0) and (errno = ESysEAGAIN) then
    {$ENDIF}
    begin
      Lock;
      try
        FSocketStates := FSocketStates - [ssCanSend];
      finally
        UnLock;
      end;
    end;
  finally
    StopSending;
  end else Result := 0;
end;

function TWCHTTPSocketReference.Read(var Buffer; Size: Integer): Integer;
begin
  if StartReading then
  try
    Result := FSocket.Read(Buffer, Size);
    {$IFDEF SOCKET_EPOLL_MODE}
    if (Result < Size) or (errno = ESysEAGAIN) then
    {$ENDIF}
    begin
      Lock;
      try
        FSocketStates := FSocketStates - [ssCanRead];
      finally
        UnLock;
      end;
    end;
  finally
    StopReading;
  end else Result := 0;
end;

{ TWCHTTPConnection }

procedure TWCHTTPConnection.SetHTTPRefCon(AValue: TWCHTTPRefConnection);
begin
  if FHTTPRefCon=AValue then Exit;
  if assigned(FHTTPRefCon) then
    FHTTPRefCon.DecReference;
  SetHTTP2Stream(nil);
  FHTTPRefCon:=AValue;
end;

procedure TWCHTTPConnection.SetHTTP2Stream(AValue: TWCHTTPStream);
begin
  if FHTTP2Str=AValue then Exit;
  if Assigned(FHTTP2Str) then FHTTP2Str.Release;  //release here!
  FHTTP2Str:=AValue;
end;

procedure TWCHTTPConnection.DoSocketAttach(ASocket: TSocketStream);
begin
  FSocketRef := TWCHTTPSocketReference.Create(ASocket);
end;

function TWCHTTPConnection.GetSocket: TSocketStream;
begin
  Result := FSocketRef.Socket;
end;

constructor TWCHTTPConnection.Create(AServer: TAbsCustomHTTPServer;
  ASocket: TSocketStream);
begin
  FSocketRef:= nil;
  inherited Create(AServer, ASocket);
  FHTTPRefCon:=nil;
  FHTTP2Str:=nil;
end;

constructor TWCHTTPConnection.CreateRefered(AServer: TAbsCustomHTTPServer;
  ASocketRef: TWCHTTPSocketReference);
begin
  inherited Create(AServer, nil);
  FSocketRef := ASocketRef;
  ASocketRef.IncReference;
  FHTTPRefCon:=nil;
  FHTTP2Str:=nil;
end;

destructor TWCHTTPConnection.Destroy;
begin
  SetHTTPRefCon(nil);
  if assigned(FSocketRef) then FSocketRef.DecReference;
  FSocketRef := nil;
  inherited Destroy;
end;

procedure TWCHTTPConnection.IncSocketReference;
begin
  if assigned(FSocketRef) then FSocketRef.IncReference;
end;

procedure TWCHTTPConnection.DecSocketReference;
begin
  if assigned(FSocketRef) then FSocketRef.DecReference;
end;

{ TWCHTTP2UpgradeResponseFrame }

constructor TWCHTTP2UpgradeResponseFrame.Create(Mode: THTTP2OpenMode);
begin
  FMode:= Mode;
end;

procedure TWCHTTP2UpgradeResponseFrame.SaveToStream(Str: TStream);
var Buffer : Pointer;
    BufferSize : Cardinal;
begin
  case FMode of
    h2oUpgradeToH2C : begin
      Buffer := @(HTTP2UpgradeBlockH2C[1]);
      BufferSize:= HTTP2UpgradeBlockH2CSize;
    end;
    h2oUpgradeToH2 : begin
      Buffer := @(HTTP2UpgradeBlockH2[1]);
      BufferSize:= HTTP2UpgradeBlockH2Size;
    end;
  else
    Buffer := nil;
    BufferSize := 0;
  end;
  if assigned(Buffer) then
    Str.WriteBuffer(Buffer^, BufferSize);
end;

function TWCHTTP2UpgradeResponseFrame.Size: Int64;
begin
  case FMode of
    h2oUpgradeToH2C : begin
      Result:= HTTP2UpgradeBlockH2CSize;
    end;
    h2oUpgradeToH2 : begin
      Result:= HTTP2UpgradeBlockH2Size;
    end;
  else
    Result := 0;
  end;
end;

{ TWCHTTP2AdvFrame }

procedure TWCHTTP2AdvFrame.SaveToStream(Str: TStream);
begin
  Str.WriteBuffer(HTTP2Preface, H2P_PREFACE_SIZE);
end;

function TWCHTTP2AdvFrame.Size: Int64;
begin
  Result := H2P_PREFACE_SIZE;
end;

{ TWCHTTP2StrmResponseHeaderPusher }

constructor TWCHTTP2StrmResponseHeaderPusher.Create(
  aHPackEncoder: TThreadSafeHPackEncoder; aStrm: TStream);
begin
  inherited Create(aHPackEncoder);
  FStrm := aStrm;
end;

procedure TWCHTTP2StrmResponseHeaderPusher.PushHeader(const H, V: String);
begin
  FMem.Position:=0;
  FHPackEncoder.EncodeHeader(FMem, H, V, false);
  FStrm.WriteBuffer(FMem.Memory^, FMem.Position);
end;

{ TWCHTTP2BufResponseHeaderPusher }

constructor TWCHTTP2BufResponseHeaderPusher.Create(
  aHPackEncoder: TThreadSafeHPackEncoder; aBuffer: Pointer; aBufferSize,
  aBufGrowValue: Cardinal);
begin
  inherited Create(aHPackEncoder);
  FBuf := aBuffer;
  FCapacity:= aBufferSize;
  FBufGrowValue := aBufGrowValue;
  FSize := 0;
end;

procedure TWCHTTP2BufResponseHeaderPusher.PushHeader(const H, V: String);

procedure ExpandHeadersBuffer;
begin
  FCapacity := FCapacity + FBufGrowValue;
  FBuf := ReAllocMem(FBuf, FCapacity);
end;

begin
  FMem.Position:=0;
  FHPackEncoder.EncodeHeader(FMem, H, V, false);
  if FMem.Position + FSize > FCapacity then
    ExpandHeadersBuffer;
  Move(FMem.Memory^, PByte(FBuf)[FSize], FMem.Position);
  Inc(FSize, FMem.Position);
end;

{ TWCHTTP2ResponseHeaderPusher }

constructor TWCHTTP2ResponseHeaderPusher.Create(
  aHPackEncoder: TThreadSafeHPackEncoder);
begin
  aHPackEncoder.IncReference;
  FHPackEncoder := aHPackEncoder;
  FMem := TMemoryStream.Create;
  FMem.SetSize(4128);
end;

destructor TWCHTTP2ResponseHeaderPusher.Destroy;
begin
  FHPackEncoder.DecReference;
  FMem.Free;
  inherited Destroy;
end;

procedure TWCHTTP2ResponseHeaderPusher.PushAll(R: TResponse);
var h1 : THeader;
    h2 : THTTP2Header;
    v  : String;
    i : integer;
begin
  FHPackEncoder.Lock;
  try
    PushHeader(HTTP2HeaderStatus, Inttostr(R.Code));
    //PushHeader(HTTP2HeaderVersion, HTTP2VersionId);
    h1 := hhUnknown;
    while h1 < High(THeader) do
    begin
      Inc(h1);
      if R.HeaderIsSet(h1) then
        PushHeader(LowerCase(HTTPHeaderNames[h1]), R.GetHeader(h1));
    end;
    h2 := hh2Status;
    while h2 < High(THTTP2Header) do
    begin
      inc(h2);
      v := R.GetCustomHeader(HTTP2AddHeaderNames[h2]);
      if Length(v) > 0 then
         PushHeader(HTTP2AddHeaderNames[h2], v);
    end;
    for i := 0 to R.Cookies.Count-1 do
      PushHeader(LowerCase(HTTP2AddHeaderNames[hh2SetCookie]),
                                                    R.Cookies[i].AsString);
  finally
    FHPackEncoder.UnLock;
  end;
end;

{ TWCHTTP2SerializeStream }

constructor TWCHTTP2SerializeStream.Create(aConn: TWCHTTP2Connection;
  aStrm: Cardinal; aFirstFrameType: Byte; aNextFramesType: Byte; aFlags,
  aFinalFlags: Byte);
begin
  Inherited Create;
  FStrmID := aStrm;
  FConn := aConn;
  FConn.IncReference;
  FFlags := aFlags;
  FFinalFlags := aFinalFlags;
  FFirstFrameType:= aFirstFrameType;
  FNextFramesType:= aNextFramesType;
  FCurFrame := nil;
  FRestFrameSz := 0;
  FChuncked := false;
  FFirstFramePushed := false;
end;

function TWCHTTP2SerializeStream.Write(const Buffer; Count: Longint): Longint;
var B, Src : Pointer;
    Sz, BSz, MaxSize : Longint;
begin
  Src := @Buffer;
  Result := Count;
  Sz := Count;
  MaxSize := FConn.ConnSettings[H2SET_MAX_FRAME_SIZE];
  if (Sz > MaxSize) and (FChuncked) then Exit(-1);
  while Sz > 0 do begin
    if Assigned(FCurFrame) and
       ((FRestFrameSz = 0) or
        (FChuncked and (FRestFrameSz < Sz))) then
    begin
      FConn.PushFrame(FCurFrame);
      FCurFrame := nil;
    end;

    if not Assigned(FCurFrame) then
    begin
      if Sz > MaxSize then Bsz := MaxSize else Bsz := Sz;
      B := GetMem(MaxSize);
      if FFirstFramePushed then
        FCurFrame := TWCHTTP2DataFrame.Create(FNextFramesType, FStrmID, FFlags, B, Bsz)
      else begin
        FCurFrame := TWCHTTP2DataFrame.Create(FFirstFrameType, FStrmID, FFlags, B, Bsz);
        FFirstFramePushed:= true;
      end;
      FRestFrameSz := MaxSize - Bsz;
    end else
    begin
      BSz := Sz;
      if BSz > FRestFrameSz then
      begin
         BSz := FRestFrameSz;
         FRestFrameSz := 0;
      end else
         Dec(FRestFrameSz, BSz);
      B := Pointer(FCurFrame.Payload + FCurFrame.Header.PayloadLength);
      Inc(FCurFrame.Header.PayloadLength, Bsz);
    end;
    Move(Src^, B^, BSz);
    Inc(Src, BSz);
    Dec(Sz, BSz);
  end;
end;

destructor TWCHTTP2SerializeStream.Destroy;
begin
  if assigned(FCurFrame) then begin
    FCurFrame.Header.FrameFlag := FFinalFlags;
    FConn.PushFrame(FCurFrame);
  end;
  FConn.DecReference;
  inherited Destroy;
end;

{ TWCHTTP2Response }

constructor TWCHTTP2Response.Create(aConnection: TWCHTTP2Connection;
  aStream: TWCHTTPStream);
begin
  inherited Create(aConnection, aStream);
  FCurHeadersBlock:= nil;
end;

destructor TWCHTTP2Response.Destroy;
begin
  if assigned(FCurHeadersBlock) then FreeMemAndNil(FCurHeadersBlock);
  inherited Destroy;
end;

procedure TWCHTTP2Response.CopyFromHTTP1Response(R: TResponse);
var pusher : TWCHTTP2BufResponseHeaderPusher;
    Capacity : Cardinal;
begin
  Capacity := FConnection.ConnSettings[H2SET_MAX_FRAME_SIZE];
  FCurHeadersBlock := ReAllocMem(FCurHeadersBlock, Capacity);
  FHeadersBlockSize:=0;
  FConnection.InitHPack;
  pusher := TWCHTTP2BufResponseHeaderPusher.Create(FConnection.CurHPackEncoder,
                                                   FCurHeadersBlock,
                                                   Capacity,
                                                   Capacity);
  try
    pusher.pushall(R);
    FCurHeadersBlock := pusher.Buffer;
    FHeadersBlockSize:= pusher.Size;
  finally
    pusher.Free;
  end;
end;

procedure TWCHTTP2Response.Close;
//var er : PHTTP2RstStreamPayload;
begin
  FConnection.PushFrame(H2FT_DATA, FStream.ID, H2FL_END_STREAM, nil, 0);
  {er := GetMem(H2P_RST_STREAM_FRAME_SIZE);
  er^.ErrorCode := H2E_NO_ERROR;
  FConnection.PushFrame(H2FT_RST_STREAM, FStream.ID, 0, er, H2P_RST_STREAM_FRAME_SIZE); }
end;

procedure TWCHTTP2Response.SerializeResponse;
begin
  SerializeHeaders(FDataBlockSize = 0);
  if FDataBlockSize > 0 then
     SerializeData(true);
end;

procedure TWCHTTP2Response.SerializeHeaders(closeStrm : Boolean);
var
  sc : TWCHTTP2SerializeStream;
begin
  if Assigned(FCurHeadersBlock) then
  begin
    sc := TWCHTTP2SerializeStream.Create(FConnection, FStream.Id,
                                         H2FT_HEADERS,
                                         H2FT_CONTINUATION,
                                         0,
                                         H2FL_END_HEADERS or
                                         (Ord(closeStrm) * H2FL_END_STREAM));
    try
      sc.WriteBuffer(FCurHeadersBlock^, FHeadersBlockSize);
    finally
      sc.Free;
    end;
    FreeMemAndNil(FCurHeadersBlock);
    FHeadersBlockSize:=0;
  end;
  // after headers serialized close stream
  if closeStrm then
    FStream.FStreamState := h2ssCLOSED;
end;

procedure TWCHTTP2Response.SerializeData(closeStrm : Boolean);
var
  sc : TWCHTTP2SerializeStream;
begin
  // serialize in group of data chunck with max_frame_size
  // then remove fdatablock
  if assigned(FCurDataBlock) and (FDataBlockSize > 0) then
  begin
    sc := TWCHTTP2SerializeStream.Create(FConnection, FStream.Id,
                                         H2FT_DATA,
                                         H2FT_DATA,
                                         0,
                                         (Ord(closeStrm) * H2FL_END_STREAM));
    try
      sc.WriteBuffer(FCurDataBlock^, FDataBlockSize);
    finally
      sc.Free;
    end;
  end;
  FDataBlockSize:=0;
  // after data serialized close stream
  if closeStrm then
    FStream.FStreamState := h2ssCLOSED;
end;

procedure TWCHTTP2Response.SerializeResponseHeaders(R: TResponse;
  closeStrm: Boolean);
var sc : TWCHTTP2SerializeStream;
    pusher : TWCHTTP2StrmResponseHeaderPusher;
begin
  if Assigned(FCurHeadersBlock) then FreeMemAndNil(FCurHeadersBlock);
  FHeadersBlockSize:=0;

  sc := TWCHTTP2SerializeStream.Create(FConnection,
                                       FStream.ID,
                                       H2FT_HEADERS,
                                       H2FT_CONTINUATION,
                                       0,
                                       H2FL_END_HEADERS or
                                       (Ord(closeStrm) * H2FL_END_STREAM));
  FConnection.InitHPack;
  pusher := TWCHTTP2StrmResponseHeaderPusher.Create(FConnection.CurHPackEncoder,
                                                    sc);
  try
    sc.Chuncked := true;
    pusher.PushAll(R);
  finally
    sc.Free;
    pusher.Free;
  end;
  // after data serialized close stream
  if closeStrm then
    FStream.FStreamState := h2ssCLOSED;
end;

procedure TWCHTTP2Response.SerializeResponseData(R: TResponse;
  closeStrm: Boolean);
var sc : TWCHTTP2SerializeStream;
begin
  if Assigned(FCurDataBlock) then FreeMemAndNil(FCurDataBlock);
  FDataBlockSize:=0;

  if R.ContentLength > 0 then
  begin
    sc := TWCHTTP2SerializeStream.Create(FConnection, FStream.ID,
                                         H2FT_DATA,
                                         H2FT_DATA,
                                         0,
                                         (Ord(closeStrm) * H2FL_END_STREAM));
    try
      if assigned(R.ContentStream) then
      begin
        sc.CopyFrom(R.ContentStream, R.ContentStream.Size);
      end else
      begin
        R.Contents.SaveToStream(sc);
      end;
    finally
      sc.Free;
    end;
  end;
  // after data serialized close stream
  if closeStrm then
    FStream.FStreamState := h2ssCLOSED;
end;

procedure TWCHTTP2Response.SerializeRefStream(R: TReferencedStream;
  closeStrm: Boolean);
var BSz, MaxSize : Longint;
    CurFrame : TWCHTTP2RefFrame;
    Pos, Size : Int64;
begin
  R.IncReference;
  try
    Pos := 0;
    Size := R.Stream.Size;
    CurFrame := nil;
    MaxSize := FConnection.ConnSettings[H2SET_MAX_FRAME_SIZE];
    while Size > 0 do begin
      if Assigned(CurFrame) then
      begin
        FConnection.PushFrame(CurFrame);
        CurFrame := nil;
      end;
      if Size > MaxSize then Bsz := MaxSize else Bsz := Size;
      CurFrame := TWCHTTP2RefFrame.Create(H2FT_DATA, FStream.ID, 0, R, Pos, Bsz);
      Inc(Pos, BSz);
      Dec(Size, BSz);
    end;
    if assigned(CurFrame) then begin
      if closeStrm then
        CurFrame.Header.FrameFlag := H2FL_END_STREAM;
      FConnection.PushFrame(CurFrame);
    end;
  finally
    R.DecReference;
  end;
  // after data serialized close stream
  if closeStrm then
    FStream.FStreamState := h2ssCLOSED;
end;

{ TWCHTTP2Request }

function TWCHTTP2Request.GetResponse: TWCHTTP2Response;
begin
  if Assigned(FResponse) then Exit(FResponse);
  FResponse := TWCHTTP2Response.Create(FConnection, FStream);
  Result := FResponse;
end;

constructor TWCHTTP2Request.Create(aConnection : TWCHTTP2Connection;
                                   aStream : TWCHTTPStream);
begin
  inherited Create(aConnection, aStream);
  FComplete := false;
  FResponse := nil;
  FHeaders  := THPackHeaderTextList.Create;
end;

destructor TWCHTTP2Request.Destroy;
begin
  if assigned(FResponse) then FreeAndNil(FResponse);
  FHeaders.Free;
  inherited Destroy;
end;

procedure TWCHTTP2Request.CopyHeaders(aHPackDecoder: TThreadSafeHPackDecoder);
var i : integer;
    p : PHPackHeaderTextItem;
begin
  aHPackDecoder.IncReference;
  aHPackDecoder.Lock;
  try
    FHeaders.Clear;
    for i := 0 to aHPackDecoder.DecodedHeaders.Count-1 do
    begin
      P := aHPackDecoder.DecodedHeaders[i];
      FHeaders.Add(P^.HeaderName, P^.HeaderValue, P^.IsSensitive);
    end;
    aHPackDecoder.DecodedHeaders.Clear;
  finally
    aHPackDecoder.UnLock;
    aHPackDecoder.DecReference;
  end;
end;

procedure TWCHTTP2Request.CopyToHTTP1Request(ARequest: TRequest);
var
  i, j : integer;
  h : PHTTPHeader;
  v : PHPackHeaderTextItem;
  S : String;
begin
  if Complete then
  begin
    try
      for i := 0 to FHeaders.Count-1 do
      begin
        v := FHeaders[i];
        h := GetHTTPHeaderType(v^.HeaderName);
        if assigned(h) then
        begin
          if h^.h2 <> hh2Unknown then
          begin
            case h^.h2 of
              hh2Method : ARequest.Method := v^.HeaderValue;
              hh2Path   : begin
                ARequest.URL:= v^.HeaderValue;
                S:=ARequest.URL;
                j:=Pos('?',S);
                if (j>0) then
                  S:=Copy(S,1,j-1);
                If (Length(S)>1) and (S[1]<>'/') then
                  S:='/'+S
                else if S='/' then
                  S:='';
                ARequest.PathInfo:=S;
              end;
              hh2Authority, hh2Scheme, hh2Status : ;
              hh2Cookie : begin
                ARequest.CookieFields.Add(v^.HeaderValue);
              end
            else
              ARequest.SetCustomHeader(HTTP2AddHeaderNames[h^.h2], v^.HeaderValue);
            end;
          end else
          if h^.h1 <> hhUnknown then
          begin
            ARequest.SetHeader(h^.h1, v^.HeaderValue);
          end else
            ARequest.SetCustomHeader(v^.HeaderName, v^.HeaderValue);
        end;
      end;
      if FDataBlockSize > 0 then begin
        SetLength(S, FDataBlockSize);
        Move(FCurDataBlock^, S[1], FDataBlockSize);
        ARequest.Content:=S;
      end;
    finally
      //
    end;
  end;
end;
  
{ TWCHTTP2Frame }

constructor TWCHTTP2Frame.Create(aFrameType: Byte; StrID: Cardinal;
  aFrameFlags: Byte);
begin
  Header := TWCHTTP2FrameHeader.Create;
  Header.FrameType := aFrameType;
  Header.FrameFlag := aFrameFlags;
  Header.PayloadLength := 0;
  Header.StreamID := StrID;
end;
                     
destructor TWCHTTP2Frame.Destroy;
begin
  Header.Free;
  inherited Destroy;
end;
                     
procedure TWCHTTP2Frame.SaveToStream(Str : TStream);
begin
  Header.SaveToStream(Str);
end;

function TWCHTTP2Frame.Size: Int64;
begin
  Result := H2P_FRAME_HEADER_SIZE + Header.PayloadLength;
end;

{ TWCHTTP2DataFrame }

constructor TWCHTTP2DataFrame.Create(aFrameType: Byte; StrID: Cardinal;
  aFrameFlags: Byte; aData: Pointer; aDataSize: Cardinal; aOwnPayload: Boolean);
begin
  inherited Create(aFrameType, StrID, aFrameFlags);
  Header.PayloadLength := aDataSize;
  Payload:= aData;
  OwnPayload:= aOwnPayload;
end;

destructor TWCHTTP2DataFrame.Destroy;
begin
  if Assigned(Payload) and OwnPayload then Freemem(Payload);
  inherited Destroy;
end;

procedure TWCHTTP2DataFrame.SaveToStream(Str: TStream);
begin
  inherited SaveToStream(Str);
  if Header.PayloadLength > 0 then
    Str.Write(Payload^, Header.PayloadLength);
end;

{ TWCHTTP2RefFrame }

constructor TWCHTTP2RefFrame.Create(aFrameType: Byte; StrID: Cardinal;
  aFrameFlags: Byte; aData: TReferencedStream; aStrmPos: Int64;
  aDataSize: Cardinal);
begin
  inherited Create(aFrameType, StrID, aFrameFlags);
  Header.PayloadLength := aDataSize;
  aData.IncReference;
  FStrm := aData;
  Fpos:= aStrmPos;
end;

destructor TWCHTTP2RefFrame.Destroy;
begin
  FStrm.DecReference;
  inherited Destroy;
end;

procedure TWCHTTP2RefFrame.SaveToStream(Str: TStream);
begin
  inherited SaveToStream(Str);
  if Header.PayloadLength > 0 then
    FStrm.WriteTo(Str, Fpos, Header.PayloadLength)
end;

{ TWCHTTP2FrameHeader }

procedure TWCHTTP2FrameHeader.LoadFromStream(Str: TStream);
var FrameHeader : Array [0..H2P_FRAME_HEADER_SIZE-1] of Byte;
begin
  // read header
  Str.Read(FrameHeader, H2P_FRAME_HEADER_SIZE);
  // format frame
  PayloadLength := (FrameHeader[0] shl 16) or
                   (FrameHeader[1] shl 8) or
                    FrameHeader[2];
  FrameType:= FrameHeader[3];
  FrameFlag:= FrameHeader[4];
  StreamID := BEtoN(PCardinal(@(FrameHeader[5]))^) and H2P_STREAM_ID_MASK;
end;

procedure TWCHTTP2FrameHeader.SaveToStream(Str: TStream);
var FrameHeader : Array [0..H2P_FRAME_HEADER_SIZE-1] of Byte;
    PL24 : Cardinal;
begin
  // format frame
  // 0x00a2b3c4 << 8 --> 0xa2b3c400 (0x00c4b3a2 in LE)
  // NtoBE(0x00c4b3a2) --> 0xa2b3c400
  PL24 := PayloadLength shl 8;
  // write first most significant 3 bytes
  Move(NtoBE(PL24), FrameHeader[0], H2P_PAYLOAD_LEN_SIZE);
  FrameHeader[3] := FrameType;
  FrameHeader[4] := FrameFlag;
  Move(NtoBE(StreamID), FrameHeader[5], H2P_STREAM_ID_SIZE);

  // write header
  Str.Write(FrameHeader, H2P_FRAME_HEADER_SIZE);
end;

{ TWCHTTP2Block }

procedure TWCHTTP2Block.PushData(Data: Pointer; sz: Cardinal);
begin
  if sz = 0 then Exit;
  
  if not Assigned(FCurDataBlock) then
     FCurDataBlock:=GetMem(Sz) else
     FCurDataBlock:=ReAllocMem(FCurDataBlock, Sz + FDataBlockSize);

  Move(Data^, PByte(FCurDataBlock)[FDataBlockSize], Sz);

  Inc(FDataBlockSize, sz);
end;

procedure TWCHTTP2Block.PushData(Strm: TStream; startAt : Int64);
var sz : Int64;
begin
  Strm.Position:= startAt;
  sz := Strm.Size - startAt;
  if Sz > 0 then
  begin
    if not Assigned(FCurDataBlock) then
       FCurDataBlock:=GetMem(Sz) else
       FCurDataBlock:=ReAllocMem(FCurDataBlock, Sz + FDataBlockSize);

    Strm.Read(PByte(FCurDataBlock)[FDataBlockSize], Sz);

    Inc(FDataBlockSize, sz);
  end;
end;

procedure TWCHTTP2Block.PushData(Strings: TStrings);
var ToSend : String;
    L : LongInt;
begin
  ToSend := Strings.Text;
  L := Length(ToSend);
  PushData(Pointer(@(ToSend[1])), L);
end;

constructor TWCHTTP2Block.Create(aConnection: TWCHTTP2Connection;
  aStream: TWCHTTPStream);
begin
  FCurDataBlock := nil;
  FDataBlockSize := 0;
  FConnection := aConnection;
  FStream := aStream;
end;

destructor TWCHTTP2Block.Destroy;
begin
  if Assigned(FCurDataBlock) then FreeMem(FCurDataBlock);
  inherited Destroy;
end;

{ TWCHTTPRefConnections }

{$ifdef SOCKET_EPOLL_MODE}

procedure TWCHTTPRefConnections.Inflate;
var
  OldLength: Integer;
begin
  FEpollLocker.Lock;
  try
    OldLength := Length(FEvents);
    if OldLength > 1 then
      SetLength(FEvents, Sqr(OldLength))
    else
      SetLength(FEvents, BASE_SIZE);
    SetLength(FEventsRead, Length(FEvents));
  finally
    FEpollLocker.UnLock;
  end;
end;

procedure TWCHTTPRefConnections.CallActionEpoll(aCount: Integer);
var
  i, MasterChanges, Changes, ReadChanges, m, err: Integer;
  Temp, TempRead: TWCHTTPSocketReference;
  MasterEvents: array[0..1] of TEpollEvent;
begin
  if aCount <= 0 then exit;

  Changes := 0;
  ReadChanges := 0;

  repeat
    MasterChanges := epoll_wait(FEpollMasterFD, @MasterEvents[0], 2, FTimeout);
    err := fpgeterrno;
  until (MasterChanges >= 0) or (err <> ESysEINTR);

  if MasterChanges <= 0 then
  begin
    if (MasterChanges < 0) and (err <> 0) and (err <> ESysEINTR) then
      raise ESocketError.CreateFmt('Error on epoll %d', [err]);
  end else
  begin
    FEpollLocker.Lock;
    try
      err := 0;
      for i := 0 to MasterChanges - 1 do begin
        if MasterEvents[i].Data.fd = FEpollFD then
        begin
          repeat
            Changes := epoll_wait(FEpollFD, @FEvents[0], aCount, 0);
            err := fpgeterrno;
          until (Changes >= 0) or (err <> ESysEINTR);
        end
        else
          repeat
            ReadChanges := epoll_wait(FEpollReadFD, @FEventsRead[0], aCount, 0);
            err := fpgeterrno;
          until (ReadChanges >= 0) or (err <> ESysEINTR);
      end;
      if (Changes < 0) or (ReadChanges < 0) then
      begin
        if (err <> 0) and (err <> ESysEINTR) then
          raise ESocketError.CreateFmt('Error on epoll %d', [err]);
      end else
      begin
        m := Changes;
        if ReadChanges > m then m := ReadChanges;
        for i := 0 to m - 1 do begin
          Temp := nil;
          if i < Changes then begin
            Temp := TWCHTTPSocketReference(FEvents[i].data.ptr);

            if  ((FEvents[i].events and EPOLLOUT) = EPOLLOUT) then
                Temp.SetCanSend;

            if  ((FEvents[i].events and EPOLLERR) = EPOLLERR) then
                Temp.PushError;// 'Handle error' + Inttostr(SocketError));
          end; // writes

          if i < ReadChanges then begin
            TempRead := TWCHTTPSocketReference(FEventsRead[i].data.ptr);

            if  ((FEventsRead[i].events and (EPOLLIN or EPOLLHUP or EPOLLPRI)) > 0) then
                TempRead.SetCanRead;
          end; // reads
        end;
      end;
    finally
      FEpollLocker.UnLock;
    end;
  end;
end;

procedure TWCHTTPRefConnections.AddSocketEpoll(ASocket: TWCHTTPSocketReference);
var
  lEvent: TEpollEvent;
begin
  ASocket.IncReference;
  lEvent.events := EPOLLET or EPOLLOUT or EPOLLERR;
  lEvent.data.ptr := ASocket;
  if epoll_ctl(FEpollFD, EPOLL_CTL_ADD, ASocket.FSocket.Handle, @lEvent) < 0 then
    raise ESocketError.CreateFmt('Error adding handle to epoll', [SocketError]);
  lEvent.events := EPOLLIN or EPOLLPRI or EPOLLHUP or EPOLLET or EPOLLONESHOT;
  if epoll_ctl(FEpollReadFD, EPOLL_CTL_ADD, ASocket.FSocket.Handle, @lEvent) < 0 then
    raise ESocketError.CreateFmt('Error adding handle to epoll', [SocketError]);
  if Count > High(FEvents) then
    Inflate;
end;

procedure TWCHTTPRefConnections.RemoveSocketEpoll(ASocket: TWCHTTPSocketReference);
begin
  try
    epoll_ctl(FEpollFD, EPOLL_CTL_DEL, ASocket.FSocket.Handle, nil);
    epoll_ctl(FEpollReadFD, EPOLL_CTL_DEL, ASocket.FSocket.Handle, nil);
  finally
    ASocket.DecReference;
  end;
end;

procedure TWCHTTPRefConnections.ResetReadingSocket(
  ASocket: TWCHTTPSocketReference);
var
  lEvent: TEpollEvent;
begin
  lEvent.data.ptr := ASocket;
  lEvent.events := EPOLLIN or EPOLLPRI or EPOLLHUP or EPOLLET or EPOLLONESHOT;
  if epoll_ctl(FEpollReadFD, EPOLL_CTL_MOD, ASocket.FSocket.Handle, @lEvent) < 0 then
    raise ESocketError.CreateFmt('Error modify handle in epoll', [SocketError]);
end;

{$endif}

function TWCHTTPRefConnections.IsConnDead(aConn: TObject; data: pointer
  ): Boolean;
begin
  with TWCHTTPRefConnection(aConn) do
  Result := (GetLifeTime(PWCLifeTimeChecker(data)^.CurTime) > PWCLifeTimeChecker(data)^.MaxLifeTime) or
            (ConnectionState <> wcCONNECTED);
end;

procedure TWCHTTPRefConnections.AfterConnExtracted(aObj: TObject);
begin
  {$ifdef SOCKET_EPOLL_MODE}
  RemoveSocketEpoll(TWCHTTPRefConnection(aObj).FSocketRef);
  {$endif}
  TWCHTTPRefConnection(aObj).DecReference;
end;

constructor TWCHTTPRefConnections.Create(aGarbageCollector: TNetReferenceList);
{$ifdef SOCKET_EPOLL_MODE}
var lEvent : TEpollEvent;
{$endif}
begin
  inherited Create;
  FNeedToRemoveDeadConnections := TThreadBoolean.Create(false);
  FMaintainStamp := GetTickCount64;
  FLastUsedConnection := nil;
  FGarbageCollector := aGarbageCollector;
  FSettings := TWCHTTP2ServerSettings.Create;
  {$ifdef SOCKET_EPOLL_MODE}
  FEpollLocker := TNetCustomLockedObject.Create;
  Inflate;
  FTimeout := 1;
  FEpollFD := epoll_create(BASE_SIZE);
  FEpollReadFD := epoll_create(BASE_SIZE);
  FEpollMasterFD := epoll_create(2);
  if (FEPollFD < 0) or (FEpollReadFD < 0) or (FEpollMasterFD < 0) then
    raise ESocketError.CreateFmt('Unable to create epoll: %d', [fpgeterrno]);
  lEvent.events := EPOLLIN or EPOLLOUT or EPOLLPRI or EPOLLERR or EPOLLHUP or EPOLLET;
  lEvent.data.fd := FEpollFD;
  if epoll_ctl(FEpollMasterFD, EPOLL_CTL_ADD, FEpollFD, @lEvent) < 0 then
    raise ESocketError.CreateFmt('Unable to add FDs to master epoll FD: %d', [fpGetErrno]);
  lEvent.data.fd := FEpollReadFD;
  if epoll_ctl(FEpollMasterFD, EPOLL_CTL_ADD, FEpollReadFD, @lEvent) < 0 then
    raise ESocketError.CreateFmt('Unable to add FDs to master epoll FD: %d', [fpGetErrno]);
  {$endif}
end;

destructor TWCHTTPRefConnections.Destroy;
var P :TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      TWCHTTPRefConnection(P.Value).DecReference;
      P := P.Next;
    end;
    ExtractAll;
  finally
    UnLock;
  end;
  {$ifdef SOCKET_EPOLL_MODE}
  fpClose(FEpollFD);
  FEpollLocker.Free;
  {$endif}
  FSettings.Free;
  FNeedToRemoveDeadConnections.Free;
  inherited Destroy;
end;

procedure TWCHTTPRefConnections.AddConnection(FConn: TWCHTTPRefConnection);
begin
  Push_back(FConn);
  {$ifdef socket_epoll_mode}
  AddSocketEpoll(FConn.FSocketRef);
  {$endif}
end;

function TWCHTTPRefConnections.GetByHandle(aSocket: Cardinal): TWCHTTPRefConnection;
var P :TIteratorObject;
begin
  Result := nil;
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      if (TWCHTTPRefConnection(P.Value).Socket = aSocket) and
         (TWCHTTPRefConnection(P.Value).ConnectionState = wcCONNECTED) then
      begin
        Result := TWCHTTPRefConnection(P.Value);
        Result.IncReference;
        Break;
      end;
      P := P.Next;
    end;
  finally
    UnLock;
  end;
end;

procedure TWCHTTPRefConnections.RemoveDeadConnections(const TS : QWord;
  MaxLifeTime: Cardinal);
var LifeTime : TWCLifeTimeChecker;
begin
  FNeedToRemoveDeadConnections.Value := false;
  LifeTime.CurTime := TS;
  LifeTime.MaxLifeTime := MaxLifeTime;
  ExtractObjectsByCriteria(@IsConnDead, @AfterConnExtracted, @LifeTime);
end;

procedure TWCHTTPRefConnections.Idle(const TS : QWord);
var P :TIteratorObject;
    i : integer;
begin
  if ((TS - FMaintainStamp) div 1000 > 10) or
     (FNeedToRemoveDeadConnections.Value) then
  begin
    RemoveDeadConnections(TS, 120);
    FMaintainStamp := TS;
  end;
  {$ifdef SOCKET_EPOLL_MODE}
  CallActionEpoll(Count);
  {$endif}
  Lock;
  try
    P := ListBegin;
    if assigned(FLastUsedConnection) then
    while assigned(P) do
    begin
      if (P = FLastUsedConnection) then begin
        break;
      end else begin
        P := P.Next;
        if not assigned(P) then begin
          P := ListBegin;
          break;
        end;
      end;
    end;
    i := 0;
    while assigned(P) do
    begin
      if (TWCHTTPRefConnection(P.Value).ConnectionState = wcCONNECTED) then
      begin
        if ssError in TWCHTTPRefConnection(P.Value).FSocketRef.States then
          TWCHTTPRefConnection(P.Value).ConnectionState:= wcDROPPED else
        if TWCHTTPRefConnection(P.Value).TryToIdleStep(TS) then
        begin
          FLastUsedConnection := P.Next;
          inc(i);
          if i > 15 then break;
        end;
      end;
      P := P.Next;
    end;
  finally
    UnLock;
  end;
end;

procedure TWCHTTPRefConnections.PushSocketError;
begin
  FNeedToRemoveDeadConnections.Value := True;
end;

{ TWCHTTPRefConnection }

procedure TWCHTTPRefConnection.SetConnectionState(CSt: TWCConnectionState);
begin
  if ConnectionState <> CSt then
  begin
    FConnectionState.Value := Cst;
    if Cst = wcDROPPED then begin
      FOwner.PushSocketError;
      FSocketRef.PushError;
    end;
  end;
end;

function TWCHTTPRefConnection.GetConnectionState: TWCConnectionState;
begin
  Result := FConnectionState.Value;
end;

function TWCHTTPRefConnection.ReadyToReadWrite(const TS: QWord): Boolean;
begin
  Result := ReadyToRead(TS) or ReadyToWrite(TS);
end;

function TWCHTTPRefConnection.ReadyToRead(const TS: QWord): Boolean;
begin
  Result := ((Int64(TS) - Int64(FReadStamp.Value)) > FReadDelay.Value) and
            (not FDataReading.Value);
end;

function TWCHTTPRefConnection.ReadyToWrite(const TS: QWord): Boolean;
begin
  Result := ((Int64(TS) - Int64(FWriteStamp.Value)) > FWriteDelay.Value) and
            (not FDataSending.Value) and
            ((FFramesToSend.Count > 0) or (FWriteTailSize > 0));
end;

function TWCHTTPRefConnection.GetLifeTime(const TS: QWord): Cardinal;
begin
  Result := (Int64(TS) - Int64(FTimeStamp.Value)) div 1000;
end;

procedure TWCHTTPRefConnection.Refresh(const TS: QWord);
begin
  FTimeStamp.Value := TS;
end;

constructor TWCHTTPRefConnection.Create(aOwner: TWCHTTPRefConnections;
  aSocket: TWCHTTPSocketReference;
  aSocketConsume: THttpRefSocketConsume; aSendData: THttpRefSendData);
var TS : QWord;
begin
  inherited Create;
  FReadBuffer := nil;
  FWriteBuffer := nil;
  FOwner := aOwner;
  FSocketRef := aSocket;
  FSocketRef.IncReference;
  FSocket:= FSocketRef.Socket.Handle;
  TS := GetTickCount64;
  FTimeStamp := TThreadQWord.Create(TS);
  FReadTailSize := 0;
  FWriteTailSize:= 0;
  FSocketConsume:= aSocketConsume;
  FSendData := aSendData;
  FDataSending := TThreadBoolean.Create(false);
  FDataReading := TThreadBoolean.Create(false);
  FReadStamp := TThreadQWord.Create(TS);
  FWriteStamp:= TThreadQWord.Create(TS);
  FReadDelay := TThreadInteger.Create(0);
  FWriteDelay := TThreadInteger.Create(0);
  FFramesToSend := TThreadSafeFastSeq.Create;
  FConnectionState := TThreadSafeConnectionState.Create(wcCONNECTED);
end;

procedure TWCHTTPRefConnection.ReleaseRead(WithSuccess : Boolean);
begin
  FDataReading.Value := false;
  {$ifdef SOCKET_EPOLL_MODE}
  FOwner.ResetReadingSocket(FSocketRef);
  {$endif}
  if WithSuccess then
  begin
    Refresh(GetTickCount64);
    RelaxDelayValue(FReadDelay);
  end else
    HoldDelayValue(FReadDelay);
end;

destructor TWCHTTPRefConnection.Destroy;
begin
  FConnectionState.Value:= wcDEAD;
  if assigned(FSocketRef) then FSocketRef.DecReference;
  FFramesToSend.Free;
  if assigned(FReadBuffer) then FReadBuffer.Free;
  if assigned(FWriteBuffer) then FWriteBuffer.Free;
  FReadStamp.Free;
  FWriteStamp.Free;
  FTimeStamp.Free;
  FConnectionState.Free;
  FDataSending.Free;
  FDataReading.Free;
  FReadDelay.Free;
  FWriteDelay.Free;
  inherited Destroy;
end;

class function TWCHTTPRefConnection.CheckProtocolVersion(Data: Pointer; sz: integer
  ): TWCProtocolVersion;
begin
  if sz >= H2P_PREFACE_SIZE then
  begin
    if CompareByte(Data^, HTTP2Preface[0], H2P_PREFACE_SIZE) = 0 then
    begin
      Result:=wcHTTP2;
    end else
    begin
      if (PByteArray(Data)^[0] in HTTP1HeadersAllowed) then
        Result:=wcHTTP1 else
        Result:=wcUNK; // other protocol
    end;
  end else Result:= wcUNK;
end;

procedure TWCHTTPRefConnection.PushFrame(fr: TWCHTTPRefProtoFrame);
begin
  FFramesToSend.Push_back(fr);
end;

procedure TWCHTTPRefConnection.PushFrame(const S: String);
begin
  PushFrame(TWCHTTPStringFrame.Create(S));
end;

procedure TWCHTTPRefConnection.PushFrame(Strm: TStream; Sz: Cardinal;
  Owned: Boolean);
begin
  PushFrame(TWCHTTPStreamFrame.Create(Strm, Sz, Owned));
end;

procedure TWCHTTPRefConnection.PushFrame(Strs: TStrings);
begin
  PushFrame(TWCHTTPStringsFrame.Create(Strs));
end;

procedure TWCHTTPRefConnection.PushFrame(Strm: TReferencedStream);
begin
  PushFrame(TWCHTTPRefStreamFrame.Create(Strm));
end;

procedure TWCHTTPRefConnection.SendFrames;
var fr : TWCHTTPRefProtoFrame;
    it : TIteratorObject;
    WrBuf : TBufferedStream;
    Sz : Integer;
    CurBuffer : Pointer;
    FrameCanSend : Boolean;
begin
  WrBuf := TBufferedStream.Create;
  try
    FWriteBuffer.Lock;
    try
      CurBuffer := FWriteBuffer.Value;
      WrBuf.SetPointer(Pointer(CurBuffer + FWriteTailSize),
                                             FWriteBufferSize - FWriteTailSize);
      FFramesToSend.Lock;
      try
        repeat
           fr := nil;
           it := FFramesToSend.ListBegin;
           if Assigned(it) then begin

             FrameCanSend := true;

             if (TWCHTTPRefProtoFrame(it.Value).Size >
                                       (WrBuf.Size - WrBuf.Position)) then
             begin
               Sz := WrBuf.Position + TWCHTTPRefProtoFrame(it.Value).Size;
               if CanExpandWriteBuffer(FWriteBufferSize, Sz) then
               begin
                 FWriteBufferSize := Sz;
                 CurBuffer:= ReAllocMem(CurBuffer, FWriteBufferSize);
                 Sz := WrBuf.Position;
                 WrBuf.SetPointer(Pointer(CurBuffer + FWriteTailSize),
                                             FWriteBufferSize - FWriteTailSize);
                 WrBuf.Position := Sz;
               end else
                  FrameCanSend := false
             end;

             if FrameCanSend then
             begin
               fr := TWCHTTPRefProtoFrame(FFramesToSend.PopValue);
               if Assigned(fr) then begin
                 fr.SaveToStream(WrBuf);
                 fr.Free;
               end;
             end else
               Break;
           end;
        until not assigned(fr);
      finally
        FFramesToSend.UnLock;
      end;
      try
        if ((WrBuf.Position > 0) or (FWriteTailSize > 0)) then
        begin
          Sz := FSocketRef.Write(CurBuffer^, WrBuf.Position + FWriteTailSize);
          if Sz < WrBuf.Position then
          begin
            if Sz < 0 then Sz := 0; // ignore non-fatal errors. rollback to tail
            FWriteTailSize := WrBuf.Position + FWriteTailSize - Sz;
            if Sz > 0 then
              Move(Pointer(CurBuffer + Sz)^, CurBuffer^, FWriteTailSize);
            HoldDelayValue(FWriteDelay);
          end else begin
            FWriteTailSize:= 0;
            RelaxDelayValue(FWriteDelay);
          end;
        end;
      except
        ConnectionState:= wcDROPPED;
      end;
    finally
      FWriteBuffer.UnLock;
    end;
  finally
    WrBuf.Free;
    FDataSending.Value := false;
  end;
end;

function TWCHTTPRefConnection.TryToIdleStep(const TS : Qword): Boolean;
begin
  Result := false;
  if assigned(FSocketRef) and ReadyToReadWrite(TS) then
  begin
    {$ifdef socket_select_mode}
    FSocketRef.GetSocketStates;
    if ssError in FSocketRef.States then
    begin
      ConnectionState:= wcDROPPED;
      Exit;
    end;
    {$endif}
    TryToSendFrames(TS);
    TryToConsumeFrames(TS);
    Result := true;
  end;
end;

procedure TWCHTTPRefConnection.TryToConsumeFrames(const TS: Qword);
begin
  if (FSocketRef.CanRead or RequestsWaiting) and
      ReadyToRead(TS) and
      assigned(FSocketConsume) then
  begin
    FDataReading.Value := True;
    FReadStamp.Value := TS;
    FSocketConsume(FSocketRef);
  end;
end;

procedure TWCHTTPRefConnection.TryToSendFrames(const TS: Qword);
begin
  if FSocketRef.CanSend and
     ReadyToWrite(TS) then
  begin
    FDataSending.Value := True;
    Refresh(TS);
    FWriteStamp.Value  := TS;
    if assigned(FSendData) then
       FSendData(Self) else
       SendFrames;
  end;
end;

procedure TWCHTTPRefConnection.InitializeBuffers;
var SZ : Cardinal;
begin
  SZ := GetInitialReadBufferSize;
  if SZ > 0 then
    FReadBuffer := TThreadPointer.Create(SZ) else
    FReadBuffer := nil;
  FReadBufferSize:= SZ;
  SZ := GetInitialWriteBufferSize;
  if SZ > 0 then
    FWriteBuffer := TThreadPointer.Create(SZ) else
    FWriteBuffer := nil;
  FWriteBufferSize:= SZ;
end;

procedure TWCHTTPRefConnection.HoldDelayValue(aDelay: TThreadInteger);
begin
  aDelay.Lock;
  try
    if aDelay.Value = 0 then
      aDelay.Value := 16 else
    begin
      aDelay.Value := aDelay.Value * 2;
      if (aDelay.Value > 512) then aDelay.Value := 512;
    end;
  finally
    aDelay.UnLock;
  end;
end;

procedure TWCHTTPRefConnection.RelaxDelayValue(aDelay: TThreadInteger);
begin
  aDelay.Lock;
  try
    aDelay.Value := aDelay.Value div 2;
  finally
    aDelay.UnLock;
  end;
end;

{ TWCHTTP2Connection }

function TWCHTTP2Connection.AddNewStream(aStreamID : Cardinal): TWCHTTPStream;
begin
  Result := TWCHTTPStream.Create(Self, aStreamID);
  FStreams.Push_back(Result);
  FOwner.GarbageCollector.Add(Result);
end;

function TWCHTTP2Connection.GetConnSetting(id : Word): Cardinal;
begin
  Result := FConSettings[id];
end;

constructor TWCHTTP2Connection.Create(aOwner: TWCHTTPRefConnections;
  aSocket: TWCHTTPSocketReference; aOpenningMode: THTTP2OpenMode;
  aSocketConsume: THttpRefSocketConsume; aSendData: THttpRefSendData);
var i, Sz : integer;
    CSet : PHTTP2SettingsPayload;
begin
  inherited Create(aOwner, aSocket, aSocketConsume, aSendData);
  FStreams := TWCHTTPStreams.Create;
  FLastStreamID := 0;
  FConSettings := TThreadSafeConnSettings.Create;
  for i := 1 to HTTP2_SETTINGS_MAX do
    FConSettings[i] := HTTP2_SET_INITIAL_VALUES[i];
  FOwner.HTTP2Settings.Lock;
  try
    with FOwner.HTTP2Settings do
    for i := 0 to Count-1 do
    begin
      FConSettings[Setting[i].Identifier] := Setting[i].Value;
    end;
  finally
    FOwner.HTTP2Settings.UnLock;
  end;
  InitializeBuffers;

  // send initial settings frame
  if aOpenningMode in [h2oUpgradeToH2C, h2oUpgradeToH2] then
    PushFrame(TWCHTTP2UpgradeResponseFrame.Create(aOpenningMode));
  Sz := FOwner.HTTP2Settings.CopySettingsToMem(Cset);
  PushFrame(TWCHTTP2DataFrame.Create(H2FT_SETTINGS, 0, 0, CSet,  Sz));
end;

class function TWCHTTP2Connection.Protocol: TWCProtocolVersion;
begin
  Result := wcHTTP2;
end;

procedure TWCHTTP2Connection.ConsumeNextFrame(Mem: TBufferedStream);
var
  ReadLoc, MemSz : Int64;

function ReadMore(WriteAt, AddSz : Int64) : Int64;
var R : Integer;
   Src : Pointer;
begin
  R := AddSz;
  Result := WriteAt;
  While (AddSz > 0) and (R > 0) do
  begin
    if ReadLoc < MemSz then
    begin
      R := MemSz - ReadLoc;
      Src := Pointer(Mem.Memory + Mem.Position + ReadLoc);
      if AddSz < R then R := AddSz;
      Move(Src^, PByte(FReadBuffer.Value)[Result], R);
    end
    else
    begin
      R:=FSocketRef.Read(PByte(FReadBuffer.Value)[Result], AddSz);
      If R < 0 then
        break;
    end;
    if R > 0 then begin
      Dec(AddSz, R);
      Inc(ReadLoc, R);
      Inc(Result, R);
    end else break;
  end;
end;

var
  Sz, fallbackpos, L, R : Int64;
  err : Byte;
  Buffer : Pointer;
  FrameHeader : TWCHTTP2FrameHeader;
  S : TBufferedStream;
  Str, RemoteStr : TWCHTTPStream;

function TruncReadBuffer : Int64;
begin
  Result := S.Size - S.Position;
  if Result > 0 then
     Move(PByte(FReadBuffer)[S.Position], FReadBuffer.Value^, Result);
end;

function ProceedHeadersPayload(Strm : TWCHTTPStream; aSz : Cardinal) : Byte;
var readbuf : TBufferedStream;
    aDecoder : TThreadSafeHPackDecoder;
begin
  Result := H2E_NO_ERROR;
  //hpack here
  InitHPack;
  aDecoder := CurHPackDecoder;
  aDecoder.IncReference;
  readbuf := TBufferedStream.Create;
  try
    readbuf.SetPointer(Pointer(S.Memory + S.Position),
                       aSz);
    try
      aDecoder.Decode(readbuf);
      if (FrameHeader.FrameFlag and H2FL_END_HEADERS) > 0 then
      begin
        if aDecoder.EndHeaderBlockTruncated then
           Result := H2E_COMPRESSION_ERROR;
        Strm.FinishHeaders(aDecoder);
      end;
    except
      on e : Exception do
        Result := H2E_COMPRESSION_ERROR;
    end;
  finally
    readbuf.Free;
    aDecoder.DecReference;
  end;
end;

procedure CheckStreamAfterState(Strm : TWCHTTPStream);
begin
  if (FrameHeader.FrameFlag and H2FL_END_STREAM) > 0 then
  begin
    if Strm.FStreamState = h2ssOPEN then
    begin
       Strm.FStreamState := h2ssHLFCLOSEDRem;
       Strm.PushRequest;
    end;
  end;
end;

var B : Byte;
    DataSize : Integer;
    RemoteID : Cardinal;
    WV: Word;
    SettFrame : THTTP2SettingsBlock;
begin
  Str := nil; RemoteStr := nil;
  if assigned(Mem) then begin
    MemSz := Mem.Size - Mem.Position;
    Sz := MemSz;
  end else begin
    Sz := WC_INITIAL_READ_BUFFER_SIZE;
  end;

  FReadBuffer.Lock;
  try
    FrameHeader := TWCHTTP2FrameHeader.Create;
    S := TBufferedStream.Create;
    try
      if Sz > (FReadBufferSize - FReadTailSize) then
         Sz := (FReadBufferSize - FReadTailSize);
      if Sz = 0 then
      begin
        err := H2E_READ_BUFFER_OVERFLOW;
        exit;
      end;
      ReadLoc := 0;
      Sz := ReadMore(FReadTailSize, Sz);
      if ReadLoc = 0 then begin
        err := H2E_INTERNAL_ERROR;
        Exit;
      end;
      S.SetPointer(FReadBuffer.Value, Sz);

      err := H2E_NO_ERROR;
      while true do
      begin
        if (S.Size - S.Position) < H2P_FRAME_HEADER_SIZE then
        begin
          L := TruncReadBuffer;
          Sz := ReadMore(L, Sz);
          if Sz < H2P_FRAME_HEADER_SIZE then begin
            fallbackpos := 0;
            err := H2E_PARSE_ERROR;
            break;
          end;
          S.SetPointer(FReadBuffer.Value, Sz);
        end;
        fallbackpos := S.Position;
        // read header
        FrameHeader.LoadFromStream(S);
        // find stream
        if assigned(Str) then Str.DecReference;
        if assigned(RemoteStr) then RemoteStr.DecReference;
        RemoteStr := nil;
        if FrameHeader.StreamID > 0 then
        begin
          if FrameHeader.StreamID <= FLastStreamID then
          begin
            Str := FStreams.GetByID(FrameHeader.StreamID);
            if not Assigned(Str) then
            begin
              err := H2E_FLOW_CONTROL_ERROR;
              break;
            end;
          end else begin
            FLastStreamID := FrameHeader.StreamID;
            if FrameHeader.FrameType in [H2FT_DATA, H2FT_HEADERS,
                                         H2FT_CONTINUATION] then
               FStreams.CloseOldIdleStreams(FLastStreamID);
            Str := AddNewStream(FLastStreamID);
            Str.IncReference;
          end;
          if Assigned(Str) then Str.UpdateState(FrameHeader);
        end else
          Str := nil;

        R := FConSettings[H2SET_MAX_FRAME_SIZE];

        if (FrameHeader.PayloadLength + H2P_FRAME_HEADER_SIZE) > R then
        begin
          err := H2E_FRAME_SIZE_ERROR;
          break;
        end;

        if (FrameHeader.PayloadLength > (S.Size - S.Position)) then
        begin
          // try to load rest octets for frame
          S.Position := fallbackpos; // truncate to the begining of the frame
          L := TruncReadBuffer;
          if L <> H2P_FRAME_HEADER_SIZE then
          begin
            err := H2E_INTERNAL_ERROR;
            break;
          end;
          Sz := ReadMore(H2P_FRAME_HEADER_SIZE, R);
          if (Sz - H2P_FRAME_HEADER_SIZE) < FrameHeader.PayloadLength then
          begin
            fallbackpos := 0;
            err := H2E_PARSE_ERROR;
            break;
          end;
          S.SetPointer(FReadBuffer.Value, Sz);
          S.Position:= H2P_FRAME_HEADER_SIZE; // to payload begining
        end;
        if err = H2E_NO_ERROR then
        begin
          if Assigned(Str) and
             Str.FWaitingForContinueFrame and
             (FrameHeader.FrameType <> H2FT_CONTINUATION) then
          begin
            err := H2E_PROTOCOL_ERROR;
            break;
          end;
          if (not Assigned(Str)) and
             (FrameHeader.FrameType in [H2FT_DATA,
                                        H2FT_CONTINUATION,
                                        H2FT_HEADERS,
                                        H2FT_PRIORITY,
                                        H2FT_RST_STREAM,
                                        H2FT_PUSH_PROMISE]) then
          begin
            err := H2E_PROTOCOL_ERROR; // sec.6.1-6.4,6.6
            break;
          end;
          if Assigned(Str) and
             (FrameHeader.FrameType in [H2FT_PING, H2FT_SETTINGS]) then
          begin
            err := H2E_PROTOCOL_ERROR; // sec.6.5, 6.7
            break;
          end;
          // payload fully loaded
          case FrameHeader.FrameType of
            H2FT_DATA : begin
              if not (Str.StreamState in [h2ssOPEN, h2ssHLFCLOSEDLoc]) then
              begin
                err := H2E_STREAM_CLOSED;
                break;
              end;
              DataSize := FrameHeader.PayloadLength;
              if FrameHeader.FrameFlag and H2FL_PADDED > 0 then
              begin
                B := 0;
                S.Read(B, H2P_PADDING_OCTET_SIZE);
                DataSize := DataSize - B;
              end;
              if DataSize < 0 then begin
                err := H2E_INTERNAL_ERROR;
                break;
              end;
              //
              Str.PushData(Pointer(S.Memory + S.Position), DataSize);
              S.Position := S.Position + FrameHeader.PayloadLength;
              CheckStreamAfterState(Str);
            end;
            H2FT_HEADERS : begin
              if not (Str.StreamState in [h2ssIDLE,
                                          h2ssRESERVEDLoc,
                                          h2ssOPEN,
                                          h2ssHLFCLOSEDRem]) then
              begin
                err := H2E_STREAM_CLOSED;
                break;
              end;
              DataSize := FrameHeader.PayloadLength;
              if FrameHeader.FrameFlag and H2FL_PADDED > 0 then
              begin
                B := 0;
                S.Read(B, H2P_PADDING_OCTET_SIZE);
                DataSize := DataSize - B;
              end;
              if FrameHeader.FrameFlag and H2FL_PRIORITY > 0 then
              begin
                B := 0;
                S.Read(Str.FParentStream, H2P_STREAM_ID_SIZE);
                Str.FParentStream := BETON(Str.FParentStream) and H2P_STREAM_ID_MASK;
                S.Read(Str.FPriority, H2P_PRIORITY_WEIGHT_SIZE);
                Str.ResetRecursivePriority;
                DataSize := DataSize - H2P_PRIORITY_FRAME_SIZE;
              end;
              if DataSize < 0 then begin
                err := H2E_INTERNAL_ERROR;
                break;
              end;
              err := ProceedHeadersPayload(Str, DataSize);
              if err <> H2E_NO_ERROR then break;
              Str.WaitingForContinueFrame := (FrameHeader.FrameFlag and
                                              H2FL_END_HEADERS) = 0;
              // END_STREAM react here
              CheckStreamAfterState(Str);
            end;
            H2FT_PUSH_PROMISE : begin
              if not (Str.StreamState in [h2ssOPEN,
                                          h2ssHLFCLOSEDLoc]) then
              begin
                err := H2E_STREAM_CLOSED;
                break;
              end;
              DataSize := FrameHeader.PayloadLength;
              if FrameHeader.FrameFlag and H2FL_PADDED > 0 then
              begin
                B := 0;
                S.Read(B, H2P_PADDING_OCTET_SIZE);
                DataSize := DataSize - B;
              end;
              if DataSize < H2P_STREAM_ID_SIZE then begin
                err := H2E_FRAME_SIZE_ERROR;
                break;
              end;
              RemoteID := 0;
              S.Read(RemoteID, H2P_STREAM_ID_SIZE);
              RemoteID := BETON(RemoteID);
              DataSize := DataSize - H2P_STREAM_ID_SIZE;
              if RemoteID = 0 then
              begin
                err := H2E_PROTOCOL_ERROR;
                break;
              end;
              RemoteStr := FStreams.GetByID(RemoteID);
              if assigned(RemoteStr) then
              begin
                if not (RemoteStr.StreamState = h2ssIDLE) then
                begin
                  err := H2E_PROTOCOL_ERROR;
                  break;
                end;
              end else
              if RemoteID <= FLastStreamID then
              begin
                err := H2E_FLOW_CONTROL_ERROR;
                break;
              end else begin
                FLastStreamID := RemoteID;
                RemoteStr := AddNewStream(FLastStreamID);
                RemoteStr.IncReference;
                RemoteStr.FStreamState:=h2ssRESERVEDRem;
              end;
              err := ProceedHeadersPayload(RemoteStr, DataSize);
              if err <> H2E_NO_ERROR then break;
              Str.WaitingForContinueFrame := (FrameHeader.FrameFlag and
                                              H2FL_END_HEADERS = 0);
              RemoteStr.WaitingForContinueFrame := Str.WaitingForContinueFrame;
              Str.FWaitingRemoteStream := RemoteID;
            end;
            H2FT_CONTINUATION : begin
                if not Str.FWaitingForContinueFrame then
                begin
                  err := H2E_PROTOCOL_ERROR;
                  break;
                end;
                if Str.FWaitingRemoteStream <> Str.FID then
                begin
                  RemoteStr := FStreams.GetByID(Str.FWaitingRemoteStream);
                  if not assigned(RemoteStr) then
                  begin
                    err := H2E_STREAM_CLOSED;
                    break;
                  end;
                  if not RemoteStr.FWaitingForContinueFrame then
                  begin
                    err := H2E_INTERNAL_ERROR;
                    break;
                  end;
                  err := ProceedHeadersPayload(RemoteStr, FrameHeader.PayloadLength);
                  if err <> H2E_NO_ERROR then break;
                end else
                begin
                  err := ProceedHeadersPayload(Str, FrameHeader.PayloadLength);
                  if err <> H2E_NO_ERROR then break;
                end;
                Str.WaitingForContinueFrame := (FrameHeader.FrameFlag and
                                                H2FL_END_HEADERS = 0);
                if assigned(RemoteStr) then begin
                  RemoteStr.WaitingForContinueFrame := Str.WaitingForContinueFrame;
                  if not Str.FWaitingForContinueFrame then
                    Str.FWaitingRemoteStream := Str.FID;
                  CheckStreamAfterState(RemoteStr);
                end else
                  CheckStreamAfterState(Str);
              end;
            H2FT_PRIORITY : begin
              if FrameHeader.PayloadLength <> H2P_PRIORITY_FRAME_SIZE then begin
                err := H2E_FRAME_SIZE_ERROR;
                break;
              end;
              S.Read(Str.FParentStream, H2P_STREAM_ID_SIZE);
              Str.FParentStream := BETON(Str.FParentStream) and H2P_STREAM_ID_MASK;
              S.Read(Str.FPriority, H2P_PRIORITY_WEIGHT_SIZE);
              Str.ResetRecursivePriority;
            end;
            H2FT_RST_STREAM : begin
              if not Assigned(Str) then
              begin
                err := H2E_PROTOCOL_ERROR;
                break;
              end;
              if FrameHeader.PayloadLength <> H2P_RST_STREAM_FRAME_SIZE then begin
                err := H2E_FRAME_SIZE_ERROR;
                break;
              end;
              S.Read(Str.FFinishedCode, H2P_ERROR_CODE_SIZE);
              Str.FFinishedCode := BETON(Str.FFinishedCode);
              Str.FStreamState := h2ssCLOSED;
            end;
            H2FT_SETTINGS : begin
              if (FrameHeader.FrameFlag and H2FL_ACK) > 0 then
              begin
                if FrameHeader.PayloadLength > 0 then
                begin
                  err := H2E_FRAME_SIZE_ERROR;
                  break;
                end;
              end else
              begin
                if FrameHeader.PayloadLength mod H2P_SETTINGS_BLOCK_SIZE > 0 then
                begin
                  err := H2E_FRAME_SIZE_ERROR;
                  break;
                end;

                DataSize := FrameHeader.PayloadLength;

                while DataSize > 0 do
                begin
                  S.Read(SettFrame, H2P_SETTINGS_BLOCK_SIZE);
                  WV := SettFrame.Identifier;
                  if (WV >= 1) and
                     (WV <= HTTP2_SETTINGS_MAX) then
                  begin
                    if FConSettings[WV] <> SettFrame.Value then
                    begin
                      FConSettings[WV] := SettFrame.Value;
                      case WV of
                        H2SET_HEADER_TABLE_SIZE,
                        H2SET_MAX_HEADER_LIST_SIZE: ResetHPack;
                      end;
                    end;
                  end;
                  Dec(DataSize, H2P_SETTINGS_BLOCK_SIZE);
                end;

                // send ack settings frame
                PushFrame(H2FT_SETTINGS, 0, H2FL_ACK, nil, 0);
              end;
            end;
            H2FT_WINDOW_UPDATE : begin
              if FrameHeader.PayloadLength <> H2P_WINDOW_INC_SIZE then
              begin
                err := H2E_FRAME_SIZE_ERROR;
                break;
              end;
              S.Read(DataSize, H2P_WINDOW_INC_SIZE);
              DataSize := BETON(DataSize);
              if DataSize <= 0 then begin
                   err := H2E_PROTOCOL_ERROR;
                   break;
              end else
              if (DataSize > $ffff{?}) then begin
                   //err := H2E_FLOW_CONTROL_ERROR;
                   //break;
              end else begin
               // do nothing for yet
               // realloc the readbuffer?
              end;
            end;
            H2FT_GOAWAY : begin
              if FrameHeader.PayloadLength < H2P_GOAWAY_MIN_SIZE then
              begin
                err := H2E_FRAME_SIZE_ERROR;
                break;
              end;
              S.Read(FErrorStream, H2P_STREAM_ID_SIZE);
              FErrorStream := BETON(FErrorStream) and H2P_STREAM_ID_MASK;
              S.Read(FLastError, H2P_ERROR_CODE_SIZE);
              FLastError := BETON(FLastError);
              if FrameHeader.PayloadLength > H2P_GOAWAY_MIN_SIZE then begin
                 FErrorDataSize := FrameHeader.PayloadLength - H2P_GOAWAY_MIN_SIZE;
                 if assigned(FErrorData) then
                    FErrorData := ReallocMem(FErrorData, FErrorDataSize) else
                    FErrorData := GetMem(FErrorDataSize);
                 S.Read(FErrorData^, FErrorDataSize);
              end;
              // drop down connection
              ConnectionState := wcDROPPED;
              break;
            end;
            H2FT_PING : begin
              if FrameHeader.PayloadLength < H2P_PING_SIZE then
              begin
                err := H2E_FRAME_SIZE_ERROR;
                break;
              end;
              Buffer := GetMem(H2P_PING_SIZE);
              //fill ping buffer
              S.Read(Buffer^, H2P_PING_SIZE);
              PushFrame(H2FT_PING, 0, H2FL_ACK, Buffer, H2P_PING_SIZE);
            end;
            else
            begin
              err := H2E_PROTOCOL_ERROR;
              break;
            end;
          end;
         if err = H2E_NO_ERROR then
            S.Position := fallbackpos + H2P_FRAME_HEADER_SIZE + FrameHeader.PayloadLength;
        end;
        if (err > H2E_NO_ERROR) or (S.Position >= S.Size) then begin
          break;
        end;
      end;

      if (S.Position < S.Size) and (err = H2E_PARSE_ERROR) then
      begin
        FReadTailSize := S.Size - S.Position;
        TruncReadBuffer;
        err := H2E_NO_ERROR;
      end else
        FReadTailSize := 0;
    finally
      S.Free;
      if assigned(RemoteStr) then RemoteStr.DecReference;
      if assigned(Str) then Str.DecReference;
      if assigned(FrameHeader) then FrameHeader.Free;
      if err <> H2E_NO_ERROR then
      begin
        //send error
        Buffer := GetMem(H2P_GOAWAY_MIN_SIZE);
        //fill goaway buffer
        PHTTP2GoawayPayload(Buffer)^.LastStreamID := FLastStreamID;
        PHTTP2GoawayPayload(Buffer)^.ErrorCode    := err;
        PushFrame(H2FT_GOAWAY, 0, 0, Buffer, H2P_GOAWAY_MIN_SIZE);
      end;
    end;
  finally
    FReadBuffer.UnLock;
  end;
end;

destructor TWCHTTP2Connection.Destroy;
begin
  FStreams.Free;
  ResetHPack;
  FConSettings.Free;
  if assigned(FErrorData) then FreeMem(FErrorData);
  inherited Destroy;
end;

procedure TWCHTTP2Connection.PushFrame(aFrameType: Byte; StrID: Cardinal;
  aFrameFlags: Byte; aData: Pointer; aDataSize: Cardinal; aOwnPayload: Boolean);
begin
  PushFrame(TWCHTTP2DataFrame.Create(aFrameType, StrID, aFrameFlags, aData,
                                             aDataSize, aOwnPayload));
end;

procedure TWCHTTP2Connection.PushFrame(aFrameType: Byte; StrID: Cardinal;
  aFrameFlags: Byte; aData: TReferencedStream; aStrmPos: Int64;
  aDataSize: Cardinal);
begin
  PushFrame(TWCHTTP2RefFrame.Create(aFrameType, StrID, aFrameFlags, aData,
                                             aStrmPos, aDataSize));
end;

function TWCHTTP2Connection.PopRequestedStream: TWCHTTPStream;
begin
  Lock;
  try
    if ConnectionState = wcCONNECTED then
    begin
      Result := FStreams.GetNextStreamWithRequest;
    end else Result := nil;
  finally
    UnLock;
  end;
end;

function TWCHTTP2Connection.TryToIdleStep(const TS: Qword): Boolean;
begin
  Result:=inherited TryToIdleStep(TS);
  FStreams.RemoveClosedStreams;
end;

procedure TWCHTTP2Connection.ResetHPack;
begin
  if Assigned(FHPackEncoder) then begin
     FHPackEncoder.DecReference;
     FHPackEncoder := nil;
  end;
  if Assigned(FHPackDecoder) then begin
     FHPackDecoder.DecReference;
     FHPackDecoder := nil;
  end;
end;

procedure TWCHTTP2Connection.InitHPack;
begin
  if not Assigned(FHPackEncoder) then begin
     FHPackEncoder := TThreadSafeHPackEncoder.Create(ConnSettings[H2SET_HEADER_TABLE_SIZE]);
     FOwner.GarbageCollector.Add(FHPackEncoder);
  end;
  if not assigned(FHPackDecoder) then begin
     FHPackDecoder :=
       TThreadSafeHPackDecoder.Create(ConnSettings[H2SET_MAX_HEADER_LIST_SIZE],
                            ConnSettings[H2SET_HEADER_TABLE_SIZE]);
     FOwner.GarbageCollector.Add(FHPackDecoder);
  end;
end;

function TWCHTTP2Connection.GetInitialReadBufferSize: Cardinal;
begin
  Result := FConSettings[H2SET_INITIAL_WINDOW_SIZE];
end;

function TWCHTTP2Connection.GetInitialWriteBufferSize: Cardinal;
begin
  Result := FConSettings[H2SET_INITIAL_WINDOW_SIZE];
end;

function TWCHTTP2Connection.CanExpandWriteBuffer(aCurSize, aNeedSize: Cardinal
  ): Boolean;
begin
  Result := false;
end;

function TWCHTTP2Connection.RequestsWaiting: Boolean;
begin
  Result :=  FStreams.HasStreamWithRequest;
end;

{ TWCHTTPStreams }

function TWCHTTPStreams.IsStreamClosed(aStrm: TObject; data: pointer): Boolean;
begin
  Result := (TWCHTTPStream(aStrm).StreamState = h2ssCLOSED);
end;

procedure TWCHTTPStreams.AfterStrmExtracted(aObj: TObject);
begin
  TWCHTTPStream(aObj).DecReference;
end;

destructor TWCHTTPStreams.Destroy;
var P :TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      TWCHTTPStream(P.Value).DecReference;
      P := P.Next;
    end;
    ExtractAll;
  finally
    UnLock;
  end;
  inherited Destroy;
end;

function TWCHTTPStreams.GetByID(aID: Cardinal): TWCHTTPStream;
var P : TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      if TWCHTTPStream(P.Value).ID = aID then
      begin
        Result := TWCHTTPStream(P.Value);
        Result.IncReference;
        Break;
      end;
      P := P.Next;
    end;
  finally
    UnLock;
  end;
end;

function TWCHTTPStreams.GetNextStreamWithRequest: TWCHTTPStream;
var P : TIteratorObject;
begin
  Result := nil;
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      if TWCHTTPStream(P.Value).RequestReady then
      begin
        Result := TWCHTTPStream(P.Value);
        Result.ResponseProceed := true;
        Result.IncReference;
        Break;
      end;
      P := P.Next;
    end;
  finally
    UnLock;
  end;
end;

function TWCHTTPStreams.HasStreamWithRequest: Boolean;
var P : TIteratorObject;
begin
  Result := false;
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      if TWCHTTPStream(P.Value).RequestReady then
      begin
        Result := true;
        Break;
      end;
      P := P.Next;
    end;
  finally
    UnLock;
  end;
end;

procedure TWCHTTPStreams.CloseOldIdleStreams(aMaxId: Cardinal);
var NP, P : TIteratorObject;
begin
  // close all idle stream with id less than aMaxId
  // sec.5.1.1 IRF7540
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      NP := P.Next;
      if (TWCHTTPStream(P.Value).ID < aMaxId) and
         (TWCHTTPStream(P.Value).StreamState = h2ssIDLE) then
      begin
        Erase(P);
      end;
      P := NP;
    end;
  finally
    UnLock;
  end;
end;

procedure TWCHTTPStreams.RemoveClosedStreams;
begin
  ExtractObjectsByCriteria(@IsStreamClosed, @AfterStrmExtracted, nil);
end;

{ TWCHTTPStream }

function TWCHTTPStream.GetRecursedPriority: Byte;
begin
  if FRecursedPriority < 0 then begin
    Result := FPriority; // todo: calc priority here
    FRecursedPriority:= Result;
  end else Result := FRecursedPriority;
end;

function TWCHTTPStream.GetResponseProceed: Boolean;
begin
  Lock;
  try
    Result := FResponseProceed;
  finally
    UnLock;
  end;
end;

procedure TWCHTTPStream.ResetRecursivePriority;
begin
  FRecursedPriority := -1;
end;

procedure TWCHTTPStream.PushRequest;
begin
  FCurRequest.Complete := true;
end;

procedure TWCHTTPStream.SetResponseProceed(AValue: Boolean);
begin
  Lock;
  try
    if FResponseProceed=AValue then Exit;
    FResponseProceed:=AValue;
  finally
    UnLock;
  end;
end;

procedure TWCHTTPStream.SetWaitingForContinueFrame(AValue: Boolean);
begin
  if FWaitingForContinueFrame=AValue then Exit;
  FWaitingForContinueFrame:=AValue;
  FHeadersComplete:=not AValue;
end;

procedure TWCHTTPStream.UpdateState(Head: TWCHTTP2FrameHeader);
begin
  case FStreamState of
    h2ssIDLE : begin
     if Head.FrameType = H2FT_HEADERS then
        FStreamState := h2ssOPEN;
     end;
    h2ssRESERVEDRem : begin
     if Head.FrameType = H2FT_HEADERS then
        FStreamState := h2ssHLFCLOSEDLoc;
    end;
  end;
end;

procedure TWCHTTPStream.PushData(Data: Pointer; sz: Cardinal);
begin
  FCurRequest.PushData(Data, sz);
end;

procedure TWCHTTPStream.FinishHeaders(aDecoder: TThreadSafeHPackDecoder);
begin
  FHeadersComplete := true;
  FCurRequest.CopyHeaders(aDecoder);
end;

constructor TWCHTTPStream.Create(aConnection: TWCHTTP2Connection;
  aStreamID: Cardinal);
begin
  inherited Create;
  FID := aStreamID;
  FConnection := aConnection;
  FStreamState:=h2ssIDLE;
  FRecursedPriority:=-1;
  FFinishedCode := H2E_NO_ERROR;
  FWaitingForContinueFrame := false;
  FWaitingRemoteStream := aStreamID;
  FHeadersComplete := false;
  FCurRequest := TWCHTTP2Request.Create(FConnection, Self);
  FResponseProceed := false;
end;

destructor TWCHTTPStream.Destroy;
begin
  if assigned(FCurRequest) then FreeAndNil(FCurRequest);
  inherited Destroy;
end;

procedure TWCHTTPStream.Release;
var er : PHTTP2RstStreamPayload;
begin
  if FStreamState <> h2ssCLOSED then begin
    er := GetMem(H2P_RST_STREAM_FRAME_SIZE);
    er^.ErrorCode := H2E_NO_ERROR;
    FConnection.PushFrame(H2FT_RST_STREAM, FID, 0, er, H2P_RST_STREAM_FRAME_SIZE);
    FStreamState := h2ssCLOSED;
  end;
  DecReference;
end;

function TWCHTTPStream.RequestReady: Boolean;
begin
  Result := FCurRequest.Complete and
            FHeadersComplete and
            (not FResponseProceed);
end;

end.
