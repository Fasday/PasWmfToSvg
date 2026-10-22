program MeasureFonts;

// Таблицы ядра PasWmfToSvg, измеренные в GDI Windows: метрики распространённых шрифтов (верх и низ ячейки, средняя
// ширина, ширина символов ASCII и кириллицы - в тысячных кегля, на кегле 2048 пикселей) и узоры штриховки HS_*
// (кисть рисуется на картинке 8x8). Пишет Source\PasWmfToSvg.FontTables.inc.
//
//   MeasureFonts <файл .inc>

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Classes;

const
  Faces: array[0..13] of string = ('Tahoma', 'Arial', 'Segoe UI', 'Times New Roman', 'Courier New', 'Verdana',
    'Microsoft Sans Serif', 'Calibri', 'Cambria', 'Consolas', 'Georgia', 'Trebuchet MS', 'Arial Narrow', 'Lucida Console');
  Em = 2048;

function Permille(V: Integer): Integer;
begin
  Result := Round(V * 1000 / Em);
end;

function IfThen(B: Boolean; const T, F: string): string;
begin
  if B then Result := T else Result := F;
end;

function Generic(PitchAndFamily: Byte): string;
begin
  if PitchAndFamily and TMPF_FIXED_PITCH = 0 then
    Exit('monospace');
  case PitchAndFamily and $F0 of
    FF_ROMAN: Result := 'serif';
    FF_MODERN: Result := 'monospace';
    FF_SCRIPT: Result := 'cursive';
    FF_DECORATIVE: Result := 'fantasy';
  else
    Result := 'sans-serif';
  end;
end;

procedure Font(Dc: HDC; const Face: string; Out: TStrings; var Count: Integer);
var
  Lf: TLogFontW;
  F: HFONT;
  Old: HGDIOBJ;
  Tm: TTextMetricW;
  Got: array[0..63] of Char;
  Sz: TSize;
  Line: string;
  Ch: Char;
begin
  Lf := Default(TLogFontW);
  Lf.lfHeight := -Em;
  Lf.lfWeight := FW_NORMAL;
  Lf.lfCharSet := DEFAULT_CHARSET;
  StrPLCopy(Lf.lfFaceName, Face, High(Lf.lfFaceName));
  F := CreateFontIndirectW(Lf);
  Old := SelectObject(Dc, F);
  try
    GetTextFaceW(Dc, Length(Got), Got);
    if not SameText(string(Got), Face) then
    begin
      Writeln('нет шрифта: ', Face);
      Exit;
    end;
    GetTextMetricsW(Dc, Tm);
    if Count > 0 then
      Out[Out.Count - 1] := Out[Out.Count - 1] + ',';
    Inc(Count);
    Out.Add(Format('    (Face: ''%s''; Generic: ''%s''; Ascent: %d; Descent: %d; Avg: %d;',
      [Face, Generic(Tm.tmPitchAndFamily), Permille(Tm.tmAscent), Permille(Tm.tmDescent), Permille(Tm.tmAveCharWidth)]));
    Line := '      Ascii: (';
    for var C := 32 to 126 do
    begin
      Ch := Char(C);
      GetTextExtentPoint32W(Dc, @Ch, 1, Sz);
      Line := Line + IntToStr(Permille(Sz.cx)) + IfThen(C < 126, ', ', ');');
      if Length(Line) > 110 then
      begin
        Out.Add(Line);
        Line := '        ';
      end;
    end;
    Out.Add(Line);
    // А..я (0410..044F), Ё (0401), ё (0451)
    Line := '      Cyr: (';
    for var I := 0 to 65 do
    begin
      if I < 64 then
        Ch := Char($410 + I)
      else if I = 64 then
        Ch := Char($401)
      else
        Ch := Char($451);
      GetTextExtentPoint32W(Dc, @Ch, 1, Sz);
      Line := Line + IntToStr(Permille(Sz.cx)) + IfThen(I < 65, ', ', '))');
      if Length(Line) > 110 then
      begin
        Out.Add(Line);
        Line := '        ';
      end;
    end;
    if Line.Trim <> '' then
      Out.Add(Line);
  finally
    SelectObject(Dc, Old);
    DeleteObject(F);
  end;
