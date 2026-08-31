program ncimage;
// Displays an image (or the first frame of a video) in the terminal via
// ncvisual - with pixel graphics (sixel/kitty) when the terminal supports
// them, degrading to character blitters otherwise.
//
// This uses notcurses_init from libnotcurses (NOT notcurses_core_init):
// that is the entry point that enables the FFmpeg multimedia backend, so
// the FFmpeg DLLs must be present at runtime on Windows.
//
// Usage: ncimage [file]   (defaults to sample.png next to the executable)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  ncconsole,
  notcurses;

var
  opts: notcurses_options;
  vopts: ncvisual_options;
  nc: Pnotcurses;
  std, imgplane: Pncplane;
  ncv: Pncvisual;
  rows, cols: Cardinal;
  path: string;
  u8path, msg: UTF8String;
  blitname: UTF8String;
begin
  path := ParamStr(1);
  if path = '' then
    path := ExtractFilePath(ParamStr(0)) + 'sample.png';
  if not FileExists(path) then
  begin
    Writeln(ErrOutput, 'file not found: ', path);
    Halt(1);
  end;
  u8path := UTF8String(path);

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

    ncv := ncvisual_from_file(PUTF8Char(u8path));
    if ncv = nil then
    begin
      ncplane_putstr_yx(std, 0, 0,
        'ncvisual_from_file failed (is the multimedia backend loaded?)');
      notcurses_render(nc);
      notcurses_get_blocking(nc, nil);
      Halt(2);
    end;

    FillChar(vopts, SizeOf(vopts), 0);
    vopts.n := std;
    vopts.y := 1;
    vopts.x := 0;
    // Pixel graphics when available; otherwise the aspect-true character
    // blitter (SCALE_HIRES character blitters have non-square subcells and
    // distort the image geometry).
    if notcurses_check_pixel_support(nc) <> NCPIXEL_NONE then
    begin
      vopts.blitter := NCBLIT_PIXEL;
      vopts.scaling := NCSCALE_SCALE_HIRES;
    end
    else
    begin
      vopts.blitter := ncvisual_media_defblitter(nc, NCSCALE_SCALE);
      vopts.scaling := NCSCALE_SCALE;
    end;
    vopts.flags := NCVISUAL_OPTION_CHILDPLANE or NCVISUAL_OPTION_NODEGRADE;

    imgplane := ncvisual_blit(nc, ncv, @vopts);
    if imgplane = nil then
    begin
      // NODEGRADE refused the blitter: retry letting notcurses degrade.
      vopts.flags := NCVISUAL_OPTION_CHILDPLANE;
      imgplane := ncvisual_blit(nc, ncv, @vopts);
    end;

    if imgplane = nil then
      ncplane_putstr_yx(std, 0, 0, 'ncvisual_blit failed')
    else
    begin
      case vopts.blitter of
        NCBLIT_PIXEL:   blitname := 'pixel';
        NCBLIT_3x2:     blitname := 'sextants';
        NCBLIT_2x2:     blitname := 'quadrants';
        NCBLIT_2x1:     blitname := 'halves';
        NCBLIT_BRAILLE: blitname := 'braille';
      else
        blitname := 'default';
      end;
      ncplane_set_fg_rgb8(std, $2E, $C8, $C8);
      msg := UTF8String(ExtractFileName(path)) + '  (blitter: ' + blitname +
        ')  -  press any key';
      ncplane_putstr_yx(std, 0, 0, PUTF8Char(msg));
    end;

    notcurses_render(nc);
    notcurses_get_blocking(nc, nil);
    {$IFNDEF MSWINDOWS}
    // On Windows ncvisual_destroy corrupts the C heap with the FFmpeg
    // backend loaded (isolated empirically: destroy crashes, stop does
    // not). For a one-shot viewer, let process exit reclaim everything; a
    // long-lived Windows program should reuse its ncvisuals instead of
    // destroy/reload cycles until this is fixed upstream.
    ncvisual_destroy(ncv);
    {$ENDIF}
  finally
    {$IFDEF MSWINDOWS}
    // With the media backend loaded, the notcurses teardown can corrupt
    // the heap on Windows: restore the terminal by hand and let process
    // exit reclaim everything (see ncconsole).
    NcConsoleLeaveScreen;
    NcConsoleRestore;
    {$ELSE}
    notcurses_stop(nc);
    {$ENDIF}
  end;
end.
