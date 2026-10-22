unit PasWmfToSvg;

// Метафайлы Windows (EMF и WMF) -> SVG на чистом Object Pascal, без GDI и внешних программ: Windows, Linux, macOS,
// Android, iOS (Delphi 10.3 и новее).
//
// Записи метафайла разбираются напрямую и повторяются так, как их рисует GDI: перья (косметические, геометрические,
// штриховые), кисти (сплошные, штриховка, DIB-узор), шрифты, многоугольники, ломаные, отрезки, прямоугольники, эллипсы,
// дуги, кривые Безье, текст (выравнивание, фон, наклон, межсимвольные расстояния), картинки (BITBLT, STRETCHBLT,
// STRETCHDIBITS, SETDIBITSTODEVICE, ALPHABLEND, PATBLT), режимы фона и заливки, начало узора, сохранение DC, режимы
// отображения и мировое преобразование. Остальное (пути, отсечение, растровые операции кроме копирования) пропускается:
// число и типы пропущенных записей - в TMfInfo.
//
// Размер SVG - рамка картинки (EMF: rclFrame в пикселях эталонного устройства; WMF: рамка размещаемого заголовка при
// 96 точках на дюйм), координаты - пиксели этого размера, точка GDI - центр пикселя (сдвиг viewBox на полпикселя),
// масштаб SVG к картинке - ровно 1. Картинки и DIB-узоры встраиваются как PNG (data:).
//
// Метрики шрифтов (базовая линия, ширина текста для фона и выравнивания) - от поставщика IMfFontMetrics: встроенные
// таблицы распространённых шрифтов (измерены в GDI Windows) или, если подключить PasWmfToSvg.Gdi, сама Windows.
//
// Лицензия MIT, https://github.com/Fasday/PasWmfToSvg

interface

uses
  System.SysUtils;

type
  EMetafileToSvg = class(Exception);

  // шрифт метафайла (LOGFONT); высота - в пикселях картинки (<0 - кегль, >0 - высота ячейки)
  TMfFont = record
    Height, Width, Escapement, Orientation, Weight: Integer;
    Italic, Underline, StrikeOut: Boolean;
    CharSet, PitchAndFamily: Byte;
    Face: string;
  end;

  // метрики шрифтов: верх и низ ячейки над и под базовой линией, кегль (всё в пикселях), ширина строки
  IMfFontMetrics = interface
    ['{6E1B7C8A-2F5D-4B8E-9C61-3A7D0F2B4E15}']
    function Metrics(const Font: TMfFont; out Ascent, Descent, Em: Single): Boolean;
    function TextWidth(const Font: TMfFont; const S: string): Single;
  end;

  TMfInfo = record
    // 'EMF' или 'WMF'
    Format: string;
    Records, Skipped: Integer;
    // пропущенные типы записей: «номер×число» через запятую (EMF - EMR_*, WMF - META_* шестнадцатерично)
    SkippedTypes: string;
    // размер картинки, пиксели
    Width, Height: Integer;
  end;

// SVG (текст UTF-16; в файл - UTF-8) по байтам EMF или WMF (с размещаемым заголовком или без); неверные данные -
// EMetafileToSvg. Metrics = nil - MfDefaultFontMetrics.
function MetafileToSvg(const Data: TBytes): string; overload;
function MetafileToSvg(const Data: TBytes; out Info: TMfInfo; const Metrics: IMfFontMetrics = nil): string; overload;
function IsEmf(const Data: TBytes): Boolean;
function IsWmf(const Data: TBytes): Boolean;

// встроенные метрики (таблицы PasWmfToSvg.FontTables.inc; неизвестный шрифт - по семейству)
function BuiltinFontMetrics: IMfFontMetrics;

var
  // поставщик метрик по умолчанию (встроенные таблицы); PasWmfToSvg.Gdi подменяет на GDI Windows
  MfDefaultFontMetrics: IMfFontMetrics;

implementation

uses
  System.Types, System.Math, System.StrUtils, System.ZLib, System.NetEncoding, System.Generics.Collections;

{$I PasWmfToSvg.FontTables.inc}

const
  // режимы отображения, фона, заливки, растровые операции, выравнивание текста, перья, кисти (значения GDI)
  MM_TEXT = 1; MM_LOMETRIC = 2; MM_HIMETRIC = 3; MM_LOENGLISH = 4; MM_HIENGLISH = 5; MM_TWIPS = 6;
  MM_ISOTROPIC = 7; MM_ANISOTROPIC = 8;
  TRANSPARENT_BK = 1; OPAQUE_BK = 2; ALTERNATE_FILL = 1;
  R2_BLACK = 1; R2_NOP = 11; R2_COPYPEN = 13; R2_WHITE = 16;
  TA_UPDATECP = 1; TA_RIGHT = 2; TA_CENTER = 6; TA_BOTTOM = 8; TA_BASELINE = 24;
  PS_SOLID = 0; PS_DASH = 1; PS_DOT = 2; PS_DASHDOT = 3; PS_DASHDOTDOT = 4; PS_NULL = 5; PS_STYLE_MASK = $F;
  PS_ENDCAP_SQUARE = $100; PS_ENDCAP_FLAT = $200; PS_ENDCAP_MASK = $F00;
  PS_JOIN_BEVEL = $1000; PS_JOIN_MITER = $2000; PS_JOIN_MASK = $F000; PS_GEOMETRIC = $10000; PS_TYPE_MASK = $F0000;
  BS_SOLID = 0; BS_NULL = 1; BS_HATCHED = 2;
  AD_COUNTERCLOCKWISE = 1; AD_CLOCKWISE = 2;
  ETO_OPAQUE = 2; ETO_CLIPPED = 4; ETO_GLYPH_INDEX = $10; ETO_PDY = $2000;
  SRCCOPY = $00CC0020; PATCOPY = $00F00021; BLACKNESS = $00000042; WHITENESS = $00FF0062;
  AC_SRC_ALPHA = 1;
  BI_RGB = 0; BI_BITFIELDS = 3;
  MWT_IDENTITY = 1; MWT_LEFTMULTIPLY = 2; MWT_RIGHTMULTIPLY = 3; MWT_SET = 4;
  WHITE_BRUSH = 0; LTGRAY_BRUSH = 1; GRAY_BRUSH = 2; DKGRAY_BRUSH = 3; BLACK_BRUSH = 4; NULL_BRUSH = 5;
  WHITE_PEN = 6; BLACK_PEN = 7; NULL_PEN = 8; OEM_FIXED_FONT = 10; ANSI_FIXED_FONT = 11; ANSI_VAR_FONT = 12;
  SYSTEM_FONT = 13; DEVICE_DEFAULT_FONT = 14; SYSTEM_FIXED_FONT = 16; DEFAULT_GUI_FONT = 17; DC_BRUSH = 18;
  DC_PEN = 19;
  FW_BOLD = 700;

type
  TPt = record
    X, Y: Single;
  end;

  TXf = record
    M11, M12, M21, M22, Dx, Dy: Single;
  end;

  // пиксели картинки: $AARRGGBB сверху вниз
  TPixels = TArray<Cardinal>;

function Pt2(X, Y: Single): TPt;
begin
  Result.X := X;
  Result.Y := Y;
end;

function IdentityXf: TXf;
begin
  Result := Default(TXf);
  Result.M11 := 1;
  Result.M22 := 1;
end;

// A, затем B (точка: p' = p * A * B)
function MulXf(const A, B: TXf): TXf;
begin
  Result.M11 := A.M11 * B.M11 + A.M12 * B.M21;
  Result.M12 := A.M11 * B.M12 + A.M12 * B.M22;
  Result.M21 := A.M21 * B.M11 + A.M22 * B.M21;
  Result.M22 := A.M21 * B.M12 + A.M22 * B.M22;
  Result.Dx := A.Dx * B.M11 + A.Dy * B.M21 + B.Dx;
  Result.Dy := A.Dx * B.M12 + A.Dy * B.M22 + B.Dy;
end;

function Esc(const S: string): string;
var
  B: TStringBuilder;
begin
  B := TStringBuilder.Create(Length(S) + 8);
  try
    for var C in S do
      case C of
        '&': B.Append('&amp;');
        '<': B.Append('&lt;');
        '>': B.Append('&gt;');
        '"': B.Append('&quot;');
        #0..#8, #11, #12, #14..#31: ;
      else
        B.Append(C);
      end;
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

function IsEmf(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 88) and (PCardinal(@Data[0])^ = 1) and (PCardinal(@Data[40])^ = $464D4520);
end;

function IsWmf(const Data: TBytes): Boolean;
var
  P: Integer;
begin
  // размещаемый заголовок (ключ 9AC6CDD7) или сразу заголовок WMF (тип 1/2, размер 9 слов)
  P := 0;
  if (Length(Data) >= 22) and (PCardinal(@Data[0])^ = $9AC6CDD7) then
    P := 22;
  Result := (Length(Data) >= P + 18) and ((PWord(@Data[P])^ = 1) or (PWord(@Data[P])^ = 2)) and
    (PWord(@Data[P + 2])^ = 9);
end;

{ PNG }

// PNG 8 бит RGB или RGBA без фильтров строк (base64); пиксели $AARRGGBB, альфа не умножена
function PngBase64(const Px: TPixels; W, H: Integer; Alpha: Boolean): string;
var
  Raw, Z, Out: TBytes;
  Bpp, At: Integer;

  procedure Chunk(const Kind: string; const Data: TBytes);
  var
    Len, Crc: Cardinal;
    Buf: TBytes;
    Base: Integer;
  begin
    Len := Length(Data);
    SetLength(Buf, 4 + Len);
    for var I := 0 to 3 do
      Buf[I] := Ord(Kind[I + 1]);
    if Len > 0 then
      Move(Data[0], Buf[4], Len);
    Crc := crc32(0, @Buf[0], Length(Buf));
    Base := Length(Out);
    SetLength(Out, Base + 12 + Integer(Len));
    Out[Base] := Len shr 24;
    Out[Base + 1] := (Len shr 16) and $FF;
    Out[Base + 2] := (Len shr 8) and $FF;
    Out[Base + 3] := Len and $FF;
    Move(Buf[0], Out[Base + 4], Length(Buf));
    Out[Base + 8 + Integer(Len)] := Crc shr 24;
    Out[Base + 9 + Integer(Len)] := (Crc shr 16) and $FF;
    Out[Base + 10 + Integer(Len)] := (Crc shr 8) and $FF;
    Out[Base + 11 + Integer(Len)] := Crc and $FF;
  end;

  function BE(V: Cardinal): TBytes;
  begin
    Result := TBytes.Create(V shr 24, (V shr 16) and $FF, (V shr 8) and $FF, V and $FF);
  end;

begin
  Bpp := IfThen(Alpha, 4, 3);
  SetLength(Raw, H * (1 + W * Bpp));
  At := 0;
  for var Y := 0 to H - 1 do
  begin
    Raw[At] := 0;
    Inc(At);
    for var X := 0 to W - 1 do
    begin
      var V := Px[Y * W + X];
      Raw[At] := (V shr 16) and $FF;
      Raw[At + 1] := (V shr 8) and $FF;
      Raw[At + 2] := V and $FF;
      if Alpha then
        Raw[At + 3] := V shr 24;
      Inc(At, Bpp);
    end;
  end;
  ZCompress(Raw, Z, zcMax);
  Out := TBytes.Create($89, $50, $4E, $47, $0D, $0A, $1A, $0A);
  Chunk('IHDR', BE(W) + BE(H) + TBytes.Create(8, IfThen(Alpha, 6, 2), 0, 0, 0));
  Chunk('IDAT', Z);
  Chunk('IEND', nil);
  // base64 одной строкой (без переносов)
  var Enc := TBase64Encoding.Create(0);
  try
    Result := Enc.EncodeBytesToString(Out);
  finally
    Enc.Free;
  end;
end;

{ DIB }

// DIB (BITMAPINFOHEADER или BITMAPCOREHEADER, палитра, маски, биты) -> пиксели сверху вниз; Hdr - начало заголовка,
// Bits - начало битов и BitsLen - их длина (Bits = -1: биты сразу за палитрой, BitsLen - конец данных); Alpha -
// сохранить альфу 32-битной картинки
function DecodeDib(const D: TBytes; Hdr, Bits, BitsLen: Integer; Alpha: Boolean; out W, H: Integer): TPixels;
var
  HdrSize, Bpp, Compr, ClrUsed, Stride, Row, PalEntry, Masks: Integer;
  Pal: TArray<Cardinal>;
  BottomUp: Boolean;
  Rm, Gm, Bm, V: Cardinal;

  function U32(P: Integer): Cardinal;
  begin
    if (P < 0) or (P + 4 > Length(D)) then
      raise EMetafileToSvg.Create('Метафайл: картинка обрезана');
    Move(D[P], Result, 4);
  end;

  function U16(P: Integer): Word;
  begin
    if (P < 0) or (P + 2 > Length(D)) then
      raise EMetafileToSvg.Create('Метафайл: картинка обрезана');
    Move(D[P], Result, 2);
  end;

  function Chan(V, Mask: Cardinal): Cardinal;
  var
    Shift, Count: Integer;
  begin
    if Mask = 0 then
      Exit(0);
    Shift := 0;
    while (Mask shr Shift) and 1 = 0 do
      Inc(Shift);
    Count := 0;
    while (Shift + Count < 32) and ((Mask shr (Shift + Count)) and 1 = 1) do
      Inc(Count);
    Result := (V and Mask) shr Shift;
    if Count < 8 then
      Result := Result * 255 div Cardinal((1 shl Count) - 1)
    else if Count > 8 then
      Result := Result shr (Count - 8);
  end;

