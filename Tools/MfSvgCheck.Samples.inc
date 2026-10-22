// Синтетические метафайлы для MfSvgCheck --make-samples: рисует GDI в EMF (CreateEnhMetaFile), по файлу на тему -
// фигуры и перья, кисти, текст, картинки, отображение координат. WMF из них - MfSvgCheck --wmf.

function NewEmf(const FileName: string; W, H: Integer): HDC;
var
  Ref: HDC;
  Frame: TRect;
begin
  // рамка (0,01 мм) - W x H пикселей экрана
  Ref := GetDC(0);
  try
    Frame := Rect(0, 0, MulDiv(W, GetDeviceCaps(Ref, HORZSIZE) * 100, GetDeviceCaps(Ref, HORZRES)),
      MulDiv(H, GetDeviceCaps(Ref, VERTSIZE) * 100, GetDeviceCaps(Ref, VERTRES)));
    Result := CreateEnhMetaFileW(Ref, PChar(FileName), @Frame, PChar('PasWmfToSvg'#0'sample'#0#0));
  finally
    ReleaseDC(0, Ref);
  end;
end;

procedure CloseEmf(Dc: HDC);
begin
  DeleteEnhMetaFile(CloseEnhMetaFile(Dc));
end;

function Pen(Style, Width: Integer; Color: COLORREF): HPEN;
begin
  Result := CreatePen(Style, Width, Color);
end;

procedure Use(Dc: HDC; Obj: HGDIOBJ);
begin
  DeleteObject(SelectObject(Dc, Obj));
end;

procedure SampleShapes(const Dir: string);
var
  Dc: HDC;
  Lb: TLogBrush;
  Star: array[0..4] of TPoint;
  Zig: array[0..4] of TPoint;
  Bez: array[0..6] of TPoint;
  Pp: array[0..7] of TPoint;
  Counts: array[0..1] of Integer;
begin
  Dc := NewEmf(TPath.Combine(Dir, 's01_shapes.emf'), 480, 360);
  SetBkColor(Dc, RGB(255, 240, 160));
  Use(Dc, Pen(PS_SOLID, 1, 0));
  Use(Dc, CreateSolidBrush(RGB(255, 255, 255)));
  Rectangle(Dc, 10, 10, 110, 60);
  SelectObject(Dc, GetStockObject(NULL_PEN));
  Use(Dc, CreateSolidBrush(RGB(60, 120, 220)));
  Rectangle(Dc, 120, 10, 220, 60);
  // штриховые перья: фон непрозрачный и прозрачный
  for var I := 0 to 3 do
  begin
    Use(Dc, Pen(PS_DASH + I, 1, RGB(160, 0, 0)));
    SetBkMode(Dc, OPAQUE);
    MoveToEx(Dc, 240, 14 + I * 12, nil);
    LineTo(Dc, 470, 14 + I * 12);
  end;
  SetBkMode(Dc, TRANSPARENT);
  Use(Dc, Pen(PS_DASHDOT, 1, RGB(0, 120, 0)));
  MoveToEx(Dc, 240, 64, nil);
  LineTo(Dc, 470, 64);
  // геометрические перья: круглые концы (CreatePen) и плоские со стыком «угол» (ExtCreatePen)
  Zig[0] := Point(20, 120); Zig[1] := Point(60, 80); Zig[2] := Point(100, 120); Zig[3] := Point(140, 80);
  Zig[4] := Point(180, 120);
  Use(Dc, Pen(PS_SOLID, 6, RGB(0, 90, 160)));
  Polyline(Dc, Zig, 5);
  Lb.lbStyle := BS_SOLID;
  Lb.lbColor := RGB(200, 90, 0);
  Lb.lbHatch := 0;
  Use(Dc, ExtCreatePen(PS_GEOMETRIC or PS_SOLID or PS_ENDCAP_FLAT or PS_JOIN_MITER, 8, Lb, 0, nil));
  for var I := 0 to 4 do
    Zig[I].Y := Zig[I].Y + 50;
  Polyline(Dc, Zig, 5);
  // звезда: чередование и обход
  Use(Dc, Pen(PS_SOLID, 1, 0));
  Use(Dc, CreateSolidBrush(RGB(250, 200, 40)));
  for var K := 0 to 1 do
  begin
    for var I := 0 to 4 do
      Star[I] := Point(260 + K * 110 + Round(45 * Sin(I * 4 * Pi / 5)), 130 - Round(45 * Cos(I * 4 * Pi / 5)));
    SetPolyFillMode(Dc, IfThen(K = 0, ALTERNATE, WINDING));
    Polygon(Dc, Star, 5);
  end;
  // эллипс, скруглённый прямоугольник, дуги (против и по часовой), хорда, сектор
  Use(Dc, CreateSolidBrush(RGB(150, 220, 150)));
  Ellipse(Dc, 10, 190, 90, 250);
  RoundRect(Dc, 100, 190, 190, 250, 24, 16);
  Arc(Dc, 200, 190, 260, 250, 260, 190, 200, 250);
  SetArcDirection(Dc, AD_CLOCKWISE);
  Arc(Dc, 270, 190, 330, 250, 330, 190, 270, 250);
  SetArcDirection(Dc, AD_COUNTERCLOCKWISE);
  Chord(Dc, 340, 190, 400, 250, 400, 220, 340, 200);
  Pie(Dc, 410, 190, 470, 250, 470, 220, 440, 190);
  // кривая Безье, многоугольник с вырезом
  Bez[0] := Point(20, 340); Bez[1] := Point(60, 260); Bez[2] := Point(100, 360); Bez[3] := Point(140, 290);
  Bez[4] := Point(170, 260); Bez[5] := Point(200, 350); Bez[6] := Point(230, 300);
  Use(Dc, Pen(PS_SOLID, 2, RGB(120, 0, 160)));
  PolyBezier(Dc, Bez, 7);
  Pp[0] := Point(260, 270); Pp[1] := Point(360, 270); Pp[2] := Point(360, 350); Pp[3] := Point(260, 350);
  Pp[4] := Point(285, 290); Pp[5] := Point(335, 290); Pp[6] := Point(335, 330); Pp[7] := Point(285, 330);
  Counts[0] := 4;
  Counts[1] := 4;
  SetPolyFillMode(Dc, ALTERNATE);
  Use(Dc, Pen(PS_SOLID, 1, 0));
  Use(Dc, CreateSolidBrush(RGB(90, 160, 230)));
  PolyPolygon(Dc, Pp, Counts, 2);
  // сетка отрезков
  for var I := 0 to 5 do
  begin
    MoveToEx(Dc, 380, 270 + I * 15, nil);
    LineTo(Dc, 470, 270 + I * 15);
    MoveToEx(Dc, 380 + I * 18, 270, nil);
    LineTo(Dc, 380 + I * 18, 345);
  end;
  CloseEmf(Dc);
end;

procedure SampleBrushes(const Dir: string);
var
  Dc: HDC;
  Dib: packed record
    Hdr: TBitmapInfoHeader;
    Bits: array[0..63] of Cardinal;
  end;
begin
  Dc := NewEmf(TPath.Combine(Dir, 's02_brushes.emf'), 480, 280);
  Use(Dc, Pen(PS_SOLID, 1, 0));
  SetBkColor(Dc, RGB(255, 245, 200));
  for var Row := 0 to 1 do
  begin
    SetBkMode(Dc, IfThen(Row = 0, OPAQUE, TRANSPARENT));
    for var H := HS_HORIZONTAL to HS_DIAGCROSS do
    begin
      Use(Dc, CreateHatchBrush(H, RGB(0, 70, 160)));
      Rectangle(Dc, 10 + H * 78, 10 + Row * 80, 80 + H * 78, 80 + Row * 80);
    end;
  end;
  // DIB-узор 8x8 (шахматка) и сдвиг начала узора
  Dib.Hdr := Default(TBitmapInfoHeader);
  Dib.Hdr.biSize := SizeOf(TBitmapInfoHeader);
  Dib.Hdr.biWidth := 8;
  Dib.Hdr.biHeight := 8;
  Dib.Hdr.biPlanes := 1;
  Dib.Hdr.biBitCount := 32;
  for var Y := 0 to 7 do
    for var X := 0 to 7 do
      Dib.Bits[Y * 8 + X] := IfThen((X div 4 + Y div 4) mod 2 = 0, $00C04020, $00F0E0B0);
  Use(Dc, CreateDIBPatternBrushPt(@Dib, DIB_RGB_COLORS));
  Rectangle(Dc, 10, 180, 230, 270);
  SetBrushOrgEx(Dc, 3, 2, nil);
  Use(Dc, CreateDIBPatternBrushPt(@Dib, DIB_RGB_COLORS));
  Rectangle(Dc, 250, 180, 470, 270);
  CloseEmf(Dc);
end;

function MakeFont(const Face: string; Height, Weight: Integer; Italic, Underline: Boolean; Escapement: Integer = 0;
  CharSet: Byte = DEFAULT_CHARSET): HFONT;
var
  Lf: TLogFontW;
begin
  Lf := Default(TLogFontW);
  Lf.lfHeight := Height;
  Lf.lfWeight := Weight;
  Lf.lfItalic := Ord(Italic);
  Lf.lfUnderline := Ord(Underline);
  Lf.lfEscapement := Escapement;
  Lf.lfOrientation := Escapement;
  Lf.lfCharSet := CharSet;
  Lf.lfQuality := NONANTIALIASED_QUALITY;
  StrPLCopy(Lf.lfFaceName, Face, High(Lf.lfFaceName));
  Result := CreateFontIndirectW(Lf);
end;

procedure Out(Dc: HDC; X, Y: Integer; const S: string);
begin
  TextOutW(Dc, X, Y, PChar(S), Length(S));
end;

procedure Mark(Dc: HDC; X, Y: Integer);
begin
  MoveToEx(Dc, X - 4, Y, nil);
  LineTo(Dc, X + 5, Y);
  MoveToEx(Dc, X, Y - 4, nil);
  LineTo(Dc, X, Y + 5);
end;

procedure SampleText(const Dir: string);
var
  Dc: HDC;
  R: TRect;
  Dx: array[0..5] of Integer;
  S: string;
begin
  Dc := NewEmf(TPath.Combine(Dir, 's03_text.emf'), 480, 360);
  Use(Dc, Pen(PS_SOLID, 1, RGB(200, 0, 0)));
  SetBkMode(Dc, TRANSPARENT);
  Use(Dc, MakeFont('Arial', -16, 400, False, False));
  Out(Dc, 10, 10, 'Arial 16 Hello, Окно 1200x1400');
  Use(Dc, MakeFont('Tahoma', -11, 400, False, False));
  Out(Dc, 10, 34, 'Tahoma 11: 1234567890 SW');
  Use(Dc, MakeFont('Times New Roman', -20, 700, False, False));
  Out(Dc, 10, 52, 'Times bold Ёлка');
  Use(Dc, MakeFont('Courier New', -14, 400, True, True));
  Out(Dc, 10, 80, 'Courier italic underline');
  // выравнивание относительно отметок
  Use(Dc, MakeFont('Arial', -14, 400, False, False));
  SetTextColor(Dc, RGB(0, 0, 160));
  for var I := 0 to 2 do
  begin
    var X := 330;
    var Y := 30 + I * 30;
    Mark(Dc, X, Y);
    case I of
      0: SetTextAlign(Dc, TA_RIGHT or TA_BASELINE);
      1: SetTextAlign(Dc, TA_CENTER or TA_BOTTOM);
    else
      SetTextAlign(Dc, TA_LEFT or TA_TOP);
    end;
    Out(Dc, X, Y, 'Align ' + IntToStr(I));
  end;
  SetTextAlign(Dc, TA_LEFT or TA_TOP);
  // непрозрачный фон текста и ETO_OPAQUE
  SetBkMode(Dc, OPAQUE);
  SetBkColor(Dc, RGB(255, 230, 120));
  SetTextColor(Dc, 0);
  Out(Dc, 10, 120, 'Opaque background');
  SetBkColor(Dc, RGB(190, 230, 255));
  R := Rect(200, 116, 470, 142);
  S := 'ExtTextOut ETO_OPAQUE';
  ExtTextOutW(Dc, 210, 120, ETO_OPAQUE, @R, PChar(S), Length(S), nil);
  SetBkMode(Dc, TRANSPARENT);
  // межсимвольные расстояния
  S := 'SPACED';
  for var I := 0 to 5 do
    Dx[I] := 22;
  ExtTextOutW(Dc, 10, 160, 0, nil, PChar(S), Length(S), @Dx[0]);
  // наклон 90 и 30 градусов
  Use(Dc, MakeFont('Arial', -16, 400, False, False, 900));
  Mark(Dc, 40, 340);
  Out(Dc, 40, 340, 'Vertical 90');
  Use(Dc, MakeFont('Arial', -16, 700, False, False, 300));
  Mark(Dc, 120, 330);
  Out(Dc, 120, 330, 'Наклон 30 градусов');
  // кириллица шрифтом с набором RUSSIAN_CHARSET (в WMF - однобайтовый текст)
  Use(Dc, MakeFont('Tahoma', -13, 400, False, False, 0, RUSSIAN_CHARSET));
  Out(Dc, 260, 200, 'Профиль 70 мм, Ёё');
  CloseEmf(Dc);
end;

procedure SampleImages(const Dir: string);
var
  Dc, Mem: HDC;
  Bi: TBitmapInfo;
  Pal: packed record
    Hdr: TBitmapInfoHeader;
    Colors: array[0..255] of Cardinal;
  end;
  Px24: array of Byte;
  Px8: array of Byte;
  Px1: array[0..63] of Byte;
  Bits: Pointer;
  Bmp: HBITMAP;
  Old: HGDIOBJ;
  Bf: TBlendFunction;
begin
  Dc := NewEmf(TPath.Combine(Dir, 's04_images.emf'), 480, 330);
  // 24 бита: градиент 64x48 -> 128x96 (STRETCHDIBITS)
  Bi := Default(TBitmapInfo);
  Bi.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
  Bi.bmiHeader.biWidth := 64;
  Bi.bmiHeader.biHeight := 48;
  Bi.bmiHeader.biPlanes := 1;
  Bi.bmiHeader.biBitCount := 24;
  SetLength(Px24, 64 * 3 * 48);
  for var Y := 0 to 47 do
    for var X := 0 to 63 do
    begin
      Px24[(Y * 64 + X) * 3] := X * 4;
      Px24[(Y * 64 + X) * 3 + 1] := Y * 5;
      Px24[(Y * 64 + X) * 3 + 2] := 255 - X * 4;
    end;
  StretchDIBits(Dc, 10, 10, 128, 96, 0, 0, 64, 48, @Px24[0], Bi, DIB_RGB_COLORS, SRCCOPY);
  // часть картинки (источник со сдвигом) 1:1
  StretchDIBits(Dc, 150, 10, 32, 24, 16, 8, 32, 24, @Px24[0], Bi, DIB_RGB_COLORS, SRCCOPY);
  // 8 бит с палитрой: 16x16 -> 64x64
  Pal.Hdr := Bi.bmiHeader;
  Pal.Hdr.biWidth := 16;
  Pal.Hdr.biHeight := 16;
  Pal.Hdr.biBitCount := 8;
  Pal.Hdr.biClrUsed := 256;
  for var I := 0 to 255 do
    Pal.Colors[I] := RGB(I, 255 - I, (I * 7) and $FF);
  SetLength(Px8, 16 * 16);
  for var I := 0 to 255 do
    Px8[I] := I;
  StretchDIBits(Dc, 200, 10, 64, 64, 0, 0, 16, 16, @Px8[0], PBitmapInfo(@Pal)^, DIB_RGB_COLORS, SRCCOPY);
  // 1 бит: 16x16 шахматка -> 64x64
  Pal.Hdr.biBitCount := 1;
  Pal.Hdr.biClrUsed := 2;
  Pal.Colors[0] := $00202020;
  Pal.Colors[1] := $00E0F0FF;
  for var Y := 0 to 15 do
  begin
    Px1[Y * 4] := IfThen(Y mod 4 < 2, $CC, $33);
    Px1[Y * 4 + 1] := Px1[Y * 4];
  end;
  StretchDIBits(Dc, 280, 10, 64, 64, 0, 0, 16, 16, @Px1[0], PBitmapInfo(@Pal)^, DIB_RGB_COLORS, SRCCOPY);
  // SETDIBITSTODEVICE
  SetDIBitsToDevice(Dc, 360, 10, 64, 48, 0, 0, 0, 48, @Px24[0], Bi, DIB_RGB_COLORS);
  // BITBLT из картинки в памяти и ALPHABLEND с альфой по пикселям (круг)
  Bi.bmiHeader.biWidth := 80;
  Bi.bmiHeader.biHeight := -80;
  Bi.bmiHeader.biBitCount := 32;
  Mem := CreateCompatibleDC(0);
  Bmp := CreateDIBSection(Mem, Bi, DIB_RGB_COLORS, Bits, 0, 0);
  Old := SelectObject(Mem, Bmp);
  for var Y := 0 to 79 do
    for var X := 0 to 79 do
    begin
      var D := Sqrt(Sqr(X - 39.5) + Sqr(Y - 39.5));
      var A := EnsureRange(Round((40 - D) * 255 / 6), 0, 255);
      var C := Cardinal((X * 3) or ((Y * 3) shl 8) or (200 shl 16));
      // предумноженная альфа
      PCardinal(NativeUInt(Bits) + NativeUInt((Y * 80 + X) * 4))^ := (Cardinal(A) shl 24) or
        (((C shr 16) and $FF) * Cardinal(A) div 255 shl 16) or (((C shr 8) and $FF) * Cardinal(A) div 255 shl 8) or
        ((C and $FF) * Cardinal(A) div 255);
    end;
  BitBlt(Dc, 10, 130, 80, 80, Mem, 0, 0, SRCCOPY);
  Use(Dc, CreateSolidBrush(RGB(40, 140, 60)));
  Rectangle(Dc, 120, 130, 330, 220);
  Bf.BlendOp := AC_SRC_OVER;
  Bf.BlendFlags := 0;
  Bf.SourceConstantAlpha := 255;
  Bf.AlphaFormat := AC_SRC_ALPHA;
  AlphaBlend(Dc, 130, 135, 80, 80, Mem, 0, 0, 80, 80, Bf);
  Bf.SourceConstantAlpha := 128;
  AlphaBlend(Dc, 230, 135, 96, 80, Mem, 0, 0, 80, 80, Bf);
  SelectObject(Mem, Old);
  DeleteObject(Bmp);
  DeleteDC(Mem);
  // PATBLT кистью (BITBLT без картинки)
  Use(Dc, CreateHatchBrush(HS_DIAGCROSS, RGB(160, 0, 0)));
  PatBlt(Dc, 350, 130, 120, 80, PATCOPY);
  PatBlt(Dc, 350, 230, 120, 40, BLACKNESS);
  CloseEmf(Dc);
end;

procedure SampleMapping(const Dir: string);
var
  Dc: HDC;
  X: TXForm;
begin
  Dc := NewEmf(TPath.Combine(Dir, 's05_mapping.emf'), 480, 330);
  Use(Dc, Pen(PS_SOLID, 1, 0));
  Use(Dc, MakeFont('Arial', -60, 400, False, False));
  SetBkMode(Dc, TRANSPARENT);
  // MM_ANISOTROPIC: окно 1000x1000 -> 200x150 пикселей от (10, 10)
  SaveDC(Dc);
  SetMapMode(Dc, MM_ANISOTROPIC);
  SetWindowExtEx(Dc, 1000, 1000, nil);
  SetViewportExtEx(Dc, 200, 150, nil);
  SetViewportOrgEx(Dc, 10, 10, nil);
  Use(Dc, CreateSolidBrush(RGB(200, 230, 255)));
  Rectangle(Dc, 0, 0, 1000, 1000);
  Ellipse(Dc, 100, 100, 600, 900);
  Out(Dc, 620, 400, 'Win');
  RestoreDC(Dc, -1);
  // MM_LOMETRIC: 0,1 мм, ось Y вверх, начало (250, 160)
  SaveDC(Dc);
  SetMapMode(Dc, MM_LOMETRIC);
  SetViewportOrgEx(Dc, 250, 160, nil);
  Use(Dc, CreateSolidBrush(RGB(255, 220, 180)));
  Rectangle(Dc, 0, 0, 500, -350);
  MoveToEx(Dc, 0, 0, nil);
  LineTo(Dc, 500, -350);
  RestoreDC(Dc, -1);
  // мировое преобразование: поворот на 20 градусов вокруг (330, 250)
  SetGraphicsMode(Dc, GM_ADVANCED);
  X.eM11 := Cos(20 * Pi / 180);
  X.eM12 := Sin(20 * Pi / 180);
  X.eM21 := -X.eM12;
  X.eM22 := X.eM11;
  X.eDx := 330 - 330 * X.eM11 + 250 * X.eM12;
  X.eDy := 250 - 330 * X.eM12 - 250 * X.eM11;
  SetWorldTransform(Dc, X);
  Use(Dc, CreateSolidBrush(RGB(180, 240, 180)));
  Rectangle(Dc, 280, 220, 380, 280);
  ModifyWorldTransform(Dc, X, MWT_IDENTITY);
  // окно со сдвигом начала в MM_TEXT
  SetWindowOrgEx(Dc, -20, -250, nil);
  Use(Dc, CreateSolidBrush(RGB(240, 200, 240)));
  Rectangle(Dc, 0, 0, 100, 50);
  CloseEmf(Dc);
end;

procedure MakeSamples(const Dir: string);
begin
  ForceDirectories(Dir);
  SampleShapes(Dir);
  SampleBrushes(Dir);
  SampleText(Dir);
  SampleImages(Dir);
  SampleMapping(Dir);
  Writeln('метафайлы -> ', Dir);
end;
