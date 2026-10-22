program MfToSvg;

// Метафайл (EMF или WMF) -> SVG из командной строки (Windows, Linux, macOS).
//
//   MfToSvg <метафайл> [<файл.svg>] [--builtin-metrics]
//
// Без <файл.svg> - рядом с метафайлом. В Windows метрики шрифтов - от GDI (PasWmfToSvg.Gdi), --builtin-metrics -
// встроенные таблицы, как на других платформах.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.StrUtils, System.IOUtils,
  {$IFDEF MSWINDOWS}PasWmfToSvg.Gdi,{$ENDIF}
  PasWmfToSvg;

var
  Src, Dst: string;
  Info: TMfInfo;
  Metrics: IMfFontMetrics;
  Svg: string;
begin
  try
    Src := '';
    Dst := '';
    Metrics := nil;
    for var I := 1 to ParamCount do
      if SameText(ParamStr(I), '--builtin-metrics') then
        Metrics := BuiltinFontMetrics
      else if Src = '' then
        Src := ParamStr(I)
      else
        Dst := ParamStr(I);
    if Src = '' then
      raise Exception.Create('MfToSvg <метафайл> [<файл.svg>] [--builtin-metrics]');
    if Dst = '' then
      Dst := TPath.ChangeExtension(Src, '.svg');
    Svg := MetafileToSvg(TFile.ReadAllBytes(Src), Info, Metrics);
    TFile.WriteAllBytes(Dst, TEncoding.UTF8.GetBytes(Svg));
    Writeln(Format('%s %dx%d, записей %d, пропущено %d%s -> %s', [Info.Format, Info.Width, Info.Height, Info.Records,
      Info.Skipped, IfThen(Info.SkippedTypes <> '', ' (' + Info.SkippedTypes + ')', ''), Dst]));
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