begin
  HdrSize := U32(Hdr);
  if HdrSize = 12 then
  begin
    // BITMAPCOREHEADER: 16-битные размеры, палитра RGBTRIPLE
    W := SmallInt(U16(Hdr + 4));
    H := SmallInt(U16(Hdr + 6));
    Bpp := U16(Hdr + 10);
    Compr := BI_RGB;
    ClrUsed := 0;
    PalEntry := 3;
  end
  else
  begin
    W := Integer(U32(Hdr + 4));
    H := Integer(U32(Hdr + 8));
    Bpp := U16(Hdr + 14);
    Compr := U32(Hdr + 16);
    ClrUsed := U32(Hdr + 32);
    PalEntry := 4;
  end;
  BottomUp := H > 0;
  H := Abs(H);
  if (W <= 0) or (H = 0) or (W > 20000) or (H > 20000) or not (Bpp in [1, 4, 8, 16, 24, 32]) or
    not (Compr in [BI_RGB, BI_BITFIELDS]) then
    raise EMetafileToSvg.CreateFmt('Метафайл: картинка %dx%d, %d бит, сжатие %d не поддерживается', [W, H, Bpp, Compr]);
  Masks := Hdr + HdrSize;
  if Bpp <= 8 then
  begin
    if (ClrUsed = 0) or (ClrUsed > 1 shl Bpp) then
      ClrUsed := 1 shl Bpp;
    SetLength(Pal, ClrUsed);
    for var I := 0 to ClrUsed - 1 do
      Pal[I] := (U32(Hdr + HdrSize + I * PalEntry) and $FFFFFF) or $FF000000;
  end;
  if Compr = BI_BITFIELDS then
  begin
    if HdrSize >= 52 then
      Masks := Hdr + 40;
    Rm := U32(Masks);
    Gm := U32(Masks + 4);
    Bm := U32(Masks + 8);
  end
  else if Bpp = 16 then
  begin
    Rm := $7C00;
    Gm := $03E0;
    Bm := $001F;
  end
  else
  begin
    Rm := $FF0000;
    Gm := $FF00;
    Bm := $FF;
  end;
  if Bits < 0 then
  begin
    // упакованная DIB (WMF): биты сразу за палитрой и масками, BitsLen - конец данных картинки
    Bits := Hdr + HdrSize + Length(Pal) * PalEntry;
    if (Compr = BI_BITFIELDS) and (HdrSize < 52) then
      Inc(Bits, 12);
    BitsLen := Min(BitsLen, Length(D)) - Bits;
  end;
  Stride := ((W * Bpp + 31) div 32) * 4;
  SetLength(Result, W * H);
  for var Y := 0 to H - 1 do
  begin
    Row := Bits + IfThen(BottomUp, H - 1 - Y, Y) * Stride;
    // строк меньше, чем в заголовке (по частям, обрезано) - прозрачные
    if (Row < 0) or (Row + Stride > Length(D)) or (Row + Stride > Bits + BitsLen) then
      Continue;
    for var X := 0 to W - 1 do
    begin
      case Bpp of
        1: V := Pal[Min((D[Row + X shr 3] shr (7 - X and 7)) and 1, High(Pal))];
        4: V := Pal[Min((D[Row + X shr 1] shr (4 * (1 - X and 1))) and $F, High(Pal))];
        8: V := Pal[Min(D[Row + X], High(Pal))];
        16:
          begin
            var W16 := Cardinal(D[Row + X * 2]) or (Cardinal(D[Row + X * 2 + 1]) shl 8);
            V := $FF000000 or (Chan(W16, Rm) shl 16) or (Chan(W16, Gm) shl 8) or Chan(W16, Bm);
          end;
        24: V := $FF000000 or Cardinal(D[Row + X * 3]) or (Cardinal(D[Row + X * 3 + 1]) shl 8) or
          (Cardinal(D[Row + X * 3 + 2]) shl 16);
      else
        begin
          Move(D[Row + X * 4], V, 4);
          if Compr = BI_BITFIELDS then
            V := (V and $FF000000) or (Chan(V, Rm) shl 16) or (Chan(V, Gm) shl 8) or Chan(V, Bm);
          if not Alpha then
            V := V or $FF000000;
        end;
      end;
      Result[Y * W + X] := V;
    end;
  end;
end;

{ встроенные метрики шрифтов }

type
  TBuiltinMetrics = class(TInterfacedObject, IMfFontMetrics)
  private
    class function Find(const Font: TMfFont): Integer; static;
  public
    function Metrics(const Font: TMfFont; out Ascent, Descent, Em: Single): Boolean;
    function TextWidth(const Font: TMfFont; const S: string): Single;
  end;

class function TBuiltinMetrics.Find(const Font: TMfFont): Integer;
var
  F: string;
begin
  // по имени; нет - близкий по семейству и шагу (LOGFONT lfPitchAndFamily: FF_ROMAN $10, FF_MODERN $30, FIXED 1)
  for var I := 0 to High(MfFontData) do
    if SameText(MfFontData[I].Face, Font.Face) then
      Exit(I);
  F := LowerCase(Font.Face);
  if F.Contains('courier') or F.Contains('mono') or F.Contains('console') or (Font.PitchAndFamily and 3 = 1) or
    (Font.PitchAndFamily and $F0 = $30) then
    F := 'Courier New'
  else if F.Contains('times') or F.Contains('serif') and not F.Contains('sans') or (Font.PitchAndFamily and $F0 = $10) then
    F := 'Times New Roman'
  else if F.Contains('segoe') then
    F := 'Segoe UI'
  else if F.Contains('verdana') then
    F := 'Verdana'
  else if F.Contains('sans serif') or (F = 'system') or (F = 'ms shell dlg') or (F = 'ms shell dlg 2') then
    F := 'Microsoft Sans Serif'
  else
    F := 'Arial';
  for var I := 0 to High(MfFontData) do
    if SameText(MfFontData[I].Face, F) then
      Exit(I);
  Result := 0;
end;

function TBuiltinMetrics.Metrics(const Font: TMfFont; out Ascent, Descent, Em: Single): Boolean;
var
  I: Integer;
  Cell: Single;
begin
  I := Find(Font);
  Cell := (MfFontData[I].Ascent + MfFontData[I].Descent) / 1000;
  if Font.Height < 0 then
    Em := -Font.Height
  else if Font.Height > 0 then
    Em := Font.Height / Cell
  else
    Em := 12;
  Ascent := Em * MfFontData[I].Ascent / 1000;
  Descent := Em * MfFontData[I].Descent / 1000;
  Result := True;
end;

function TBuiltinMetrics.TextWidth(const Font: TMfFont; const S: string): Single;
var
  I: Integer;
  A, D, Em, Units: Single;
begin
  I := Find(Font);
  Metrics(Font, A, D, Em);
  Units := 0;
  for var C in S do
    if (Ord(C) >= 32) and (Ord(C) <= 126) then
      Units := Units + MfFontData[I].Ascii[Ord(C)]
    else if (Ord(C) >= $410) and (Ord(C) <= $44F) then
      Units := Units + MfFontData[I].Cyr[Ord(C) - $410]
    else if Ord(C) = $401 then
      Units := Units + MfFontData[I].Cyr[64]
    else if Ord(C) = $451 then
      Units := Units + MfFontData[I].Cyr[65]
    else
      Units := Units + MfFontData[I].Avg;
  // полужирный шире обычного; ширина задана - пропорционально
  if Font.Weight >= 600 then
    Units := Units * 1.06;
  Result := Units * Em / 1000;
end;

var
  Builtin: IMfFontMetrics;

function BuiltinFontMetrics: IMfFontMetrics;
begin
  Result := Builtin;
end;

{ преобразователь }

type
  TBrushKind = (bkSolid, bkNull, bkHatch, bkDib);

  TMfPen = record
    Style: Cardinal;
    Width: Single;
    Color: Cardinal;
    Geometric: Boolean;
  end;

  TMfBrush = record
    Kind: TBrushKind;
    Color, Hatch: Cardinal;
    // DIB-узор: PNG (base64) и размер
    Png: string;
    PngW, PngH: Integer;
  end;

  TObjKind = (okNone, okPen, okBrush, okFont, okOther);

  TMfObject = record
    Kind: TObjKind;
    Pen: TMfPen;
    Brush: TMfBrush;
    Font: TMfFont;
  end;

  TDcState = record
    Pen: TMfPen;
    Brush: TMfBrush;
    Font: TMfFont;
    TextColor, BkColor, BkMode, FillMode, TextAlign, Rop2, MapMode, ArcDir: Cardinal;
    BrushOrg, CurPos: TPoint;
    WinOrg, WinExt, VpOrg, VpExt: TPt;
    World: TXf;
  end;

  TFontMetric = record
    Ascent, Descent, Em: Single;
  end;

  TMfConverter = class
  private
    FData: TBytes;
    FSize: Integer;
    FWmf: Boolean;
    FBody, FDefs, FPath: TStringBuilder;
    FPathEnd: string;
    FPathLines: Boolean;
    FPatterns: TDictionary<string, string>;
    FObjects: TArray<TMfObject>;
    FDC: TDcState;
    FStack: TList<TDcState>;
    FDevX, FDevY: Single;
    FFonts: IMfFontMetrics;
    FMetrics: TDictionary<string, TFontMetric>;
    FSkipped: TDictionary<string, Integer>;
    FInfo: TMfInfo;
    FViewX, FViewY: Single;
    FExact: Boolean;
    procedure Need(P, Len: Integer);
    function U32(P: Integer): Cardinal;
    function I32(P: Integer): Integer;
    function U16(P: Integer): Word;
    function I16(P: Integer): SmallInt;
    procedure Skip(const Kind: string);
    function Map(X, Y: Single): TPt;
    function LenScale(Axis: Integer = 0): Single;
    function Rotated: Boolean;
    procedure MapBox(L, T, R, B: Integer; out A, C: TPt);
    function N(V: Single): string;
    function Pt(const P: TPt): string;
    function Col(C: Cardinal): string;
    function PenNull: Boolean;
    function StyledPen: Boolean;
    function PatternId(const B: TMfBrush): string;
    function FillAttr: string;
    function StrokeAttr(const Color: string; Dashed: Boolean): string;
    procedure Shape(const Tag, Geo: string; Filled: Boolean);
    procedure FlushPath;
    procedure DefaultState;
    procedure StockObject(Index: Cardinal);
    procedure SelectObject(Index: Cardinal);
    function AddObject(const Obj: TMfObject): Integer;
    function Metric(const F: TMfFont): TFontMetric;
    function DibBrush(Hdr, Bits, BitsLen: Integer): TMfBrush;
    // рисование в логических координатах (общие для EMF и WMF)
    procedure DoMoveTo(X, Y: Integer);
    procedure DoLineTo(X, Y: Integer);
    procedure DoPoly(const Raw: TArray<TPt>; Closed: Boolean);
    procedure DoPolyPoly(const Counts: TArray<Integer>; const Raw: TArray<TPt>; Closed: Boolean);
    procedure DoBezier(const Raw: TArray<TPt>; FromCur: Boolean);
    procedure DoRect(L, T, R, B: Integer);
    procedure DoEllipse(L, T, R, B: Integer);
    procedure DoRoundRect(L, T, R, B, Cw, Ch: Integer);
    procedure DoArc(Kind: Integer; L, T, R, B, Sx, Sy, Ex, Ey: Integer);
    procedure DoText(X, Y: Integer; const S: string; Opts: Integer; const Rc: TRect; const Dx: TArray<Integer>);
    procedure DoImage(XDest, YDest, CxDest, CyDest: Integer; const Px: TPixels; W, H, XSrc, YSrc, CxSrc,
      CySrc: Integer; Alpha: Boolean; Opacity: Single);
    procedure DoPatBlt(X, Y, Cx, Cy: Integer; Rop: Cardinal);
    procedure ConvertEmf;
    procedure ConvertWmf;
  public
    constructor Create(const Data: TBytes; const Fonts: IMfFontMetrics);
    destructor Destroy; override;
    function Convert: string;
    property Info: TMfInfo read FInfo;
  end;