end;

procedure Hatches(Dc: HDC; Out: TStrings);
var
  Bi: TBitmapInfo;
  Bits: Pointer;
  Bmp: HBITMAP;
  Old: HGDIOBJ;
  Br: HBRUSH;
  R: TRect;
  Line: string;
  Row: Byte;
begin
  Bi := Default(TBitmapInfo);
  Bi.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
  Bi.bmiHeader.biWidth := 8;
  Bi.bmiHeader.biHeight := -8;
  Bi.bmiHeader.biPlanes := 1;
  Bi.bmiHeader.biBitCount := 32;
  Bmp := CreateDIBSection(Dc, Bi, DIB_RGB_COLORS, Bits, 0, 0);
  Old := SelectObject(Dc, Bmp);
  try
    Out.Add('  // узоры штриховки HS_HORIZONTAL..HS_DIAGCROSS: строка - байт, старший бит - левый пиксель; начало узора 0, 0');
    Out.Add('  MfHatchBits: array[0..5, 0..7] of Byte = (');
    for var H := 0 to 5 do
    begin
      FillChar(Bits^, 8 * 8 * 4, $FF);
      Br := CreateHatchBrush(H, 0);
      SetBkMode(Dc, TRANSPARENT);
      SetBrushOrgEx(Dc, 0, 0, nil);
      R := Rect(0, 0, 8, 8);
      FillRect(Dc, R, Br);
      DeleteObject(Br);
      GdiFlush;
      Line := '    (';
      for var Y := 0 to 7 do
      begin
        Row := 0;
        for var X := 0 to 7 do
          if PCardinal(NativeUInt(Bits) + NativeUInt((Y * 8 + X) * 4))^ and $FFFFFF = 0 then
            Row := Row or (1 shl (7 - X));
        Line := Line + Format('$%.2x', [Row]) + IfThen(Y < 7, ', ', ')');
      end;
      Out.Add(Line + IfThen(H < 5, ',', ');'));
    end;
  finally
    SelectObject(Dc, Old);
    DeleteObject(Bmp);
  end;
end;

var
  Out: TStringList;
  Dc: HDC;
  Count: Integer;
begin
  try
    if ParamCount < 1 then
      raise Exception.Create('MeasureFonts <файл .inc>');
    Out := TStringList.Create;
    Dc := CreateCompatibleDC(0);
    try
      Out.Add('// Создано Tools\MeasureFonts.dpr (измерено в GDI Windows), не править вручную.');
      Out.Add('// Шрифты: верх (Ascent) и низ (Descent) ячейки, средняя ширина (Avg), ширина символов ASCII 32..126 (Ascii) и');
      Out.Add('// кириллицы А..я, Ё, ё (Cyr) - в тысячных кегля.');
      Out.Add('');
      Out.Add('type');
      Out.Add('  TMfFontData = record');
      Out.Add('    Face, Generic: string;');
      Out.Add('    Ascent, Descent, Avg: Word;');
      Out.Add('    Ascii: array[32..126] of Word;');
      Out.Add('    Cyr: array[0..65] of Word;');
      Out.Add('  end;');
      Out.Add('');
      Out.Add('const');
      Out.Add('  MfFontData: array[0..%COUNT%] of TMfFontData = (');
      Count := 0;
      for var F in Faces do
        Font(Dc, F, Out, Count);
      Out[Out.Count - 1] := Out[Out.Count - 1] + ');';
      Out.Text := Out.Text.Replace('%COUNT%', IntToStr(Count - 1));
      Out.Add('');
      Hatches(Dc, Out);
      Out.WriteBOM := True;
      Out.SaveToFile(ParamStr(1), TEncoding.UTF8);
      Writeln(Format('шрифтов %d -> %s', [Count, ParamStr(1)]));
    finally
      DeleteDC(Dc);
      Out.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
