unit PasWmfToSvg.Gdi;

// Метрики шрифтов PasWmfToSvg от GDI самой Windows (только Windows): базовая линия и ширина текста - точно как при
// рисовании метафайла. Достаточно подключить модуль - он становится поставщиком по умолчанию (MfDefaultFontMetrics);
// или передать GdiFontMetrics в MetafileToSvg явно. Потокобезопасен (контекст устройства - на каждый вызов).

interface

uses
  PasWmfToSvg;

function GdiFontMetrics: IMfFontMetrics;

implementation

{$IFDEF MSWINDOWS}

uses
  Winapi.Windows, System.SysUtils;

type
  TGdiMetrics = class(TInterfacedObject, IMfFontMetrics)
  private
    class function MakeFont(const Font: TMfFont): HFONT; static;
  public
    function Metrics(const Font: TMfFont; out Ascent, Descent, Em: Single): Boolean;
    function TextWidth(const Font: TMfFont; const S: string): Single;
  end;

class function TGdiMetrics.MakeFont(const Font: TMfFont): HFONT;
var
  Lf: TLogFontW;
begin
  Lf := Default(TLogFontW);
  Lf.lfHeight := Font.Height;
  Lf.lfWidth := Font.Width;
  Lf.lfWeight := Font.Weight;
  Lf.lfItalic := Ord(Font.Italic);
  Lf.lfUnderline := Ord(Font.Underline);
  Lf.lfStrikeOut := Ord(Font.StrikeOut);
  Lf.lfCharSet := Font.CharSet;
  Lf.lfPitchAndFamily := Font.PitchAndFamily;
  StrPLCopy(Lf.lfFaceName, Font.Face, High(Lf.lfFaceName));
  Result := CreateFontIndirectW(Lf);
end;

function TGdiMetrics.Metrics(const Font: TMfFont; out Ascent, Descent, Em: Single): Boolean;
var
  Dc: HDC;
  F: HFONT;
  Old: HGDIOBJ;
  Tm: TTextMetricW;
begin
  Result := False;
  Dc := CreateCompatibleDC(0);
  if Dc = 0 then
    Exit;
  F := MakeFont(Font);
  try
    Old := SelectObject(Dc, F);
    try
      Result := GetTextMetricsW(Dc, Tm);
      if Result then
      begin
        Ascent := Tm.tmAscent;
        Descent := Tm.tmDescent;
        Em := Tm.tmHeight - Tm.tmInternalLeading;
      end;
    finally
      SelectObject(Dc, Old);
    end;
  finally
    DeleteObject(F);
    DeleteDC(Dc);
  end;
end;

function TGdiMetrics.TextWidth(const Font: TMfFont; const S: string): Single;
var
  Dc: HDC;
  F: HFONT;
  Old: HGDIOBJ;
  Sz: TSize;
begin
  Result := BuiltinFontMetrics.TextWidth(Font, S);
  Dc := CreateCompatibleDC(0);
  if Dc = 0 then
    Exit;
  F := MakeFont(Font);
  try
    Old := SelectObject(Dc, F);
    try
      if GetTextExtentPoint32W(Dc, PChar(S), Length(S), Sz) then
        Result := Sz.cx;
    finally
      SelectObject(Dc, Old);
    end;
  finally
    DeleteObject(F);
    DeleteDC(Dc);
  end;
end;

var
  Gdi: IMfFontMetrics;

function GdiFontMetrics: IMfFontMetrics;
begin
  Result := Gdi;
end;

initialization
  Gdi := TGdiMetrics.Create;
  MfDefaultFontMetrics := Gdi;

{$ELSE}

// не Windows: GDI нет - встроенные метрики
function GdiFontMetrics: IMfFontMetrics;
begin
  Result := BuiltinFontMetrics;
end;

{$ENDIF}

end.