const
  EMR_HEADER = 1; EMR_POLYBEZIER = 2; EMR_POLYGON = 3; EMR_POLYLINE = 4; EMR_POLYBEZIERTO = 5; EMR_POLYLINETO = 6;
  EMR_POLYPOLYLINE = 7; EMR_POLYPOLYGON = 8; EMR_SETWINDOWEXTEX = 9; EMR_SETWINDOWORGEX = 10;
  EMR_SETVIEWPORTEXTEX = 11; EMR_SETVIEWPORTORGEX = 12; EMR_SETBRUSHORGEX = 13; EMR_EOF = 14; EMR_SETMAPMODE = 17;
  EMR_SETBKMODE = 18; EMR_SETPOLYFILLMODE = 19; EMR_SETROP2 = 20; EMR_SETTEXTALIGN = 22; EMR_SETTEXTCOLOR = 24;
  EMR_SETBKCOLOR = 25; EMR_MOVETOEX = 27; EMR_SAVEDC = 33; EMR_RESTOREDC = 34; EMR_SETWORLDTRANSFORM = 35;
  EMR_MODIFYWORLDTRANSFORM = 36; EMR_SELECTOBJECT = 37; EMR_CREATEPEN = 38; EMR_CREATEBRUSHINDIRECT = 39;
  EMR_DELETEOBJECT = 40; EMR_ELLIPSE = 42; EMR_RECTANGLE = 43; EMR_ROUNDRECT = 44; EMR_ARC = 45; EMR_CHORD = 46;
  EMR_PIE = 47; EMR_LINETO = 54; EMR_ARCTO = 55; EMR_SETARCDIRECTION = 57; EMR_BITBLT = 76; EMR_STRETCHBLT = 77;
  EMR_SETDIBITSTODEVICE = 80; EMR_STRETCHDIBITS = 81; EMR_EXTCREATEFONTINDIRECTW = 82; EMR_EXTTEXTOUTW = 84;
  EMR_POLYBEZIER16 = 85; EMR_POLYGON16 = 86; EMR_POLYLINE16 = 87; EMR_POLYBEZIERTO16 = 88; EMR_POLYLINETO16 = 89;
  EMR_POLYPOLYLINE16 = 90; EMR_POLYPOLYGON16 = 91; EMR_CREATEDIBPATTERNBRUSHPT = 94; EMR_EXTCREATEPEN = 95;
  EMR_ALPHABLEND = 114;
  // записи EMF без видимого результата (палитры, ICM, комментарии, режимы растяжения и т. п.)
  EmfQuiet: array[0..13] of Integer = (16, 21, 23, 28, 48, 49, 50, 51, 52, 58, 70, 98, 115, 120);

constructor TMfConverter.Create(const Data: TBytes; const Fonts: IMfFontMetrics);
begin
  inherited Create;
  FData := Data;
  FSize := Length(Data);
  FFonts := Fonts;
  if FFonts = nil then
    FFonts := MfDefaultFontMetrics;
  if FFonts = nil then
    FFonts := Builtin;
  FBody := TStringBuilder.Create;
  FDefs := TStringBuilder.Create;
  FPath := TStringBuilder.Create;
  FPatterns := TDictionary<string, string>.Create;
  FStack := TList<TDcState>.Create;
  FMetrics := TDictionary<string, TFontMetric>.Create;
  FSkipped := TDictionary<string, Integer>.Create;
end;

destructor TMfConverter.Destroy;
begin
  FSkipped.Free;
  FMetrics.Free;
  FStack.Free;
  FPatterns.Free;
  FPath.Free;
  FDefs.Free;
  FBody.Free;
  inherited;
end;

procedure TMfConverter.Need(P, Len: Integer);
begin
  if (P < 0) or (Len < 0) or (P + Len > FSize) then
    raise EMetafileToSvg.Create('Метафайл обрезан или повреждён');
end;

function TMfConverter.U32(P: Integer): Cardinal;
begin
  Need(P, 4);
  Move(FData[P], Result, 4);
end;

function TMfConverter.I32(P: Integer): Integer;
begin
  Need(P, 4);
  Move(FData[P], Result, 4);
end;

function TMfConverter.U16(P: Integer): Word;
begin
  Need(P, 2);
  Move(FData[P], Result, 2);
end;

function TMfConverter.I16(P: Integer): SmallInt;
begin
  Need(P, 2);
  Move(FData[P], Result, 2);
end;

procedure TMfConverter.Skip(const Kind: string);
var
  C: Integer;
begin
  Inc(FInfo.Skipped);
  if not FSkipped.TryGetValue(Kind, C) then
    C := 0;
  FSkipped.AddOrSetValue(Kind, C + 1);
end;

function TMfConverter.Map(X, Y: Single): TPt;
var
  W: TXf;
  Sx, Sy, Px, Py: Single;
begin
  // мировое преобразование, затем страница (режим отображения) -> пиксели картинки
  W := FDC.World;
  Px := X * W.M11 + Y * W.M21 + W.Dx;
  Py := X * W.M12 + Y * W.M22 + W.Dy;
  case FDC.MapMode of
    MM_ANISOTROPIC, MM_ISOTROPIC:
      begin
        Sx := IfThen(FDC.WinExt.X <> 0, FDC.VpExt.X / FDC.WinExt.X, 1);
        Sy := IfThen(FDC.WinExt.Y <> 0, FDC.VpExt.Y / FDC.WinExt.Y, 1);
        if FDC.MapMode = MM_ISOTROPIC then
        begin
          var M := Min(Abs(Sx), Abs(Sy));
          Sx := Sign(Sx) * M;
          Sy := Sign(Sy) * M;
        end;
      end;
    MM_LOMETRIC: begin Sx := FDevX / 10; Sy := -FDevY / 10; end;
    MM_HIMETRIC: begin Sx := FDevX / 100; Sy := -FDevY / 100; end;
    MM_LOENGLISH: begin Sx := FDevX * 0.254; Sy := -FDevY * 0.254; end;
    MM_HIENGLISH: begin Sx := FDevX * 0.0254; Sy := -FDevY * 0.0254; end;
    MM_TWIPS: begin Sx := FDevX * 25.4 / 1440; Sy := -FDevY * 25.4 / 1440; end;
  else
    begin
      Sx := 1;
      Sy := 1;
    end;
  end;
  if FDC.MapMode = MM_TEXT then
  begin
    Result.X := Px + FDC.VpOrg.X - FDC.WinOrg.X;
    Result.Y := Py + FDC.VpOrg.Y - FDC.WinOrg.Y;
  end
  else
  begin
    Result.X := (Px - FDC.WinOrg.X) * Sx + FDC.VpOrg.X;
    Result.Y := (Py - FDC.WinOrg.Y) * Sy + FDC.VpOrg.Y;
  end;
  // GDI рисует в целых пикселях устройства: точка - к ближайшему
  if not FExact then
  begin
    Result.X := Floor(Result.X + 0.5);
    Result.Y := Floor(Result.Y + 0.5);
  end;
end;

function TMfConverter.LenScale(Axis: Integer): Single;
var
  A, B, C: TPt;
begin
  // масштаб длин без округления: 0 - корень из площади образа квадрата 1000 x 1000, 1 - по оси X (толщина пера,
  // как у GDI), 2 - по оси Y (высота шрифта)
  FExact := True;
  try
    A := Map(0, 0);
    B := Map(1000, 0);
    C := Map(0, 1000);
  finally
    FExact := False;
  end;
  case Axis of
    1: Result := Sqrt(Sqr(B.X - A.X) + Sqr(B.Y - A.Y)) / 1000;
    2: Result := Sqrt(Sqr(C.X - A.X) + Sqr(C.Y - A.Y)) / 1000;
  else
    Result := Sqrt(Abs((B.X - A.X) * (C.Y - A.Y) - (B.Y - A.Y) * (C.X - A.X))) / 1000;
  end;
  if Result = 0 then
    Result := 1;
end;

procedure TMfConverter.MapBox(L, T, R, B: Integer; out A, C: TPt);
begin
  // прямоугольник фигуры: в WMF - как аргументы вызова GDI (правый нижний угол не входит), в EMF - включительно
  // (GDI записывает угол на пиксель устройства меньше и при рисовании возвращает этот пиксель)
  A := Map(L, T);
  C := Map(R, B);
  if not FWmf then
  begin
    if C.X >= A.X then C.X := C.X + 1 else A.X := A.X + 1;
    if C.Y >= A.Y then C.Y := C.Y + 1 else A.Y := A.Y + 1;
  end;
end;

function TMfConverter.Rotated: Boolean;
begin
  Result := (Abs(FDC.World.M12) > 1E-6) or (Abs(FDC.World.M21) > 1E-6);
end;

function TMfConverter.N(V: Single): string;
var
  R: Double;
begin
  R := RoundTo(V, -2);
  if R = 0 then
    Exit('0');
  Result := FloatToStrF(R, ffFixed, 15, 2, TFormatSettings.Invariant);
  if Result.Contains('.') then
    Result := Result.TrimRight(['0']).TrimRight(['.']);
end;

function TMfConverter.Pt(const P: TPt): string;
begin
  Result := N(P.X) + ',' + N(P.Y);
end;

function TMfConverter.Col(C: Cardinal): string;
begin
  if FDC.Rop2 = R2_BLACK then
    C := 0
  else if FDC.Rop2 = R2_WHITE then
    C := $FFFFFF;
  Result := Format('#%.2x%.2x%.2x', [C and $FF, (C shr 8) and $FF, (C shr 16) and $FF]).ToLower;
end;

function TMfConverter.PenNull: Boolean;
begin
  Result := (FDC.Pen.Style and PS_STYLE_MASK) = PS_NULL;
end;

function TMfConverter.StyledPen: Boolean;
begin
  Result := (FDC.Pen.Style and PS_STYLE_MASK) in [PS_DASH, PS_DOT, PS_DASHDOT, PS_DASHDOTDOT];
end;

function TMfConverter.PatternId(const B: TMfBrush): string;
var
  Key: string;
  Org: TPt;
begin
  // узор от начала узора кисти (в пикселях картинки); штриховка - фон цветом фона при OPAQUE
  Org := Pt2(FDC.BrushOrg.X, FDC.BrushOrg.Y);
  if B.Kind = bkHatch then
    Key := Format('h%d_%x_%d_%x_%s', [B.Hatch, B.Color, FDC.BkMode, FDC.BkColor, Pt(Org)])
  else
    Key := Format('d%d_%d_%s', [B.Png.GetHashCode, B.Png.Length, Pt(Org)]);
  if FPatterns.TryGetValue(Key, Result) then
    Exit;
  Result := 'p' + IntToStr(FPatterns.Count);
  FPatterns.Add(Key, Result);
  if B.Kind = bkHatch then
  begin
    FDefs.Append(Format('<pattern id="%s" patternUnits="userSpaceOnUse" x="%s" y="%s" width="8" height="8">',
      [Result, N(Org.X - 0.5), N(Org.Y - 0.5)]));
    if FDC.BkMode <> TRANSPARENT_BK then
      FDefs.Append(Format('<rect width="8" height="8" fill="%s"/>', [Col(FDC.BkColor)]));
    for var Y := 0 to 7 do
    begin
      var Bits := MfHatchBits[Min(B.Hatch, 5), Y];
      var X := 0;
      while X < 8 do
        if Bits and (1 shl (7 - X)) <> 0 then
        begin
          var X0 := X;
          while (X < 8) and (Bits and (1 shl (7 - X)) <> 0) do
            Inc(X);
          FDefs.Append(Format('<rect x="%d" y="%d" width="%d" height="1" fill="%s"/>', [X0, Y, X - X0, Col(B.Color)]));
        end
        else
          Inc(X);
    end;
  end
  else
    FDefs.Append(Format('<pattern id="%s" patternUnits="userSpaceOnUse" x="%s" y="%s" width="%d" height="%d">' +
      '<image width="%d" height="%d" xlink:href="data:image/png;base64,%s"/>', [Result, N(Org.X - 0.5),
      N(Org.Y - 0.5), B.PngW, B.PngH, B.PngW, B.PngH, B.Png]));
  FDefs.Append('</pattern>');
end;

function TMfConverter.FillAttr: string;
begin
  if FDC.Rop2 = R2_NOP then
    Exit('fill="none"');
  case FDC.Brush.Kind of
    bkSolid: Result := 'fill="' + Col(FDC.Brush.Color) + '"';
    bkHatch, bkDib: Result := 'fill="url(#' + PatternId(FDC.Brush) + ')"';
  else
    Result := 'fill="none"';
  end;
  if (Result <> 'fill="none"') and (FDC.FillMode = ALTERNATE_FILL) then
    Result := Result + ' fill-rule="evenodd"';
