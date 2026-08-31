program ncvideo;
// A minimal terminal video player: decode/blit/render loop over an ncvisual,
// using pixel graphics (sixel/kitty) when the terminal supports them. Any
// key stops playback.
//
// IMPORTANT (upstream notcurses bug, all platforms, violent on Windows):
// decoding frames that are not already RGBA goes through force_rgba() in
// notcurses' ffmpeg backend, which memcpy()s an AVFrame by compile-time
// size and duplicates its internal AVBufferRefs - corrupting the C heap
// (STATUS_HEAP_CORRUPTION). Feed it videos whose decoder outputs RGBA
// directly and the buggy path is never taken.
//
// On Windows, when ffprobe/ffmpeg are available (PATH or next to the exe),
// any non-RGBA input (a regular mp4, say) is therefore transparently
// pre-converted to a temporary RGBA .mov before playing:
//
//   ffmpeg -i input.mp4 -an -vf format=rgba -c:v png temp.mov
//
// Usage: ncvideo [file [ms_per_frame [pixel]]]
//   default file sample_rgba.mov, 66ms/frame.
//
//   Default rendering: the highest-detail character blitter (quadrants on
//   Windows Terminal), stretched into a plane whose cell dimensions are
//   computed from the video's aspect ratio and the terminal's physical
//   cell geometry - maximum character-mode resolution AND correct
//   proportions. Only changed cells are retransmitted, so it stays fluid.
//   Pass "pixel" as third argument for pixel graphics (sixel/kitty):
//   full resolution, but every frame retransmits the whole bitmap, which
//   most terminals cannot parse at video rate.
//
// Late frames are dropped to hold the requested pace. Character-mode
// resolution is bounded by the terminal grid: a bigger window / smaller
// font shows more detail; the source video's resolution barely matters.
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF MSWINDOWS}{$IFDEF FPC}Windows,{$ELSE}Winapi.Windows,{$ENDIF}{$ENDIF}
  {$IFDEF FPC}SysUtils, Classes{$ELSE}System.SysUtils, System.Classes{$ENDIF},
  ncconsole,
  notcurses;

function TickMs: UInt64;
begin
  {$IFDEF FPC}
  Result := GetTickCount64;
  {$ELSE}
  Result := TThread.GetTickCount64;
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}
// run a command line via cmd.exe (so PATH lookup applies), hidden, and wait;
// True when it exits 0
function RunTool(const cmdline: string): Boolean;
var
  si: TStartupInfo;
  pi: TProcessInformation;
  cmd: string;
  ec: DWORD;
begin
  Result := False;
  cmd := 'cmd.exe /c ' + cmdline;
  UniqueString(cmd);
  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  if not CreateProcess(nil, PChar(cmd), nil, nil, False, CREATE_NO_WINDOW,
    nil, nil, si, pi) then
    Exit;
  WaitForSingleObject(pi.hProcess, INFINITE);
  GetExitCodeProcess(pi.hProcess, ec);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  Result := ec = 0;
end;

// pixel format and dimensions of the first video stream; pixfmt is ''
// when ffprobe is unavailable
procedure ProbeVideo(const path: string; out pixfmt: string; out w, h: Integer);
var
  tmp: string;
  sl, parts: TStringList;
begin
  pixfmt := '';
  w := 0;
  h := 0;
  tmp := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) +
    'ncvideo_probe.txt';
  if not RunTool('ffprobe -v error -select_streams v:0 -show_entries ' +
    'stream=pix_fmt,width,height -of csv=p=0 "' + path + '" > "' + tmp + '"') then
    Exit;
  sl := TStringList.Create;
  parts := TStringList.Create;
  try
    sl.LoadFromFile(tmp);
    if sl.Count > 0 then
    begin
      // ffprobe emits fields in ITS order (width,height,pix_fmt),
      // regardless of the order they were requested in
      parts.CommaText := Trim(sl[0]);
      if parts.Count >= 3 then
      begin
        w := StrToIntDef(parts[0], 0);
        h := StrToIntDef(parts[1], 0);
        pixfmt := parts[2];
      end;
    end;
  finally
    parts.Free;
    sl.Free;
  end;
end;

// screen recordings often carry baked-in black borders; find them so the
// conversion can crop them away. Returns 'crop=W:H:X:Y,' or ''.
function DetectCrop(const path: string): string;
var
  tmp, line, tok: string;
  sl: TStringList;
  i, p: Integer;
