program ncinfo;
// A Pascal take on the classic `notcurses-info` screen: version and terminal
// identification, geometry, capability flags, styled text, glyph coverage
// strips for the various blitters, and a truecolor gradient band.
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  ncconsole,
  notcurses;

const
  // EGC stress test: plain emoji, VS16 (heart), skin-tone modifier, a
  // regional-indicator flag, and ZWJ sequences (family, rainbow flag).
  // Note: upstream notcurses hardwires wcwidth()=1 on Windows (ncport.h),
  // so double-width glyphs may overlap there - that is what this probes.
  EMOJIS: UTF8String = '🚀  🎨  ⚡  🐕  🍕  ❤️  👍🏽  🇫🇷  👨‍👩‍👧‍👦  🏳️‍🌈';

var
  nc: Pnotcurses;
  std: Pncplane;
  rows, cols: Cardinal;
  row: Integer;

procedure PutAt(y, x: Integer; const s: UTF8String);
begin
  ncplane_putstr_yx(std, y, x, PUTF8Char(s));
end;

// capability flag, notcurses-info style: name then a green + or red -
procedure PutFlag(const name: UTF8String; ok: Boolean);
begin
  ncplane_set_fg_rgb8(std, $9E, $B6, $C9);
  ncplane_putstr(std, PUTF8Char(name));
  if ok then
  begin
    ncplane_set_fg_rgb8(std, $39, $D3, $53);
    ncplane_putstr(std, '+ ');
  end
  else
  begin
    ncplane_set_fg_rgb8(std, $F0, $50, $50);
    ncplane_putstr(std, '- ');
  end;
end;

procedure PutStyled(const name: UTF8String; style: Cardinal);
begin
  ncplane_set_styles(std, style);
  ncplane_putstr(std, PUTF8Char(name));
  ncplane_set_styles(std, NCSTYLE_NONE);
  ncplane_putstr(std, '  ');
end;

// a labeled glyph strip, tinted
procedure Strip(const label_: UTF8String; const glyphs: UTF8String;
  r, g, b: Cardinal);
begin
  ncplane_set_fg_rgb8(std, $80, $8B, $96);
  PutAt(row, 2, label_);
  ncplane_set_fg_rgb8(std, r, g, b);
  ncplane_putstr_yx(std, row, 12, PUTF8Char(glyphs));
  Inc(row);
end;

// ncplane_gradient2x1 takes CHANNELS, not raw RGB: the not-default-color
// flag must be set, which ncchannel_set_rgb8 does for us.
function RgbChan(r, g, b: Cardinal): UInt32;
begin
  Result := 0;
  ncchannel_set_rgb8(@Result, r, g, b);
end;

function PixelImplName(impl: ncpixelimpl_e): UTF8String;
begin
  case impl of
    NCPIXEL_NONE:           Result := 'none';
    NCPIXEL_SIXEL:          Result := 'sixel';
    NCPIXEL_LINUXFB:        Result := 'linuxfb';
    NCPIXEL_ITERM2:         Result := 'iterm2';
    NCPIXEL_KITTY_STATIC:   Result := 'kitty';
    NCPIXEL_KITTY_ANIMATED: Result := 'kitty2';
    NCPIXEL_KITTY_SELFREF:  Result := 'kitty3';
  else
    Result := '?';
  end;
end;

var
  opts: notcurses_options;
  term: PUTF8Char;
  pxy, pxx, celly, cellx, maxby, maxbx: Cardinal;
  pimpl: ncpixelimpl_e;
  braille64: UTF8String;