end;

function TMfConverter.StrokeAttr(const Color: string; Dashed: Boolean): string;
var
  W: Single;
  Dash: string;
begin
  if PenNull or (FDC.Rop2 = R2_NOP) then
    Exit('stroke="none"');
  // толщина в целых пикселях устройства, не меньше 1 (как GDI)
  W := FDC.Pen.Width;
  if FDC.Pen.Geometric then
    W := Floor(W * LenScale(1) + 0.5);
  if W < 1 then
    W := 1;
  Result := Format('stroke="%s" stroke-width="%s"', [Color, N(W)]);
  if FDC.Pen.Geometric and (W > 1) then
  begin
    // концы и стыки - по стилю пера (по умолчанию GDI - круглые)
    case FDC.Pen.Style and PS_ENDCAP_MASK of
      PS_ENDCAP_SQUARE: Result := Result + ' stroke-linecap="square"';
      PS_ENDCAP_FLAT: ;
    else
      Result := Result + ' stroke-linecap="round"';
    end;
    case FDC.Pen.Style and PS_JOIN_MASK of
      PS_JOIN_BEVEL: Result := Result + ' stroke-linejoin="bevel"';
      PS_JOIN_MITER: ;
    else
      Result := Result + ' stroke-linejoin="round"';
    end;
  end;
  if Dashed then
  begin
    // штрихи косметического пера GDI (пиксели), толстого - кратно толщине
    case FDC.Pen.Style and PS_STYLE_MASK of
      PS_DASH: Dash := '18,6';
      PS_DOT: Dash := '3,3';
      PS_DASHDOT: Dash := '9,6,3,6';
    else
      Dash := '9,3,3,3,3,3';
    end;
    if W > 1 then
    begin
      var Parts := Dash.Split([',']);
      Dash := '';
      for var S in Parts do
        Dash := Dash + IfThen(Dash <> '', ',', '') + N(StrToInt(S) * W);
    end;
    Result := Result + ' stroke-dasharray="' + Dash + '"';
  end;
end;

procedure TMfConverter.Shape(const Tag, Geo: string; Filled: Boolean);
var
  Fill, Stroke: string;
begin
  if Filled then
    Fill := FillAttr
  else
    Fill := 'fill="none"';
  Stroke := StrokeAttr(Col(FDC.Pen.Color), StyledPen);
  if (Fill = 'fill="none"') and (Stroke = 'stroke="none"') then
    Exit;
  // штриховое перо при непрозрачном фоне: промежутки - цветом фона
  if StyledPen and (FDC.BkMode <> TRANSPARENT_BK) and (Stroke <> 'stroke="none"') then
  begin
    FBody.Append(Format('<%s %s %s %s/>', [Tag, Geo, Fill, StrokeAttr(Col(FDC.BkColor), False)]));
    Fill := 'fill="none"';
  end;
  FBody.Append(Format('<%s %s %s %s/>', [Tag, Geo, Fill, Stroke]));
end;

procedure TMfConverter.FlushPath;
begin
  if FPathLines then
    Shape('path', 'd="' + FPath.ToString + '"', False);
  FPath.Clear;
  FPathEnd := '';
  FPathLines := False;
end;

procedure TMfConverter.DefaultState;
begin
  FDC := Default(TDcState);
  FDC.Pen.Width := 1;
  FDC.Brush.Kind := bkSolid;
  FDC.Brush.Color := $FFFFFF;
  FDC.BkColor := $FFFFFF;
  FDC.BkMode := OPAQUE_BK;
  FDC.FillMode := ALTERNATE_FILL;
  FDC.Rop2 := R2_COPYPEN;
  FDC.MapMode := MM_TEXT;
  FDC.ArcDir := AD_COUNTERCLOCKWISE;
  FDC.WinExt := Pt2(1, 1);
  FDC.VpExt := Pt2(1, 1);
  FDC.World := IdentityXf;
  StockObject(SYSTEM_FONT);
end;

procedure TMfConverter.StockObject(Index: Cardinal);

  procedure StockFont(const Face: string; Height, Weight: Integer; Pitch: Byte);
  begin
    FDC.Font := Default(TMfFont);
    FDC.Font.Face := Face;
    FDC.Font.Height := Height;
    FDC.Font.Weight := Weight;
    FDC.Font.PitchAndFamily := Pitch;
  end;

begin
  case Index of
    WHITE_BRUSH, LTGRAY_BRUSH, GRAY_BRUSH, DKGRAY_BRUSH, BLACK_BRUSH, DC_BRUSH:
      begin
        FDC.Brush := Default(TMfBrush);
        FDC.Brush.Kind := bkSolid;
        case Index of
          WHITE_BRUSH, DC_BRUSH: FDC.Brush.Color := $FFFFFF;
          LTGRAY_BRUSH: FDC.Brush.Color := $C0C0C0;
          GRAY_BRUSH: FDC.Brush.Color := $808080;
          DKGRAY_BRUSH: FDC.Brush.Color := $404040;
        else
          FDC.Brush.Color := 0;
        end;
      end;
    NULL_BRUSH:
      begin
        FDC.Brush := Default(TMfBrush);
        FDC.Brush.Kind := bkNull;
      end;
    WHITE_PEN, BLACK_PEN, NULL_PEN, DC_PEN:
      begin
        FDC.Pen := Default(TMfPen);
        FDC.Pen.Width := 1;
        if Index = NULL_PEN then
          FDC.Pen.Style := PS_NULL
        else if Index = WHITE_PEN then
          FDC.Pen.Color := $FFFFFF;
      end;
    // стандартные шрифты Windows (96 точек на дюйм)
    SYSTEM_FONT: StockFont('System', 16, FW_BOLD, $22);
    DEFAULT_GUI_FONT: StockFont('MS Shell Dlg', -11, 400, $22);
    ANSI_VAR_FONT: StockFont('MS Sans Serif', 13, 400, $22);
    OEM_FIXED_FONT, ANSI_FIXED_FONT, SYSTEM_FIXED_FONT: StockFont('Courier New', 13, 400, $31);
    DEVICE_DEFAULT_FONT: StockFont('System', 16, FW_BOLD, $22);
  end;
end;

procedure TMfConverter.SelectObject(Index: Cardinal);
begin
  if Index and $80000000 <> 0 then
    StockObject(Index and $7FFFFFFF)
  else if Index < Cardinal(Length(FObjects)) then
    case FObjects[Index].Kind of
      okPen: FDC.Pen := FObjects[Index].Pen;
      okBrush: FDC.Brush := FObjects[Index].Brush;
      okFont: FDC.Font := FObjects[Index].Font;
    end;
end;

function TMfConverter.AddObject(const Obj: TMfObject): Integer;
begin
  // WMF: объект занимает первое свободное место таблицы
  for var I := 0 to High(FObjects) do
    if FObjects[I].Kind = okNone then
    begin
      FObjects[I] := Obj;
      Exit(I);
    end;
  Result := Length(FObjects);
  FObjects := FObjects + [Obj];
end;

function TMfConverter.Metric(const F: TMfFont): TFontMetric;
var
  Key: string;
begin
  Key := Format('%d|%d|%d|%d|%s', [F.Height, F.Weight, Ord(F.Italic), F.CharSet, F.Face]);
  if FMetrics.TryGetValue(Key, Result) then
    Exit;
  if not FFonts.Metrics(F, Result.Ascent, Result.Descent, Result.Em) then
    Builtin.Metrics(F, Result.Ascent, Result.Descent, Result.Em);
  FMetrics.Add(Key, Result);
end;

function TMfConverter.DibBrush(Hdr, Bits, BitsLen: Integer): TMfBrush;
var
  W, H: Integer;
  Px: TPixels;
begin
  Px := DecodeDib(FData, Hdr, Bits, BitsLen, False, W, H);
  Result := Default(TMfBrush);
  Result.Kind := bkDib;
  Result.Png := PngBase64(Px, W, H, False);
  Result.PngW := W;
  Result.PngH := H;
end;

procedure TMfConverter.DoMoveTo(X, Y: Integer);
begin
  FDC.CurPos := Point(X, Y);
end;

procedure TMfConverter.DoLineTo(X, Y: Integer);
var
  From, Dest: string;
begin
  // отрезки подряд (MOVETO/LINETO одним пером) - одним путём; GDI не рисует последний пиксель - здесь он
  // наполовину под сглаживанием
  From := Pt(Map(FDC.CurPos.X, FDC.CurPos.Y));
  Dest := Pt(Map(X, Y));
  if FPath.Length = 0 then
    FPath.Append('M' + From)
  else if From <> FPathEnd then
    FPath.Append(' M' + From);
  FPath.Append(' L' + Dest);
  FPathEnd := Dest;
  FPathLines := True;
  FDC.CurPos := Point(X, Y);
end;

procedure TMfConverter.DoPoly(const Raw: TArray<TPt>; Closed: Boolean);
var
  B: TStringBuilder;
begin
  if Length(Raw) < 2 then
    Exit;
  B := TStringBuilder.Create;
  try
    for var I := 0 to High(Raw) do
    begin
      if I > 0 then
        B.Append(' ');
      B.Append(Pt(Map(Raw[I].X, Raw[I].Y)));
    end;
    if Closed then
      Shape('polygon', 'points="' + B.ToString + '"', True)
    else
      Shape('polyline', 'points="' + B.ToString + '"', False);
  finally
    B.Free;
  end;
end;

procedure TMfConverter.DoPolyPoly(const Counts: TArray<Integer>; const Raw: TArray<TPt>; Closed: Boolean);
var
  D: TStringBuilder;
  At: Integer;
begin
  D := TStringBuilder.Create;
  try
    At := 0;
    for var C in Counts do
    begin
      for var I := 0 to C - 1 do
        if At + I < Length(Raw) then
          D.Append(IfThen(I = 0, IfThen(D.Length > 0, ' M', 'M'), ' L') + Pt(Map(Raw[At + I].X, Raw[At + I].Y)));
      if Closed and (C > 0) then
        D.Append(' Z');
      Inc(At, C);
    end;
    if D.Length > 0 then
      Shape('path', 'd="' + D.ToString + '"', Closed);
  finally
    D.Free;
  end;
end;

procedure TMfConverter.DoBezier(const Raw: TArray<TPt>; FromCur: Boolean);
var
  I: Integer;
  D: string;
begin
  // первая точка и тройки (POLYBEZIER) или тройки от текущей точки (POLYBEZIERTO)
  if FromCur then
  begin
    D := 'M' + Pt(Map(FDC.CurPos.X, FDC.CurPos.Y));
    I := 0;
  end
  else
  begin
    if Length(Raw) = 0 then
      Exit;
    D := 'M' + Pt(Map(Raw[0].X, Raw[0].Y));
    I := 1;
  end;
  while I + 2 < Length(Raw) do
  begin
    D := D + ' C' + Pt(Map(Raw[I].X, Raw[I].Y)) + ' ' + Pt(Map(Raw[I + 1].X, Raw[I + 1].Y)) + ' ' +
      Pt(Map(Raw[I + 2].X, Raw[I + 2].Y));
    Inc(I, 3);
  end;
  if FromCur and (Length(Raw) > 0) then
    FDC.CurPos := Point(Round(Raw[High(Raw)].X), Round(Raw[High(Raw)].Y));
  Shape('path', 'd="' + D + '"', False);
end;

procedure TMfConverter.DoRect(L, T, R, B: Integer);
var
  A, C: TPt;
  X, Y, W, H: Single;
begin
  // без правого и нижнего края; без пера - заливка на пиксель меньше (по краям пикселей); с поворотом мирового
  // преобразования - четырёхугольник
  if Rotated then
  begin
    if FWmf then
    begin
      Dec(R);
      Dec(B);
    end;
    DoPoly([Pt2(L, T), Pt2(R, T), Pt2(R, B), Pt2(L, B)], True);
    Exit;
  end;
  MapBox(L, T, R, B, A, C);
  X := Min(A.X, C.X);
  Y := Min(A.Y, C.Y);
  W := Abs(C.X - A.X) - 1;
  H := Abs(C.Y - A.Y) - 1;
  if (W <= 0) or (H <= 0) then
    Exit;
  if PenNull then
  begin
    X := X - 0.5;
    Y := Y - 0.5;
  end;
  Shape('rect', Format('x="%s" y="%s" width="%s" height="%s"', [N(X), N(Y), N(W), N(H)]), True);
end;

procedure TMfConverter.DoEllipse(L, T, R, B: Integer);
var
  A, C: TPt;
