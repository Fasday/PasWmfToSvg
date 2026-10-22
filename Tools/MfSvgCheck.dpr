program MfSvgCheck;

// Сверка PasWmfToSvg с рисованием самой Windows (только Windows), первая половина: папка метафайлов (.emf, .wmf) ->
// в --out для каждого SVG преобразователя (<имя>.svg), картинка GDI (<имя>.gdi: 4 байта ширина, 4 - высота, BGRA
// сверху вниз; EMF - PlayEnhMetaFile рамки картинки в её пиксели, WMF - рамка размещаемого заголовка при 96 точках на
// дюйм) и manifest.json (размер, время, байты SVG, пропущенные записи, ошибки). Вторая половина - Tools/edge_compare.py:
// SVG рисует Edge, сравнение с картинкой GDI.
//
//   MfSvgCheck <папка> --out <папка> [--limit N] [--no-gdi] [--no-svg] [--wmf] [--builtin-metrics]
//   MfSvgCheck --make-samples <папка>
//
// --no-gdi/--no-svg - только разбор (время, размер, пропущенные записи, ошибки); --wmf - каждый EMF переводится
// в WMF (GetWinMetaFileBits, размещаемый заголовок; в нём Windows хранит и исходный EMF), --wmf-pure - то же без
// вложенного EMF (проверка разбора самих записей WMF), --save-wmf - сохранить эти WMF в --out; --builtin-metrics -
// встроенные метрики
// шрифтов вместо GDI; --make-samples - синтетические метафайлы всех поддержанных записей (рисует GDI).

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, System.Types, System.Math, System.JSON,
  System.Diagnostics, System.Generics.Collections,
  PasWmfToSvg.Gdi, PasWmfToSvg;

type
  // картинка GDI метафайла: размер, как у SVG преобразователя
  TGdiPicture = record
    W, H: Integer;
    Bits: TBytes;
  end;

function EmfFrame(const Emf: TBytes; out Fx, Fy, Fw, Fh: Single): Boolean;
var
  F: TRect;
  Dev, Mm: TPoint;
begin
  Move(Emf[24], F, 16);
  Move(Emf[72], Dev, 8);
  Move(Emf[80], Mm, 8);
  Fx := F.Left * Dev.X / Mm.X / 100;
  Fy := F.Top * Dev.Y / Mm.Y / 100;
  Fw := (F.Right - F.Left) * Dev.X / Mm.X / 100;
  Fh := (F.Bottom - F.Top) * Dev.Y / Mm.Y / 100;
  Result := (Fw >= 1) and (Fh >= 1);
end;

// WMF -> дескриптор EMF Windows: размещаемый заголовок - рамка (0,01 мм)
function WmfHandle(const Wmf: TBytes): HENHMETAFILE;
var
  Pict: TMetafilePict;
  Skip, Inch: Integer;
  Box: array[0..3] of SmallInt;
begin
  Pict := Default(TMetafilePict);
  Pict.mm := MM_ANISOTROPIC;
  Skip := 0;
  if PCardinal(@Wmf[0])^ = $9AC6CDD7 then
  begin
    Move(Wmf[6], Box, 8);
    Inch := PWord(@Wmf[14])^;
    if Inch = 0 then
      Inch := 1440;
    Pict.xExt := MulDiv(Abs(Box[2] - Box[0]), 2540, Inch);
    Pict.yExt := MulDiv(Abs(Box[3] - Box[1]), 2540, Inch);
    Skip := 22;
  end;
  Result := SetWinMetaFileBits(Length(Wmf) - Skip, @Wmf[Skip], 0, Pict);
end;

function RenderGdi(const Data: TBytes; W, H: Integer): TGdiPicture;
var
  Bi: TBitmapInfo;
  Bits: Pointer;
  Dc: HDC;
  Bmp: HBITMAP;
  Old: HGDIOBJ;
  Mf: HENHMETAFILE;
  R: TRect;
  Fx, Fy, Fw, Fh: Single;