begin
  Result := '';
  tmp := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) +
    'ncvideo_crop.txt';
  // cropdetect reports on stderr at info level; skip 1s in case of fade-in
  if not RunTool('ffmpeg -v info -ss 1 -i "' + path + '" -an ' +
    '-vf cropdetect=limit=24:round=2 -frames:v 60 -f null NUL 2> "' +
    tmp + '"') then
    Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(tmp);
    line := '';
    for i := sl.Count - 1 downto 0 do
      if Pos(' crop=', sl[i]) > 0 then
      begin
        line := sl[i];
        Break;
      end;
    p := Pos(' crop=', line);
    if p = 0 then
      Exit;
    tok := Trim(Copy(line, p + 1, MaxInt));
    // expect crop=W:H:X:Y with positive dimensions
    if (Pos('crop=', tok) = 1) and (Pos(':', tok) > 0) and
       (Pos('crop=0:', tok) = 0) and (Pos('crop=-', tok) = 0) then
      Result := tok + ',';
  finally
    sl.Free;
  end;
end;

// see the header comment: non-RGBA sources trip a heap-corrupting notcurses
// bug, so transparently re-encode them to a temporary RGBA .mov. Sources
// with baked-in black borders get re-encoded too (rgba or not), so the
// borders can be cropped away.
procedure EnsureRgbaSource(var path: string);
var
  pf, outp, cropf, s: string;
  w, h, cw, ch, p: Integer;
begin
  ProbeVideo(path, pf, w, h);
  if pf = '' then
    Exit; // no ffprobe to tell - play as-is
  cropf := DetectCrop(path);
  // does the detected crop actually remove anything?
  if cropf <> '' then
  begin
    s := Copy(cropf, Length('crop=') + 1, MaxInt); // W:H:X:Y,
    p := Pos(':', s);
    cw := StrToIntDef(Copy(s, 1, p - 1), 0);
    Delete(s, 1, p);
    p := Pos(':', s);
    ch := StrToIntDef(Copy(s, 1, p - 1), 0);
    if (cw <= 0) or (ch <= 0) or ((cw >= w) and (ch >= h)) then
      cropf := ''; // nothing to crop (or parse trouble)
  end;
  if (pf = 'rgba') and (cropf = '') then
    Exit; // already safe and borderless
  outp := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) +
    'ncvideo_rgba.mov';
  if SameText(path, outp) then
    outp := ChangeFileExt(outp, '2.mov'); // re-encoding our own temp file
  Writeln('input is ', pf, ': pre-converting to RGBA (workaround for a ',
    'notcurses ffmpeg-backend bug), please wait...');
  if cropf <> '' then
    Writeln('cropping baked-in borders: ', cropf);
  // cap the intermediate resolution: terminal output is a few hundred
  // effective pixels wide at most, and png intra frames get huge
  if RunTool('ffmpeg -v error -y -i "' + path + '" -an ' +
    '-vf "' + cropf + 'scale=min(960\,iw):-2:flags=lanczos,format=rgba" ' +
    '-c:v png "' + outp + '"') then
    path := outp
  else
    Writeln('ffmpeg conversion failed; playing as-is (may crash)');
end;
{$ENDIF}

var
  opts: notcurses_options;
  popts: ncplane_options;
  vopts: ncvisual_options;
  nc: Pnotcurses;
  std, screen: Pncplane;
  ncv: Pncvisual;
  rows, cols: Cardinal;
  path: string;
  u8: UTF8String;
  framems, r, skips: Integer;
  deadline, now: UInt64;
  playing: Boolean;
  zero: timespec;
  vg: ncvgeom;
  cellpy, cellpx: Cardinal;
  availr, availc: Cardinal;
  tgtr, tgtc: Integer;