begin
  MapBox(L, T, R, B, A, C);
  Shape('ellipse', Format('cx="%s" cy="%s" rx="%s" ry="%s"', [N((A.X + C.X - 1) / 2), N((A.Y + C.Y - 1) / 2),
    N((Abs(C.X - A.X) - 1) / 2), N((Abs(C.Y - A.Y) - 1) / 2)]), True);
end;

procedure TMfConverter.DoRoundRect(L, T, R, B, Cw, Ch: Integer);
var
  A, C: TPt;
  S: Single;
begin
  MapBox(L, T, R, B, A, C);
  S := LenScale;
  Shape('rect', Format('x="%s" y="%s" width="%s" height="%s" rx="%s" ry="%s"', [N(Min(A.X, C.X)), N(Min(A.Y, C.Y)),
    N(Abs(C.X - A.X) - 1), N(Abs(C.Y - A.Y) - 1), N(Cw * S / 2), N(Ch * S / 2)]), True);
end;

procedure TMfConverter.DoArc(Kind: Integer; L, T, R, B, Sx, Sy, Ex, Ey: Integer);
var
  A, C, S, E, M, P1, P2: TPt;
  Rx, Ry, A1, A2, Delta: Single;
  Large, Sweep: Integer;
  D: string;
begin
  // лучи из центра к начальной и конечной точкам; направление - против часовой (как на экране) или SETARCDIRECTION
  MapBox(L, T, R, B, A, C);
  S := Map(Sx, Sy);
  E := Map(Ex, Ey);
  M.X := (A.X + C.X - 1) / 2;
  M.Y := (A.Y + C.Y - 1) / 2;
  Rx := (Abs(C.X - A.X) - 1) / 2;
  Ry := (Abs(C.Y - A.Y) - 1) / 2;
  if (Rx <= 0) or (Ry <= 0) then
    Exit;
  A1 := ArcTan2(-(S.Y - M.Y) / Ry, (S.X - M.X) / Rx);
  A2 := ArcTan2(-(E.Y - M.Y) / Ry, (E.X - M.X) / Rx);
  P1 := Pt2(M.X + Rx * Cos(A1), M.Y - Ry * Sin(A1));
  P2 := Pt2(M.X + Rx * Cos(A2), M.Y - Ry * Sin(A2));
  if FDC.ArcDir = AD_CLOCKWISE then
  begin
    Delta := A1 - A2;
    Sweep := 1;
  end
  else
  begin
    Delta := A2 - A1;
    Sweep := 0;
  end;
  while Delta <= 0 do
    Delta := Delta + 2 * Pi;
  Large := Ord(Delta > Pi);
  if SameValue(Delta, 2 * Pi, 1E-4) then
    D := Format('M%s A%s,%s 0 0,%d %s A%s,%s 0 0,%d %s', [Pt(P1), N(Rx), N(Ry), Sweep,
      Pt(Pt2(2 * M.X - P1.X, 2 * M.Y - P1.Y)), N(Rx), N(Ry), Sweep, Pt(P1)])
  else
    D := Format('M%s A%s,%s 0 %d,%d %s', [Pt(P1), N(Rx), N(Ry), Large, Sweep, Pt(P2)]);
  case Kind of
    EMR_CHORD: Shape('path', 'd="' + D + ' Z"', True);
    EMR_PIE: Shape('path', 'd="M' + Pt(M) + ' L' + D.Substring(1) + ' Z"', True);
    EMR_ARCTO:
      begin
        Shape('path', 'd="M' + Pt(Map(FDC.CurPos.X, FDC.CurPos.Y)) + ' L' + D.Substring(1) + '"', False);
        FDC.CurPos := Point(Ex, Ey);
      end;
  else
    Shape('path', 'd="' + D + '"', False);
  end;
end;

procedure TMfConverter.DoText(X, Y: Integer; const S: string; Opts: Integer; const Rc: TRect;
  const Dx: TArray<Integer>);
var
  Ref, Org, A, B: TPt;
  Xs, Attr, Family, Generic: string;
  Adv: TArray<Single>;
  Total, X0, Base, Angle, Scale: Single;
  F: TMfFont;
  M: TFontMetric;
begin
  // выравнивание - SETTEXTALIGN; фон при OPAQUE - ячейка текста цветом фона; ETO_OPAQUE - прямоугольник фона
  if (Opts and ETO_OPAQUE <> 0) and (Rc.Right > Rc.Left) and (Rc.Bottom > Rc.Top) then
  begin
    A := Map(Rc.Left, Rc.Top);
    B := Map(Rc.Right, Rc.Bottom);
    FBody.Append(Format('<rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>', [N(Min(A.X, B.X) - 0.5),
      N(Min(A.Y, B.Y) - 0.5), N(Abs(B.X - A.X)), N(Abs(B.Y - A.Y)), Col(FDC.BkColor)]));
  end;
  if S = '' then
    Exit;
  Scale := LenScale(2);
  F := FDC.Font;
  F.Height := Round(F.Height * Scale);
  F.Width := Round(F.Width * Scale);
  M := Metric(F);
  Total := 0;
  if Length(Dx) >= Length(S) then
  begin
    SetLength(Adv, Length(S));
    for var I := 0 to High(Adv) do
    begin
      Adv[I] := Dx[I] * Scale;
      Total := Total + Adv[I];
    end;
  end
  else
    Total := FFonts.TextWidth(F, S);
  if FDC.TextAlign and TA_UPDATECP <> 0 then
    Ref := Map(FDC.CurPos.X, FDC.CurPos.Y)
  else
    Ref := Map(X, Y);
  case FDC.TextAlign and TA_CENTER of
    TA_RIGHT: X0 := -Total;
    TA_CENTER: X0 := -Total / 2;
  else
    X0 := 0;
  end;
  case FDC.TextAlign and TA_BASELINE of
    TA_BASELINE: Base := 0;
    TA_BOTTOM: Base := -M.Descent;
  else
    Base := M.Ascent;
  end;
  if FDC.TextAlign and TA_UPDATECP <> 0 then
    FDC.CurPos := Point(FDC.CurPos.X + Round(IfThen(FDC.TextAlign and TA_CENTER = TA_RIGHT, -Total, Total) / Scale),
      FDC.CurPos.Y);
  // точка привязки - угол ячейки (край пикселя): сдвиг на полпикселя; наклон - lfEscapement (десятые градуса)
  Org := Pt2(Ref.X - 0.5, Ref.Y - 0.5);
  Angle := FDC.Font.Escapement / 10;
  if Rotated then
    Angle := Angle - RadToDeg(ArcTan2(FDC.World.M12, FDC.World.M11));
  if Angle <> 0 then
    FBody.Append(Format('<g transform="rotate(%s %s %s)">', [N(-Angle), N(Org.X), N(Org.Y)]));
  if FDC.BkMode <> TRANSPARENT_BK then
    FBody.Append(Format('<rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>', [N(Org.X + X0),
      N(Org.Y + Base - M.Ascent), N(Total), N(M.Ascent + M.Descent), Col(FDC.BkColor)]));
  if Length(Adv) > 1 then
  begin
    var Px := Org.X + X0;
    for var I := 0 to High(Adv) do
    begin
      Xs := Xs + IfThen(I > 0, ' ', '') + N(Px);
      Px := Px + Adv[I];
    end;
  end
  else
    Xs := N(Org.X + X0);
  Family := FDC.Font.Face.Trim;
  if Family = '' then
    Family := 'Arial';
  if (FDC.Font.PitchAndFamily and 3 = 1) or (FDC.Font.PitchAndFamily and $F0 = $30) then
    Generic := 'monospace'
  else if FDC.Font.PitchAndFamily and $F0 = $10 then
    Generic := 'serif'
  else
    Generic := 'sans-serif';
  if Family.Contains(' ') then
    Family := '''' + Family + '''';
  Attr := Format('font-family="%s, %s" font-size="%s"', [Esc(Family), Generic, N(M.Em)]);
  if FDC.Font.Weight >= 600 then
    Attr := Attr + ' font-weight="bold"'
  else if (FDC.Font.Weight > 0) and (FDC.Font.Weight <> 400) then
    Attr := Attr + ' font-weight="' + IntToStr(FDC.Font.Weight) + '"';
  if FDC.Font.Italic then
    Attr := Attr + ' font-style="italic"';
  if FDC.Font.Underline or FDC.Font.StrikeOut then
    Attr := Attr + ' text-decoration="' + Trim(IfThen(FDC.Font.Underline, 'underline ', '') +
      IfThen(FDC.Font.StrikeOut, 'line-through', '')) + '"';
  FBody.Append(Format('<text x="%s" y="%s" %s fill="%s" xml:space="preserve">%s</text>', [Xs, N(Org.Y + Base), Attr,
    Col(FDC.TextColor), Esc(S)]));
  if Angle <> 0 then
    FBody.Append('</g>');
end;

procedure TMfConverter.DoImage(XDest, YDest, CxDest, CyDest: Integer; const Px: TPixels; W, H, XSrc, YSrc, CxSrc,
  CySrc: Integer; Alpha: Boolean; Opacity: Single);
var
  A, B: TPt;
  Crop: TPixels;
begin
  // прямоугольник источника картинки -> прямоугольник назначения (пиксель картинки покрывает пиксели назначения);
  // альфа ALPHABLEND умножена на цвет - для PNG вернуть цвет
  if (CxSrc <= 0) or (CySrc <= 0) then
    Exit;
  A := Map(XDest, YDest);
  B := Map(XDest + CxDest, YDest + CyDest);
  SetLength(Crop, CxSrc * CySrc);
  for var Y := 0 to CySrc - 1 do
    for var X := 0 to CxSrc - 1 do
    begin
      var Sx := XSrc + X;
      var Sy := YSrc + Y;
      var V: Cardinal := 0;
      if (Sx >= 0) and (Sx < W) and (Sy >= 0) and (Sy < H) then
        V := Px[Sy * W + Sx];
      if Alpha then
      begin
        var Al := V shr 24;
        if Al = 0 then
          V := 0
        else if Al < 255 then
          V := (Al shl 24) or (Min(255, ((V shr 16) and $FF) * 255 div Al) shl 16) or
            (Min(255, ((V shr 8) and $FF) * 255 div Al) shl 8) or Min(255, (V and $FF) * 255 div Al);
      end;
      Crop[Y * CxSrc + X] := V;
    end;
  // отражение (отрицательная ширина или высота назначения)
  var Tf := '';
  if (B.X < A.X) or (B.Y < A.Y) then
    Tf := Format(' transform="translate(%s %s) scale(%d %d)"', [N(IfThen(B.X < A.X, A.X + B.X - 1, 0)),
      N(IfThen(B.Y < A.Y, A.Y + B.Y - 1, 0)), IfThen(B.X < A.X, -1, 1), IfThen(B.Y < A.Y, -1, 1)]);
  FBody.Append(Format('<image x="%s" y="%s" width="%s" height="%s" preserveAspectRatio="none"%s%s ' +
    'xlink:href="data:image/png;base64,%s"/>', [N(Min(A.X, B.X) - 0.5), N(Min(A.Y, B.Y) - 0.5), N(Abs(B.X - A.X)),
    N(Abs(B.Y - A.Y)), IfThen(Opacity < 1, ' opacity="' + N(Opacity) + '"', ''), Tf,
    PngBase64(Crop, CxSrc, CySrc, Alpha)]));
end;

procedure TMfConverter.DoPatBlt(X, Y, Cx, Cy: Integer; Rop: Cardinal);
var
  A, B: TPt;
  Fill: string;
begin
  // заливка прямоугольника кистью (PATCOPY) или цветом (BLACKNESS, WHITENESS)
  A := Map(X, Y);
  B := Map(X + Cx, Y + Cy);
  if Rop = PATCOPY then
    Fill := FillAttr
  else if Rop = BLACKNESS then
    Fill := 'fill="#000000"'
  else if Rop = WHITENESS then
    Fill := 'fill="#ffffff"'
  else
    Fill := '';
  if Fill = '' then
    Skip(Format('rop %.8x', [Rop]))
  else if Fill <> 'fill="none"' then
    FBody.Append(Format('<rect x="%s" y="%s" width="%s" height="%s" %s/>', [N(Min(A.X, B.X) - 0.5),
      N(Min(A.Y, B.Y) - 0.5), N(Abs(B.X - A.X)), N(Abs(B.Y - A.Y)), Fill]));
end;