begin
  Result.W := W;
  Result.H := H;
  Bi := Default(TBitmapInfo);
  Bi.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
  Bi.bmiHeader.biWidth := W;
  Bi.bmiHeader.biHeight := -H;
  Bi.bmiHeader.biPlanes := 1;
  Bi.bmiHeader.biBitCount := 32;
  Dc := CreateCompatibleDC(0);
  Bmp := CreateDIBSection(Dc, Bi, DIB_RGB_COLORS, Bits, 0, 0);
  Old := SelectObject(Dc, Bmp);
  if IsEmf(Data) then
  begin
    // рамка картинки -> прямоугольник в пикселях устройства от её левого верхнего угла
    Mf := SetEnhMetaFileBits(Length(Data), @Data[0]);
    EmfFrame(Data, Fx, Fy, Fw, Fh);
    R := Rect(0, 0, Round(Fx + Fw) - Round(Fx), Round(Fy + Fh) - Round(Fy));
  end
  else
  begin
    Mf := WmfHandle(Data);
    R := Rect(0, 0, W, H);
  end;
  try
    FillChar(Bits^, W * H * 4, $FF);
    PlayEnhMetaFile(Dc, Mf, R);
    GdiFlush;
    SetLength(Result.Bits, W * H * 4);
    Move(Bits^, Result.Bits[0], W * H * 4);
  finally
    DeleteEnhMetaFile(Mf);
    SelectObject(Dc, Old);
    DeleteObject(Bmp);
    DeleteDC(Dc);
  end;
end;

// WMF с размещаемым заголовком (1440 единиц на дюйм) из EMF - как сохраняют WMF программы Windows
function EmfToWmf(const Emf: TBytes): TBytes;
var
  Mf: HENHMETAFILE;
  Dc: HDC;
  Size: Cardinal;
  Bits: TBytes;
  Hdr: array[0..10] of Word;
  B: TRect;
  Sum: Word;
begin
  Mf := SetEnhMetaFileBits(Length(Emf), @Emf[0]);
  Dc := GetDC(0);
  try
    Size := GetWinMetaFileBits(Mf, 0, nil, MM_ANISOTROPIC, Dc);
    SetLength(Bits, Size);
    GetWinMetaFileBits(Mf, Size, @Bits[0], MM_ANISOTROPIC, Dc);
  finally
    ReleaseDC(0, Dc);
    DeleteEnhMetaFile(Mf);
  end;
  Move(Emf[24], B, 16);
  FillChar(Hdr, SizeOf(Hdr), 0);
  Hdr[0] := $CDD7;
  Hdr[1] := $9AC6;
  Hdr[5] := Word(SmallInt(MulDiv(B.Right - B.Left, 1440, 2540)));
  Hdr[6] := Word(SmallInt(MulDiv(B.Bottom - B.Top, 1440, 2540)));
  Hdr[7] := 1440;
  Sum := 0;
  for var I := 0 to 9 do
    Sum := Sum xor Hdr[I];
  Hdr[10] := Sum;
  SetLength(Result, 22 + Length(Bits));
  Move(Hdr, Result[0], 22);
  Move(Bits[0], Result[22], Length(Bits));
end;

// WMF без записей META_ESCAPE: без вложенного EMF Windows рисует сами записи WMF (проверка их разбора)
function StripEscapes(const Wmf: TBytes): TBytes;
var
  Hdr, Pos, Size, Out: Integer;
begin
  Hdr := IfThen(PCardinal(@Wmf[0])^ = $9AC6CDD7, 22, 0);
  Pos := Hdr + PWord(@Wmf[Hdr + 2])^ * 2;
  SetLength(Result, Length(Wmf));
  Move(Wmf[0], Result[0], Pos);
  Out := Pos;
  while Pos + 6 <= Length(Wmf) do
  begin
    Size := Integer(PCardinal(@Wmf[Pos])^) * 2;
    if (Size < 6) or (Pos + Size > Length(Wmf)) then
      Break;
    if PWord(@Wmf[Pos + 4])^ <> $0626 then
    begin
      Move(Wmf[Pos], Result[Out], Size);
      Inc(Out, Size);
    end;
    Inc(Pos, Size);
  end;
  SetLength(Result, Out);
  PCardinal(@Result[Hdr + 6])^ := (Out - Hdr) div 2;
end;

{$I MfSvgCheck.Samples.inc}

var
  Dir, OutDir, Name, Svg: string;
  Limit, I, N, Errors: Integer;
  Files: TList<string>;
  Data: TBytes;
  Info: TMfInfo;
  Metrics: IMfFontMetrics;
  Sw: TStopwatch;
  Manifest: TJSONArray;
  Item: TJSONObject;
  NoGdi, NoSvg, Wmf, SaveWmf, WmfPure: Boolean;
  Pic: TGdiPicture;