begin
  path := ParamStr(1);
  if path = '' then
    path := ExtractFilePath(ParamStr(0)) + 'sample_rgba.mov';
  framems := StrToIntDef(ParamStr(2), 66);
  if not FileExists(path) then
  begin
    Writeln(ErrOutput, 'file not found: ', path);
    Halt(1);
  end;
  {$IFDEF MSWINDOWS}
  EnsureRgbaSource(path);
  {$ENDIF}

  FillChar(opts, SizeOf(opts), 0);
  opts.flags := NCOPTION_SUPPRESS_BANNERS;

  NcConsolePrepare;
  nc := notcurses_init(@opts, nil);   // multimedia-enabled init
  if nc = nil then
  begin
    NcConsoleRestore;
    Writeln(ErrOutput, 'notcurses_init failed (not running in a terminal?)');
    Halt(1);
  end;
  try
    std := notcurses_stddim_yx(nc, @rows, @cols);
    NcConsoleHome;
    ncplane_erase(std);
    ncplane_set_fg_rgb8(std, $2E, $C8, $C8);
    u8 := UTF8String(ExtractFileName(path)) + '  -  any key stops';
    ncplane_putstr_yx(std, 0, 0, PUTF8Char(u8));

    u8 := UTF8String(path);
    ncv := ncvisual_from_file(PUTF8Char(u8));
    if ncv = nil then
    begin
      ncplane_putstr_yx(std, 2, 0, 'ncvisual_from_file failed');
      notcurses_render(nc);
      notcurses_get_blocking(nc, nil);
      Halt(2);
    end;

    // target plane: sized so that (cells x physical cell pixels) matches
    // the video's aspect ratio, then STRETCH the frames into it with the
    // sharpest character blitter - max detail with correct proportions
    ncplane_pixel_geom(std, nil, nil, @cellpy, @cellpx, nil, nil);
    if (cellpy = 0) or (cellpx = 0) then
    begin
      cellpy := 2; // no pixel info: assume the typical 1:2 cell
      cellpx := 1;
    end;
    FillChar(vg, SizeOf(vg), 0);
    ncvisual_geom(nc, ncv, nil, @vg);

    availr := rows - 1;
    availc := cols;
    tgtc := availc;
    tgtr := 0;
    if (vg.pixy > 0) and (vg.pixx > 0) then
      tgtr := Round(tgtc * cellpx * vg.pixy / (vg.pixx * cellpy));
    if (tgtr = 0) or (tgtr > Integer(availr)) then
    begin
      tgtr := availr;
      if (vg.pixy > 0) and (vg.pixx > 0) then
        tgtc := Round(tgtr * cellpy * vg.pixx / (vg.pixy * cellpx));
      if (tgtc = 0) or (tgtc > Integer(availc)) then
        tgtc := availc;
    end;

    FillChar(popts, SizeOf(popts), 0);
    popts.y := 1 + (Integer(availr) - tgtr) div 2;
    popts.x := (Integer(availc) - tgtc) div 2;
    popts.rows := tgtr;
    popts.cols := tgtc;
    screen := ncplane_create(std, @popts);

    FillChar(vopts, SizeOf(vopts), 0);
    vopts.n := screen;
    if SameText(ParamStr(3), 'pixel') and
       (notcurses_check_pixel_support(nc) <> NCPIXEL_NONE) then
    begin
      vopts.blitter := NCBLIT_PIXEL;
      vopts.scaling := NCSCALE_SCALE_HIRES; // pixel cells are square anyway
    end
    else
    begin
      vopts.blitter := ncvisual_media_defblitter(nc, NCSCALE_SCALE_HIRES);
      vopts.scaling := NCSCALE_STRETCH; // the plane already has the aspect
    end;

    zero.tv_sec := 0;
    zero.tv_nsec := 0;
    playing := True;
    deadline := TickMs;
    while playing do
    begin
      if ncvisual_blit(nc, ncv, @vopts) = nil then
        Break;
      notcurses_render(nc);
      Inc(deadline, UInt64(framems));
      now := TickMs;
      if now < deadline then
        Sleep(Integer(deadline - now));
      if notcurses_get(nc, @zero, nil) <> 0 then
        Break; // any key (or input error): stop
      r := ncvisual_decode(ncv);
      if r <> 0 then
        Break; // 1 = end of stream, <0 = error
      // running late? drop frames (bounded) to hold the pace
      skips := 0;
      while (TickMs >= deadline + UInt64(framems)) and (skips < 8) do
      begin
        r := ncvisual_decode(ncv);
        if r <> 0 then
        begin
          playing := False;
          Break;
        end;
        Inc(deadline, UInt64(framems));
        Inc(skips);
      end;
    end;

    {$IFNDEF MSWINDOWS}
    ncvisual_destroy(ncv); // corrupts the heap on Windows - see ncimage.dpr
    {$ENDIF}
  finally
    {$IFDEF MSWINDOWS}
    // With the media backend loaded, the notcurses teardown reliably
    // corrupts the heap on Windows: restore the terminal by hand and let
    // process exit reclaim everything (see ncconsole).
    NcConsoleLeaveScreen;
    NcConsoleRestore;
    {$ELSE}
    notcurses_stop(nc);
    {$ENDIF}
  end;
end.