procedure TMfConverter.ConvertEmf;
var
  Pos, T, Size, Ix: Integer;
  Frame, Bounds: TRect;
  Fx, Fy, Fw, Fh: Single;
  Obj: TMfObject;

  function Points(P, Count: Integer; Short: Boolean): TArray<TPt>;
  begin
    if (Count < 0) or (Count > FSize) then
      raise EMetafileToSvg.Create('Метафайл: неверное число точек');
    SetLength(Result, Count);
    for var I := 0 to Count - 1 do
      if Short then
        Result[I] := Pt2(I16(P + I * 4), I16(P + I * 4 + 2))
      else
        Result[I] := Pt2(I32(P + I * 8), I32(P + I * 8 + 4));
  end;

  // EMR_POLYPOLYGON(16)/POLYPOLYLINE(16): rclBounds, nPolys, cpts, aPolyCounts, точки
  procedure PolyPoly(P: Integer; Short, Closed: Boolean);
  var
    Counts: TArray<Integer>;
    NPolys: Integer;
  begin
    NPolys := I32(P + 24);
    if (NPolys < 0) or (NPolys > FSize) then
      raise EMetafileToSvg.Create('Метафайл: неверное число фигур');
    SetLength(Counts, NPolys);
    for var I := 0 to NPolys - 1 do
      Counts[I] := I32(P + 32 + I * 4);
    DoPolyPoly(Counts, Points(P + 32 + NPolys * 4, I32(P + 28), Short), Closed);
  end;

  procedure PolyTo(P: Integer; Short: Boolean);
  begin
    for var Q in Points(P + 28, I32(P + 24), Short) do
      DoLineTo(Round(Q.X), Round(Q.Y));
  end;

  // EMR_EXTTEXTOUTW: rclBounds, iGraphicsMode, ex/eyScale, ptlReference, nChars, offString, fOptions, rcl, offDx
  procedure Text(P: Integer);
  var
    Count, OffStr, OffDx, Opts, Step: Integer;
    S: string;
    Dx: TArray<Integer>;
  begin
    Count := I32(P + 44);
    OffStr := I32(P + 48);
    Opts := I32(P + 52);
    OffDx := I32(P + 72);
    if (Count > 0) and (Opts and ETO_GLYPH_INDEX = 0) then
    begin
      Need(P + OffStr, Count * 2);
      SetLength(S, Count);
      Move(FData[P + OffStr], S[1], Count * 2);
      if OffDx <> 0 then
      begin
        Step := IfThen(Opts and ETO_PDY <> 0, 2, 1);
        SetLength(Dx, Count);
        for var I := 0 to Count - 1 do
          Dx[I] := I32(P + OffDx + I * Step * 4);
      end;
    end
    else if Count > 0 then
      Skip('84 glyph');
    DoText(I32(P + 36), I32(P + 40), S, Opts, Rect(I32(P + 56), I32(P + 60), I32(P + 64), I32(P + 68)), Dx);
  end;

  // картинки: BITBLT/STRETCHBLT/ALPHABLEND (xDest, yDest, cxDest, cyDest, rop|blend, xSrc, ySrc, xform, bk, usage,
  // offBmi, cbBmi, offBits, cbBits[, cxSrc, cySrc]); STRETCHDIBITS/SETDIBITSTODEVICE - свой порядок полей
  procedure Bitmap(P, Kind: Integer);
  var
    XDest, YDest, CxDest, CyDest, XSrc, YSrc, CxSrc, CySrc, OffBmi, CbBmi, OffBits, CbBits, W, H: Integer;
    Rop: Cardinal;
    Alpha: Boolean;
    Opacity: Single;
  begin
    Alpha := False;
    Opacity := 1;
    case Kind of
      EMR_BITBLT, EMR_STRETCHBLT, EMR_ALPHABLEND:
        begin
          XDest := I32(P + 24); YDest := I32(P + 28); CxDest := I32(P + 32); CyDest := I32(P + 36);
          Rop := U32(P + 40);
          XSrc := I32(P + 44); YSrc := I32(P + 48);
          OffBmi := I32(P + 84); CbBmi := I32(P + 88); OffBits := I32(P + 92); CbBits := I32(P + 96);
          if Kind = EMR_BITBLT then
          begin
            CxSrc := CxDest;
            CySrc := CyDest;
          end
          else
          begin
            CxSrc := I32(P + 100);
            CySrc := I32(P + 104);
          end;
          if Kind = EMR_ALPHABLEND then
          begin
            Opacity := ((Rop shr 16) and $FF) / 255;
            Alpha := (Rop shr 24) and AC_SRC_ALPHA <> 0;
            Rop := SRCCOPY;
          end;
        end;
      EMR_STRETCHDIBITS:
        begin
          XDest := I32(P + 24); YDest := I32(P + 28); XSrc := I32(P + 32); YSrc := I32(P + 36);
          CxSrc := I32(P + 40); CySrc := I32(P + 44);
          OffBmi := I32(P + 48); CbBmi := I32(P + 52); OffBits := I32(P + 56); CbBits := I32(P + 60);
          Rop := U32(P + 68);
          CxDest := I32(P + 72); CyDest := I32(P + 76);
        end;
    else
      begin
        // EMR_SETDIBITSTODEVICE: строки источника - от iStartScan
        XDest := I32(P + 24); YDest := I32(P + 28); XSrc := I32(P + 32); YSrc := 0;
        CxSrc := I32(P + 40); CySrc := I32(P + 44);
        OffBmi := I32(P + 48); CbBmi := I32(P + 52); OffBits := I32(P + 56); CbBits := I32(P + 60);
        CxDest := CxSrc;
        CyDest := CySrc;
        Rop := SRCCOPY;
      end;
    end;
    if CbBmi = 0 then
      DoPatBlt(XDest, YDest, CxDest, CyDest, Rop)
    else if Rop <> SRCCOPY then
      Skip(Format('%d rop %.8x', [Kind, Rop]))
    else
    begin
      var Px := DecodeDib(FData, P + OffBmi, P + OffBits, CbBits, Alpha, W, H);
      DoImage(XDest, YDest, CxDest, CyDest, Px, W, H, XSrc, YSrc, CxSrc, CySrc, Alpha, Opacity);
    end;
  end;

  procedure PutObject(Index: Integer; const Obj: TMfObject);
  begin
    if (Index > 0) and (Index < Length(FObjects)) then
      FObjects[Index] := Obj;
  end;