begin
  FillChar(opts, SizeOf(opts), 0);
  opts.flags := NCOPTION_SUPPRESS_BANNERS;

  NcConsolePrepare;
  nc := notcurses_core_init(@opts, nil);
  if nc = nil then
  begin
    NcConsoleRestore;
    Writeln(ErrOutput, 'notcurses_core_init failed (not running in a terminal?)');
    Halt(1);
  end;
  try
    std := notcurses_stddim_yx(nc, @rows, @cols);
    ncplane_pixel_geom(std, @pxy, @pxx, @celly, @cellx, @maxby, @maxbx);
    pimpl := notcurses_check_pixel_support(nc);
    term := notcurses_detected_terminal(nc);

    NcConsoleHome;
    ncplane_erase(std);

    // -- banner ------------------------------------------------------------
    ncplane_set_fg_rgb8(std, $2E, $C8, $C8);
    PutAt(0, 0, UTF8String(Format('notcurses %s (notcurses-pas) on %s',
      [string(notcurses_version()),
       string(term)])));
    if celly > 0 then
      PutAt(1, 0, UTF8String(Format(
        '%d rows (%dpx) %d cols (%dpx) %dx%d %d colors',
        [rows, celly, cols, cellx, pxy, pxx, notcurses_palette_size(nc)])))
    else
      PutAt(1, 0, UTF8String(Format('%d rows %d cols %d colors',
        [rows, cols, notcurses_palette_size(nc)])));
    if notcurses_cantruecolor(nc) then
    begin
      ncplane_set_fg_rgb8(std, $FF, $60, $60); ncplane_putstr(std, '+R');
      ncplane_set_fg_rgb8(std, $60, $FF, $60); ncplane_putstr(std, 'G');
      ncplane_set_fg_rgb8(std, $60, $80, $FF); ncplane_putstr(std, 'B');
    end;

    // -- capability flags --------------------------------------------------
    ncplane_cursor_move_yx(std, 3, 0);
    PutFlag('rgb', notcurses_cantruecolor(nc));
    PutFlag('ccc', notcurses_canchangecolor(nc));
    PutFlag('utf8', notcurses_canutf8(nc));
    PutFlag('half', notcurses_canhalfblock(nc));
    PutFlag('quad', notcurses_canquadrant(nc));
    PutFlag('sex', notcurses_cansextant(nc));
    PutFlag('oct', notcurses_canoctant(nc));
    PutFlag('braille', notcurses_canbraille(nc));
    PutFlag('images', notcurses_canopen_images(nc));
    PutFlag('video', notcurses_canopen_videos(nc));
    ncplane_set_fg_rgb8(std, $9E, $B6, $C9);
    ncplane_putstr(std, PUTF8Char(UTF8String(
      'pixel:' + string(PixelImplName(pimpl)))));

    // -- style demo --------------------------------------------------------
    ncplane_set_fg_rgb8(std, $D8, $D8, $D8);
    ncplane_cursor_move_yx(std, 4, 0);
    PutStyled('bold', NCSTYLE_BOLD);
    PutStyled('ital', NCSTYLE_ITALIC);
    PutStyled('uline', NCSTYLE_UNDERLINE);
    PutStyled('ucurl', NCSTYLE_UNDERCURL);
    PutStyled('struck', NCSTYLE_STRUCK);

    // -- glyph coverage strips --------------------------------------------
    row := 6;
    Strip('halves', NCHALFBLOCKS, $FF, $B8, $50);
    Strip('quads', NCQUADBLOCKS, $FF, $88, $30);
    Strip('eighths', NCEIGHTHSB + '  ' + NCEIGHTHSL, $E8, $60, $60);
    if notcurses_cansextant(nc) then
      Strip('sextants', NCSEXBLOCKS, $C8, $60, $E8);
    // 64 of the 256 braille EGCs (each is 3 UTF-8 bytes, slicing is safe)
    braille64 := Copy(NCBRAILLEEGCS, 1, 64 * 3);
    Strip('braille', braille64, $50, $A8, $FF);
    Strip('boxes', NCBOXLIGHT + ' ' + NCBOXHEAVY + ' ' + NCBOXROUND + ' ' +
      NCBOXDOUBLE + ' ' + NCBOXASCII, $39, $D3, $92);
    Strip('symbols', NCSUITSBLACK + ' ' + NCCHESSWHITE + ' ' + NCDICE + ' ' +
      NCMUSICSYM + ' ' + NCDIGITSSUPERW + NCDIGITSSUBW, $E8, $C8, $50);
    Strip('emoji', EMOJIS, $FF, $FF, $FF);

    // -- truecolor gradient band (2x1 halfblock cells) ---------------------
    Inc(row);
    ncplane_gradient2x1(std, row, 2, 3, cols - 4,
      RgbChan($FF, $40, $40), RgbChan($40, $FF, $40),
      RgbChan($40, $40, $FF), RgbChan($FF, $40, $FF));
    Inc(row, 4);

    ncplane_set_fg_rgb8(std, $80, $8B, $96);
    ncplane_set_bg_default(std);
    PutAt(row, 2, 'press any key to quit');

    notcurses_render(nc);
    notcurses_get_blocking(nc, nil);
  finally
    NcConsoleQuiesce; // see ncconsole: makes the teardown safe on Windows
    notcurses_stop(nc);
    NcConsoleRestore;
  end;
end.