begin
  SaveWmf := False;
  WmfPure := False;
  try
    if (ParamCount >= 2) and SameText(ParamStr(1), '--make-samples') then
    begin
      MakeSamples(ParamStr(2));
      Exit;
    end;
    if ParamCount < 1 then
      raise Exception.Create('MfSvgCheck <папка> --out <папка> [--limit N] [--no-gdi] [--no-svg] [--wmf] ' +
        '[--builtin-metrics] | --make-samples <папка>');
    Dir := ParamStr(1);
    OutDir := TPath.Combine(Dir, '_check');
    Limit := MaxInt;
    NoGdi := False;
    NoSvg := False;
    Wmf := False;
    Metrics := GdiFontMetrics;
    I := 2;
    while I <= ParamCount do
    begin
      if SameText(ParamStr(I), '--out') then begin Inc(I); OutDir := ParamStr(I); end
      else if SameText(ParamStr(I), '--limit') then begin Inc(I); Limit := StrToInt(ParamStr(I)); end
      else if SameText(ParamStr(I), '--no-gdi') then NoGdi := True
      else if SameText(ParamStr(I), '--no-svg') then NoSvg := True
      else if SameText(ParamStr(I), '--wmf') then Wmf := True
      else if SameText(ParamStr(I), '--save-wmf') then SaveWmf := True
      else if SameText(ParamStr(I), '--wmf-pure') then begin Wmf := True; WmfPure := True; end
      else if SameText(ParamStr(I), '--builtin-metrics') then Metrics := BuiltinFontMetrics;
      Inc(I);
    end;
    ForceDirectories(OutDir);
    Files := TList<string>.Create;
    Files.AddRange(TDirectory.GetFiles(Dir, '*.emf'));
    Files.AddRange(TDirectory.GetFiles(Dir, '*.wmf'));
    Files.Sort;
    Manifest := TJSONArray.Create;
    try
      N := 0;
      Errors := 0;
      for var F in Files do
      begin
        if N >= Limit then
          Break;
        Inc(N);
        Name := TPath.GetFileNameWithoutExtension(F);
        Item := TJSONObject.Create;
        Manifest.AddElement(Item);
        Item.AddPair('name', Name);
        try
          Data := TFile.ReadAllBytes(F);
          if Wmf and IsEmf(Data) then
          begin
            Data := EmfToWmf(Data);
            if WmfPure then
              Data := StripEscapes(Data);
            if SaveWmf then
            begin
              TFile.WriteAllBytes(TPath.Combine(OutDir, Name + '.wmf'), Data);
              // и EMF, в который этот WMF переводит сама Windows (так его рисует GDI)
              var H := WmfHandle(Data);
              var Sz := GetEnhMetaFileBits(H, 0, nil);
              var Back: TBytes;
              SetLength(Back, Sz);
              GetEnhMetaFileBits(H, Sz, @Back[0]);
              DeleteEnhMetaFile(H);
              TFile.WriteAllBytes(TPath.Combine(OutDir, Name + '.wmf.emf'), Back);
            end;
          end;
          Sw := TStopwatch.StartNew;
          Svg := MetafileToSvg(Data, Info, Metrics);
          Item.AddPair('ms', TJSONNumber.Create(RoundTo(Sw.Elapsed.TotalMilliseconds, -3)));
          Item.AddPair('format', Info.Format);
          Item.AddPair('w', TJSONNumber.Create(Info.Width));
          Item.AddPair('h', TJSONNumber.Create(Info.Height));
          Item.AddPair('records', TJSONNumber.Create(Info.Records));
          if Info.SkippedTypes <> '' then
            Item.AddPair('skipped', Info.SkippedTypes);
          Item.AddPair('bytes', TJSONNumber.Create(TEncoding.UTF8.GetByteCount(Svg)));
          if not NoSvg then
            TFile.WriteAllBytes(TPath.Combine(OutDir, Name + '.svg'), TEncoding.UTF8.GetBytes(Svg));
          if not NoGdi then
          begin
            Pic := RenderGdi(Data, Info.Width, Info.Height);
            var Raw: TBytes;
            SetLength(Raw, 8 + Length(Pic.Bits));
            Move(Pic.W, Raw[0], 4);
            Move(Pic.H, Raw[4], 4);
            Move(Pic.Bits[0], Raw[8], Length(Pic.Bits));
            TFile.WriteAllBytes(TPath.Combine(OutDir, Name + '.gdi'), Raw);
          end;
        except
          on E: Exception do
          begin
            Item.AddPair('error', E.ClassName + ': ' + E.Message);
            Inc(Errors);
          end;
        end;
        if N mod 500 = 0 then
          Writeln(Format('  %d', [N]));
      end;
      TFile.WriteAllText(TPath.Combine(OutDir, 'manifest.json'), Manifest.ToJSON, TEncoding.UTF8);
      Writeln(Format('метафайлов %d, ошибок %d -> %s', [N, Errors, OutDir]));
    finally
      Manifest.Free;
      Files.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