begin
  Bounds := Rect(I32(8), I32(12), I32(16), I32(20));
  Frame := Rect(I32(24), I32(28), I32(32), I32(36));
  FDevX := IfThen((I32(72) > 0) and (I32(80) > 0), I32(72) / I32(80), 96 / 25.4);
  FDevY := IfThen((I32(76) > 0) and (I32(84) > 0), I32(76) / I32(84), 96 / 25.4);
  SetLength(FObjects, Max(Word(I16(56)), 1));
  DefaultState;
  // размер - рамка картинки (rclFrame, 0,01 мм) в пикселях эталонного устройства; нет рамки - границы рисунка;
  // целые пиксели: масштаб SVG к картинке - ровно 1
  Fx := Frame.Left * FDevX / 100;
  Fy := Frame.Top * FDevY / 100;
  Fw := (Frame.Right - Frame.Left) * FDevX / 100;
  Fh := (Frame.Bottom - Frame.Top) * FDevY / 100;
  if (Fw < 1) or (Fh < 1) then
  begin
    Fx := Bounds.Left;
    Fy := Bounds.Top;
    Fw := Max(1, Bounds.Right - Bounds.Left + 1);
    Fh := Max(1, Bounds.Bottom - Bounds.Top + 1);
  end;
  FInfo.Width := Max(1, Round(Fx + Fw) - Round(Fx));
  FInfo.Height := Max(1, Round(Fy + Fh) - Round(Fy));
  FViewX := Round(Fx);
  FViewY := Round(Fy);
  Pos := 0;
  while Pos + 8 <= FSize do
  begin
    T := I32(Pos);
    Size := I32(Pos + 4);
    if (Size < 8) or (Pos + Size > FSize) or (Size and 3 <> 0) then
      raise EMetafileToSvg.Create('Метафайл: неверная запись EMF');
    Inc(FInfo.Records);
    if (T <> EMR_MOVETOEX) and (T <> EMR_LINETO) and (T <> EMR_POLYLINETO16) and (T <> EMR_POLYLINETO) then
      FlushPath;
    case T of
      EMR_HEADER: ;
      EMR_EOF: Break;
      EMR_SETBKMODE: FDC.BkMode := U32(Pos + 8);
      EMR_SETBKCOLOR: FDC.BkColor := U32(Pos + 8);
      EMR_SETTEXTCOLOR: FDC.TextColor := U32(Pos + 8);
      EMR_SETPOLYFILLMODE: FDC.FillMode := U32(Pos + 8);
      EMR_SETROP2: FDC.Rop2 := U32(Pos + 8);
      EMR_SETTEXTALIGN: FDC.TextAlign := U32(Pos + 8);
      EMR_SETBRUSHORGEX: FDC.BrushOrg := Point(I32(Pos + 8), I32(Pos + 12));
      EMR_SETARCDIRECTION: FDC.ArcDir := U32(Pos + 8);
      EMR_SETMAPMODE: FDC.MapMode := U32(Pos + 8);
      EMR_SETWINDOWEXTEX: FDC.WinExt := Pt2(I32(Pos + 8), I32(Pos + 12));
      EMR_SETWINDOWORGEX: FDC.WinOrg := Pt2(I32(Pos + 8), I32(Pos + 12));
      EMR_SETVIEWPORTEXTEX: FDC.VpExt := Pt2(I32(Pos + 8), I32(Pos + 12));
      EMR_SETVIEWPORTORGEX: FDC.VpOrg := Pt2(I32(Pos + 8), I32(Pos + 12));
      EMR_SETWORLDTRANSFORM:
        begin
          Need(Pos + 8, 24);
          Move(FData[Pos + 8], FDC.World, SizeOf(TXf));
        end;
      EMR_MODIFYWORLDTRANSFORM:
        begin
          var X: TXf;
          Need(Pos + 8, 28);
          Move(FData[Pos + 8], X, SizeOf(TXf));
          case U32(Pos + 32) of
            MWT_IDENTITY: FDC.World := IdentityXf;
            MWT_LEFTMULTIPLY: FDC.World := MulXf(X, FDC.World);
            MWT_RIGHTMULTIPLY: FDC.World := MulXf(FDC.World, X);
            MWT_SET: FDC.World := X;
          end;
        end;
      EMR_SAVEDC: FStack.Add(FDC);
      EMR_RESTOREDC:
        begin
          Ix := I32(Pos + 8);
          if Ix < 0 then
            Ix := FStack.Count + Ix
          else
            Ix := Ix - 1;
          if (Ix >= 0) and (Ix < FStack.Count) then
          begin
            FDC := FStack[Ix];
            FStack.Count := Ix;
          end;
        end;
      EMR_CREATEPEN:
        begin
          Obj := Default(TMfObject);
          Obj.Kind := okPen;
          Obj.Pen.Style := U32(Pos + 12);
          Obj.Pen.Width := Max(1, I32(Pos + 16));
          Obj.Pen.Geometric := I32(Pos + 16) > 1;
          Obj.Pen.Color := U32(Pos + 24);
          PutObject(I32(Pos + 8), Obj);
        end;
      EMR_EXTCREATEPEN:
        begin
          Obj := Default(TMfObject);
          Obj.Kind := okPen;
          Obj.Pen.Style := U32(Pos + 28);
          Obj.Pen.Geometric := Obj.Pen.Style and PS_TYPE_MASK = PS_GEOMETRIC;
          Obj.Pen.Width := Max(1, I32(Pos + 32));
          Obj.Pen.Color := U32(Pos + 40);
          if U32(Pos + 36) = BS_NULL then
            Obj.Pen.Style := PS_NULL;
          PutObject(I32(Pos + 8), Obj);
        end;
      EMR_CREATEBRUSHINDIRECT:
        begin
          Obj := Default(TMfObject);
          Obj.Kind := okBrush;
          case U32(Pos + 12) of
            BS_SOLID: Obj.Brush.Kind := bkSolid;
            BS_HATCHED: Obj.Brush.Kind := bkHatch;
          else
            Obj.Brush.Kind := bkNull;
          end;
          Obj.Brush.Color := U32(Pos + 16);
          Obj.Brush.Hatch := U32(Pos + 20);
          PutObject(I32(Pos + 8), Obj);
        end;
      EMR_CREATEDIBPATTERNBRUSHPT:
        begin
          Obj := Default(TMfObject);
          Obj.Kind := okBrush;
          Obj.Brush := DibBrush(Pos + I32(Pos + 16), Pos + I32(Pos + 24), I32(Pos + 28));
          PutObject(I32(Pos + 8), Obj);
        end;
      EMR_EXTCREATEFONTINDIRECTW:
        begin
          // LOGFONTW: высота, ширина, наклон, поворот, насыщенность, курсив, подчёркивание, зачёркивание, набор,
          // точность, качество, семейство, имя (32 символа)
          Need(Pos + 12, 92);
          Obj := Default(TMfObject);
          Obj.Kind := okFont;
          Obj.Font.Height := I32(Pos + 12);
          Obj.Font.Width := I32(Pos + 16);
          Obj.Font.Escapement := I32(Pos + 20);
          Obj.Font.Orientation := I32(Pos + 24);
          Obj.Font.Weight := I32(Pos + 28);
          Obj.Font.Italic := FData[Pos + 32] <> 0;
          Obj.Font.Underline := FData[Pos + 33] <> 0;
          Obj.Font.StrikeOut := FData[Pos + 34] <> 0;
          Obj.Font.CharSet := FData[Pos + 35];
          Obj.Font.PitchAndFamily := FData[Pos + 39];
          SetLength(Obj.Font.Face, 32);
          Move(FData[Pos + 40], Obj.Font.Face[1], 64);
          if Obj.Font.Face.IndexOf(#0) >= 0 then
            SetLength(Obj.Font.Face, Obj.Font.Face.IndexOf(#0));
          PutObject(I32(Pos + 8), Obj);
        end;
      EMR_SELECTOBJECT: SelectObject(U32(Pos + 8));
      EMR_DELETEOBJECT: PutObject(I32(Pos + 8), Default(TMfObject));
      EMR_MOVETOEX: DoMoveTo(I32(Pos + 8), I32(Pos + 12));
      EMR_LINETO: DoLineTo(I32(Pos + 8), I32(Pos + 12));
      EMR_POLYLINETO16: PolyTo(Pos, True);
      EMR_POLYLINETO: PolyTo(Pos, False);
      EMR_POLYGON16, EMR_POLYGON, EMR_POLYLINE16, EMR_POLYLINE:
        DoPoly(Points(Pos + 28, I32(Pos + 24), (T = EMR_POLYGON16) or (T = EMR_POLYLINE16)),
          (T = EMR_POLYGON16) or (T = EMR_POLYGON));
      EMR_POLYPOLYGON16: PolyPoly(Pos, True, True);
      EMR_POLYPOLYGON: PolyPoly(Pos, False, True);
      EMR_POLYPOLYLINE16: PolyPoly(Pos, True, False);
      EMR_POLYPOLYLINE: PolyPoly(Pos, False, False);
      EMR_POLYBEZIER16, EMR_POLYBEZIER, EMR_POLYBEZIERTO16, EMR_POLYBEZIERTO:
        DoBezier(Points(Pos + 28, I32(Pos + 24), (T = EMR_POLYBEZIER16) or (T = EMR_POLYBEZIERTO16)),
          (T = EMR_POLYBEZIERTO16) or (T = EMR_POLYBEZIERTO));
      // прямоугольник фигуры в EMF - включительно (правый нижний угол на 1 меньше аргумента вызова GDI)
      EMR_RECTANGLE: DoRect(I32(Pos + 8), I32(Pos + 12), I32(Pos + 16), I32(Pos + 20));
      EMR_ELLIPSE: DoEllipse(I32(Pos + 8), I32(Pos + 12), I32(Pos + 16), I32(Pos + 20));
      EMR_ROUNDRECT: DoRoundRect(I32(Pos + 8), I32(Pos + 12), I32(Pos + 16), I32(Pos + 20), I32(Pos + 24),
        I32(Pos + 28));
      EMR_ARC, EMR_CHORD, EMR_PIE, EMR_ARCTO: DoArc(T, I32(Pos + 8), I32(Pos + 12), I32(Pos + 16),
        I32(Pos + 20), I32(Pos + 24), I32(Pos + 28), I32(Pos + 32), I32(Pos + 36));
      EMR_EXTTEXTOUTW: Text(Pos);
      EMR_BITBLT, EMR_STRETCHBLT, EMR_ALPHABLEND, EMR_STRETCHDIBITS, EMR_SETDIBITSTODEVICE: Bitmap(Pos, T);
    else
      begin
        var Quiet := False;
        for var Q in EmfQuiet do
          Quiet := Quiet or (Q = T);
        if not Quiet then
          Skip(IntToStr(T));
      end;
    end;
    Inc(Pos, Size);
  end;
  FlushPath;
end;

// однобайтовый текст WMF -> строка по набору символов шрифта (LOGFONT lfCharSet)
function AnsiText(const B: TBytes; CharSet: Byte): string;
var
  Cp: Integer;
  E: TEncoding;
begin
  case CharSet of
    77: Cp := 10000;
    128: Cp := 932;
    129: Cp := 949;
    134: Cp := 936;
    136: Cp := 950;
    161: Cp := 1253;
    162: Cp := 1254;
    163: Cp := 1258;
    177: Cp := 1255;
    178: Cp := 1256;
    186: Cp := 1257;
    204: Cp := 1251;
    222: Cp := 874;
    238: Cp := 1250;
    255: Cp := 437;
    1: Cp := 0;
  else
    Cp := 1252;
  end;
  try
    if Cp = 0 then
      Exit(TEncoding.ANSI.GetString(B));
    E := TEncoding.GetEncoding(Cp);
    try
      Result := E.GetString(B);
    finally
      E.Free;
    end;
  except
    // нет кодовой страницы на этой платформе - как Latin-1
    SetLength(Result, Length(B));
    for var I := 0 to High(B) do
      Result[I + 1] := Char(B[I]);
  end;
end;

procedure TMfConverter.ConvertWmf;
const
  META_EOF = $0000; META_SETBKCOLOR = $0201; META_SETBKMODE = $0102; META_SETMAPMODE = $0103; META_SETROP2 = $0104;
  META_SETPOLYFILLMODE = $0106; META_SETTEXTCOLOR = $0209; META_SETWINDOWORG = $020B; META_SETWINDOWEXT = $020C;
  META_SETVIEWPORTORG = $020D; META_SETVIEWPORTEXT = $020E; META_OFFSETWINDOWORG = $020F; META_SCALEWINDOWEXT = $0410;
  META_LINETO = $0213; META_MOVETO = $0214; META_ARC = $0817; META_ELLIPSE = $0418; META_PIE = $081A;
  META_RECTANGLE = $041B; META_ROUNDRECT = $061C; META_PATBLT = $061D; META_SAVEDC = $001E; META_SETPIXEL = $041F;
  META_TEXTOUT = $0521; META_POLYGON = $0324; META_POLYLINE = $0325; META_RESTOREDC = $0127; META_SELECTOBJECT = $012D;
  META_SETTEXTALIGN = $012E; META_CHORD = $0830; META_EXTTEXTOUT = $0A32; META_SETDIBTODEV = $0D33;
  META_POLYPOLYGON = $0538; META_DIBBITBLT = $0940; META_DIBSTRETCHBLT = $0B41; META_DIBCREATEPATTERNBRUSH = $0142;
  META_STRETCHDIB = $0F43; META_DELETEOBJECT = $01F0; META_CREATEPALETTE = $00F7; META_CREATEPATTERNBRUSH = $01F9;
  META_CREATEPENINDIRECT = $02FA; META_CREATEFONTINDIRECT = $02FB; META_CREATEBRUSHINDIRECT = $02FC;
  META_CREATEREGION = $06FF;
  // без видимого результата: SETRELABS, SETSTRETCHBLTMODE, SETTEXTCHAREXTRA, SETTEXTJUSTIFICATION, SETMAPPERFLAGS,
  // палитры, SETLAYOUT, ESCAPE
  WmfQuiet: array[0..11] of Integer = ($0105, $0107, $0108, $020A, $0231, $0234, $0035, $0436, $0037, $0139, $0149,
    $0626);
var
  Pos, Hdr, Size, Func, P, RecEnd, Inch, W, H: Integer;
  Box: TRect;
  Placeable, HasBox: Boolean;
  Obj: TMfObject;

  function Pts(At, Count: Integer): TArray<TPt>;
  begin
    if (Count < 0) or (At + Count * 4 > RecEnd) then
      raise EMetafileToSvg.Create('Метафайл: неверное число точек');
    SetLength(Result, Count);
    for var I := 0 to Count - 1 do
      Result[I] := Pt2(I16(At + I * 4), I16(At + I * 4 + 2));
  end;

  function Bytes(At, Count: Integer): TBytes;
  begin
    Need(At, Count);
    SetLength(Result, Count);
    if Count > 0 then
      Move(FData[At], Result[0], Count);
  end;

  // картинка записи: DIB с позиции At до конца записи
  procedure Image(At, XDest, YDest, CxDest, CyDest, XSrc, YSrc, CxSrc, CySrc: Integer; Rop: Cardinal);
  var
    Iw, Ih: Integer;
  begin
    if Rop <> SRCCOPY then
    begin
      Skip(Format('%.4x rop %.8x', [Func, Rop]));
      Exit;
    end;
    var Px := DecodeDib(FData, At, -1, RecEnd, False, Iw, Ih);
    // источник в DIB - от нижней строки (координаты GDI для DIB снизу вверх)
    DoImage(XDest, YDest, CxDest, CyDest, Px, Iw, Ih, XSrc, Ih - YSrc - CySrc, CxSrc, CySrc, False, 1);
  end;

begin
  FWmf := True;
  Placeable := U32(0) = $9AC6CDD7;
  Hdr := IfThen(Placeable, 22, 0);
  HasBox := False;
  Inch := 1440;
  if Placeable then
  begin
    Box := Rect(I16(6), I16(8), I16(10), I16(12));
    Inch := U16(14);
    if Inch = 0 then
      Inch := 1440;
    HasBox := (Box.Right <> Box.Left) and (Box.Bottom <> Box.Top);
  end;
  SetLength(FObjects, U16(Hdr + 10));
  FDevX := 96 / 25.4;
  FDevY := 96 / 25.4;
  DefaultState;
  Pos := Hdr + U16(Hdr + 2) * 2;
  if not HasBox then
  begin
    // без размещаемого заголовка: окно из первых SETWINDOWORG/SETWINDOWEXT, единица - пиксель
    P := Pos;
    Box := Rect(0, 0, 0, 0);
    while (P + 6 <= FSize) and (U32(P) >= 3) do
    begin
      if U16(P + 4) = META_SETWINDOWORG then
        Box.TopLeft := Point(I16(P + 8), I16(P + 6))
      else if (U16(P + 4) = META_SETWINDOWEXT) and not HasBox then
      begin
        Box.BottomRight := Point(I16(P + 8), I16(P + 6));
        HasBox := True;
      end
      else if U16(P + 4) = META_EOF then
        Break;
      Inc(P, Integer(U32(P)) * 2);
    end;
    if HasBox then
      Box := Rect(Box.Left, Box.Top, Box.Left + Box.Right, Box.Top + Box.Bottom)
    else
      Box := Rect(0, 0, 1024, 768);
    Inch := 96;
  end;
  // окно метафайла (рамка) -> картинка (96 точек на дюйм); записи окна метафайла меняют его, область вывода - картинка
  W := Max(1, Round(Abs(Box.Right - Box.Left) * 96 / Inch));
  H := Max(1, Round(Abs(Box.Bottom - Box.Top) * 96 / Inch));
  FInfo.Width := W;
  FInfo.Height := H;
  FDC.MapMode := MM_ANISOTROPIC;
  FDC.WinOrg := Pt2(Box.Left, Box.Top);
  FDC.WinExt := Pt2(Box.Right - Box.Left, Box.Bottom - Box.Top);
  FDC.VpOrg := Pt2(0, 0);
  FDC.VpExt := Pt2(W, H);
  while Pos + 6 <= FSize do
  begin
    Size := Integer(U32(Pos)) * 2;
    Func := U16(Pos + 4);
    if (Size < 6) or (Pos + Size > FSize) then
      raise EMetafileToSvg.Create('Метафайл: неверная запись WMF');
    P := Pos + 6;
    RecEnd := Pos + Size;
    Inc(FInfo.Records);
    if (Func <> META_MOVETO) and (Func <> META_LINETO) then
      FlushPath;
    case Func of
      META_EOF: Break;
      META_SETBKCOLOR: FDC.BkColor := U32(P);
      META_SETBKMODE: FDC.BkMode := U16(P);
      META_SETMAPMODE: FDC.MapMode := U16(P);
      META_SETROP2: FDC.Rop2 := U16(P);
      META_SETPOLYFILLMODE: FDC.FillMode := U16(P);
      META_SETTEXTCOLOR: FDC.TextColor := U32(P);
      META_SETTEXTALIGN: FDC.TextAlign := U16(P);
      META_SETWINDOWORG: FDC.WinOrg := Pt2(I16(P + 2), I16(P));
      META_SETWINDOWEXT: FDC.WinExt := Pt2(I16(P + 2), I16(P));
      META_OFFSETWINDOWORG: FDC.WinOrg := Pt2(FDC.WinOrg.X + I16(P + 2), FDC.WinOrg.Y + I16(P));
      META_SCALEWINDOWEXT:
        if (I16(P) <> 0) and (I16(P + 4) <> 0) then
          FDC.WinExt := Pt2(FDC.WinExt.X * I16(P + 6) / I16(P + 4), FDC.WinExt.Y * I16(P + 2) / I16(P));
      META_SAVEDC: FStack.Add(FDC);
      META_RESTOREDC:
        begin
          var Ix := I16(P);
          if Ix < 0 then
            Ix := FStack.Count + Ix
          else
            Ix := Ix - 1;
          if (Ix >= 0) and (Ix < FStack.Count) then
          begin
            FDC := FStack[Ix];
            FStack.Count := Ix;
          end;
        end;
      META_CREATEPENINDIRECT:
        begin
          Obj := Default(TMfObject);
          Obj.Kind := okPen;
          Obj.Pen.Style := U16(P);
          Obj.Pen.Width := Max(1, I16(P + 2));
          Obj.Pen.Geometric := I16(P + 2) > 1;
          Obj.Pen.Color := U32(P + 6);
          AddObject(Obj);
        end;
      META_CREATEBRUSHINDIRECT:
        begin
          Obj := Default(TMfObject);
          Obj.Kind := okBrush;
          case U16(P) of
            BS_SOLID: Obj.Brush.Kind := bkSolid;
            BS_HATCHED: Obj.Brush.Kind := bkHatch;
          else
            Obj.Brush.Kind := bkNull;
          end;
          Obj.Brush.Color := U32(P + 2);
          Obj.Brush.Hatch := U16(P + 6);
          AddObject(Obj);
        end;
      META_DIBCREATEPATTERNBRUSH:
        begin
          Obj := Default(TMfObject);
          Obj.Kind := okBrush;
          if U16(P) = 3 then
          begin
            // BS_PATTERN - картинка устройства (Bitmap16): не разбирается, серая кисть
            Obj.Brush.Kind := bkSolid;
            Obj.Brush.Color := $808080;
            Skip(Format('%.4x bitmap16', [Func]));
          end
          else
            Obj.Brush := DibBrush(P + 4, -1, RecEnd);
          AddObject(Obj);
        end;
      META_CREATEFONTINDIRECT:
        begin
          Obj := Default(TMfObject);
          Obj.Kind := okFont;
          Obj.Font.Height := I16(P);
          Obj.Font.Width := I16(P + 2);
          Obj.Font.Escapement := I16(P + 4);
          Obj.Font.Orientation := I16(P + 6);
          Obj.Font.Weight := I16(P + 8);
          Obj.Font.Italic := FData[P + 10] <> 0;
          Obj.Font.Underline := FData[P + 11] <> 0;
          Obj.Font.StrikeOut := FData[P + 12] <> 0;
          Obj.Font.CharSet := FData[P + 13];
          Obj.Font.PitchAndFamily := FData[P + 17];
          var Face := Bytes(P + 18, Min(32, RecEnd - (P + 18)));
          var Z := 0;
          while (Z < Length(Face)) and (Face[Z] <> 0) do
            Inc(Z);
          Obj.Font.Face := AnsiText(Copy(Face, 0, Z), Obj.Font.CharSet);
          AddObject(Obj);
        end;
      META_CREATEPALETTE, META_CREATEPATTERNBRUSH, META_CREATEREGION:
        begin
          // занимают место в таблице объектов
          Obj := Default(TMfObject);
          Obj.Kind := okOther;
          AddObject(Obj);
          if Func = META_CREATEPATTERNBRUSH then
            Skip(Format('%.4x', [Func]));
        end;
      META_SELECTOBJECT: SelectObject(U16(P));
      META_DELETEOBJECT:
        if U16(P) < Length(FObjects) then
          FObjects[U16(P)] := Default(TMfObject);
      META_MOVETO: DoMoveTo(I16(P + 2), I16(P));
      META_LINETO: DoLineTo(I16(P + 2), I16(P));
      META_POLYGON, META_POLYLINE: DoPoly(Pts(P + 2, I16(P)), Func = META_POLYGON);
      META_POLYPOLYGON:
        begin
          var Counts: TArray<Integer>;
          SetLength(Counts, U16(P));
          var Total := 0;
          for var I := 0 to High(Counts) do
          begin
            Counts[I] := U16(P + 2 + I * 2);
            Inc(Total, Counts[I]);
          end;
          DoPolyPoly(Counts, Pts(P + 2 + Length(Counts) * 2, Total), True);
        end;
      META_RECTANGLE: DoRect(I16(P + 6), I16(P + 4), I16(P + 2), I16(P));
      META_ELLIPSE: DoEllipse(I16(P + 6), I16(P + 4), I16(P + 2), I16(P));
      META_ROUNDRECT: DoRoundRect(I16(P + 10), I16(P + 8), I16(P + 6), I16(P + 4), I16(P + 2), I16(P));
      META_ARC, META_PIE, META_CHORD:
        DoArc(IfThen(Func = META_PIE, EMR_PIE, IfThen(Func = META_CHORD, EMR_CHORD, EMR_ARC)), I16(P + 14), I16(P + 12),
          I16(P + 10), I16(P + 8), I16(P + 6), I16(P + 4), I16(P + 2), I16(P));
      META_SETPIXEL:
        begin
          var A := Map(I16(P + 6), I16(P + 4));
          FBody.Append(Format('<rect x="%s" y="%s" width="1" height="1" fill="%s"/>', [N(A.X - 0.5), N(A.Y - 0.5),
            Col(U32(P))]));
        end;
      META_PATBLT: DoPatBlt(I16(P + 10), I16(P + 8), I16(P + 6), I16(P + 4), U32(P));
      META_TEXTOUT:
        begin
          var Len := U16(P);
          var At := P + 2 + ((Len + 1) div 2) * 2;
          DoText(I16(At + 2), I16(At), AnsiText(Bytes(P + 2, Len), FDC.Font.CharSet), 0, Rect(0, 0, 0, 0), nil);
        end;
      META_EXTTEXTOUT:
        begin
          var Y := I16(P);
          var X := I16(P + 2);
          var Len := I16(P + 4);
          var Opts := U16(P + 6);
          var At := P + 8;
          var Rc := Rect(0, 0, 0, 0);
          if Opts and (ETO_OPAQUE or ETO_CLIPPED) <> 0 then
          begin
            Rc := Rect(I16(At), I16(At + 2), I16(At + 4), I16(At + 6));
            Inc(At, 8);
          end;
          var S := AnsiText(Bytes(At, Max(0, Len)), FDC.Font.CharSet);
          Inc(At, ((Max(0, Len) + 1) div 2) * 2);
          var Dx: TArray<Integer>;
          if (Len > 0) and (At + Len * 2 <= RecEnd) and (Length(S) = Len) then
          begin
            SetLength(Dx, Len);
            for var I := 0 to Len - 1 do
              Dx[I] := I16(At + I * 2);
          end;
          DoText(X, Y, S, Opts, Rc, Dx);
        end;
      // без картинки (размер записи - (функция shr 8) + 3 слова): rop, источник, резерв, назначение - заливка
      META_DIBBITBLT:
        if Size = 2 * (Func shr 8 + 3) then
          DoPatBlt(I16(P + 16), I16(P + 14), I16(P + 12), I16(P + 10), U32(P))
        else
          Image(P + 16, I16(P + 14), I16(P + 12), I16(P + 10), I16(P + 8), I16(P + 6), I16(P + 4), I16(P + 10),
            I16(P + 8), U32(P));
      META_DIBSTRETCHBLT:
        if Size = 2 * (Func shr 8 + 3) then
          DoPatBlt(I16(P + 20), I16(P + 18), I16(P + 16), I16(P + 14), U32(P))
        else
          Image(P + 20, I16(P + 18), I16(P + 16), I16(P + 14), I16(P + 12), I16(P + 10), I16(P + 8), I16(P + 6),
            I16(P + 4), U32(P));
      META_STRETCHDIB:
        Image(P + 22, I16(P + 20), I16(P + 18), I16(P + 16), I16(P + 14), I16(P + 12), I16(P + 10), I16(P + 8),
          I16(P + 6), U32(P));
      META_SETDIBTODEV:
        Image(P + 18, I16(P + 16), I16(P + 14), I16(P + 12), I16(P + 10), I16(P + 8), I16(P + 6), I16(P + 12),
          I16(P + 10), SRCCOPY);
    else
      begin
        var Quiet := False;
        for var Q in WmfQuiet do
          Quiet := Quiet or (Q = Func);
        if not Quiet then
          Skip(Format('%.4x', [Func]));
      end;
    end;
    Inc(Pos, Size);
  end;
  FlushPath;
end;

// EMF, вложенный в WMF комментариями META_ESCAPE/MFCOMMENT «WMFC» (так пишет WMF сама Windows, GetWinMetaFileBits);
// нет или неполный - nil
function EmbeddedEmf(const D: TBytes): TBytes;
var
  Pos, Size, Total, Chunk, Got: Integer;

  function U16(P: Integer): Word;
  begin
    Move(D[P], Result, 2);
  end;

  function U32(P: Integer): Cardinal;
  begin
    Move(D[P], Result, 4);
  end;

begin
  Result := nil;
  Pos := 0;
  if (Length(D) >= 22) and (U32(0) = $9AC6CDD7) then
    Pos := 22;
  if Pos + 18 > Length(D) then
    Exit;
  Pos := Pos + U16(Pos + 2) * 2;
  Total := -1;
  Got := 0;
  while Pos + 6 <= Length(D) do
  begin
    Size := Integer(U32(Pos)) * 2;
    if (Size < 6) or (Pos + Size > Length(D)) or (U16(Pos + 4) = 0) then
      Break;
    // EscapeFunction MFCOMMENT, ByteCount, CommentIdentifier WMFC, CommentType 1, Version, Checksum, Flags,
    // CommentRecordCount, CurrentRecordSize, RemainingBytes, EnhancedMetafileDataSize, данные
    if (U16(Pos + 4) = $0626) and (Size >= 6 + 38) and (U16(Pos + 6) = $000F) and (U32(Pos + 10) = $43464D57) and
      (U32(Pos + 14) = 1) then
    begin
      Chunk := U32(Pos + 32);
      if Total < 0 then
      begin
        Total := U32(Pos + 40);
        if (Total <= 0) or (Total > Length(D)) then
          Exit;
        SetLength(Result, Total);
      end;
      if (Chunk < 0) or (Got + Chunk > Total) or (Pos + 44 + Chunk > Pos + Size) then
        Exit(nil);
      Move(D[Pos + 44], Result[Got], Chunk);
      Inc(Got, Chunk);
    end;
    Inc(Pos, Size);
  end;
  if (Total <= 0) or (Got <> Total) or not IsEmf(Result) then
    Result := nil;
end;

function TMfConverter.Convert: string;
var
  Head: string;
  Inner: TBytes;
begin
  if IsWmf(FData) then
  begin
    Inner := EmbeddedEmf(FData);
    if Inner <> nil then
    begin
      // WMF, сделанный Windows из EMF: рисуется исходный EMF (как это делает сама Windows)
      FData := Inner;
      FSize := Length(Inner);
      FInfo.Format := 'WMF+EMF';
      ConvertEmf;
    end
    else
    begin
      FInfo.Format := 'WMF';
      ConvertWmf;
    end;
  end
  else if IsEmf(FData) then
  begin
    FInfo.Format := 'EMF';
    ConvertEmf;
  end
  else
    raise EMetafileToSvg.Create('Не метафайл: нет заголовка EMF или WMF');
  for var Pair in FSkipped do
    FInfo.SkippedTypes := FInfo.SkippedTypes + IfThen(FInfo.SkippedTypes <> '', ',', '') +
      Format('%s×%d', [Pair.Key, Pair.Value]);
  Head := Format('<?xml version="1.0" encoding="UTF-8"?>'#10'<svg xmlns="http://www.w3.org/2000/svg" ' +
    'xmlns:xlink="http://www.w3.org/1999/xlink" width="%d" height="%d" viewBox="%s %s %d %d">', [FInfo.Width,
    FInfo.Height, N(FViewX - 0.5), N(FViewY - 0.5), FInfo.Width, FInfo.Height]);
  if FDefs.Length > 0 then
    Head := Head + '<defs>' + FDefs.ToString + '</defs>';
  Result := Head + FBody.ToString + '</svg>'#10;
end;

{ функции }

function MetafileToSvg(const Data: TBytes; out Info: TMfInfo; const Metrics: IMfFontMetrics): string;
var
  C: TMfConverter;
begin
  C := TMfConverter.Create(Data, Metrics);
  try
    Result := C.Convert;
    Info := C.Info;
  finally
    C.Free;
  end;
end;

function MetafileToSvg(const Data: TBytes): string;
var
  Info: TMfInfo;
begin
  Result := MetafileToSvg(Data, Info, nil);
end;

initialization
  Builtin := TBuiltinMetrics.Create;
  MfDefaultFontMetrics := Builtin;

end.
