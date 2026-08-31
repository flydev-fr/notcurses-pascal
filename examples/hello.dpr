program hello;
// Full-screen (rendered mode) example: draws a rounded perimeter and some
// colored text on the standard plane, adapts to terminal resizes, and quits
// on any key press.
//
// Resize handling comes in two flavors:
//   - on POSIX, SIGWINCH surfaces as an NCKEY_RESIZE input event;
//   - on Windows there is no push event: notcurses re-reads the console
//     geometry whenever it renders, so we poll notcurses_get with an
//     already-expired deadline (non-blocking) and refresh periodically.
// The loop below handles both.
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  ncconsole,
  notcurses;

var
  opts: notcurses_options;
  nc: Pnotcurses;
  std: Pncplane;
  rows, cols: Cardinal;

procedure Redraw;
var
  chans: UInt64;
  msg: UTF8String;
begin
  // Windows: notcurses paints full frames assuming the cursor is at home,
  // but its "clear" escape never puts it there - see ncconsole.
  NcConsoleHome;
  ncplane_erase(std);

  chans := 0;
  ncchannels_set_fg_rgb8(@chans, $52, $C8, $FF);
  ncplane_home(std);
  ncplane_perimeter_rounded(std, NCSTYLE_NONE, chans, 0);

  ncplane_set_fg_rgb8(std, $FF, $D7, $00);
  ncplane_putstr_yx(std, 2, 4, 'notcurses-pas: Notcurses from Pascal');

  ncplane_set_fg_rgb8(std, $C0, $C0, $C0);
  msg := UTF8String(Format('terminal geometry: %d rows x %d cols (resize me!)',
    [rows, cols]));
  ncplane_putstr_yx(std, 4, 4, PUTF8Char(msg));
  if rows > 5 then
    ncplane_putstr_yx(std, Integer(rows) - 3, 4, 'press any key to quit');

  notcurses_render(nc);
end;

var
  key: UInt32;
  ni: ncinput;
  zero: timespec;
  newr, newc: Cardinal;
begin
  FillChar(opts, SizeOf(opts), 0);
  opts.flags := NCOPTION_SUPPRESS_BANNERS;

  // Required on Windows consoles - see the ncconsole unit.
  NcConsolePrepare;

  // notcurses_core_init comes from libnotcurses-core and does not pull in
  // the multimedia stack; use notcurses_init (libnotcurses) if you need
  // ncvisual media decoding.
  nc := notcurses_core_init(@opts, nil);
  if nc = nil then
  begin
    NcConsoleRestore;
    Writeln(ErrOutput, 'notcurses_core_init failed (not running in a terminal?)');
    Halt(1);
  end;
  try
    std := notcurses_stddim_yx(nc, @rows, @cols);
    Redraw;

    zero.tv_sec := 0;
    zero.tv_nsec := 0;
    repeat
      Sleep(100);
      // Windows resize detection: poll the console geometry (cheap, no
      // repaint). When it changes, wait for the drag to settle, then do a
      // single refresh + redraw, plus one delayed healing pass (painting
      // mid-resize at a stale size can scroll the screen by a line).
      if NcConsoleSize(newr, newc) and ((newr <> rows) or (newc <> cols)) then
      begin
        repeat
          rows := newr;
          cols := newc;
          Sleep(120);
        until not NcConsoleSize(newr, newc) or ((newr = rows) and (newc = cols));
        // notcurses_refresh repaints the full screen after a bare clear,
        // assuming the cursor is home - put it there first (see ncconsole).
        NcConsoleHome;
        notcurses_refresh(nc, @rows, @cols);
        Redraw;
        Sleep(150);
        NcConsoleHome;
        notcurses_refresh(nc, @rows, @cols);
        Redraw;
      end;
      // Already-expired deadline: non-blocking input poll (0 = nothing).
      key := notcurses_get(nc, @zero, @ni);
      if key = NCKEY_RESIZE then
      begin
        // POSIX path: the resize arrives as an input event.
        NcConsoleHome;
        notcurses_refresh(nc, @rows, @cols);
        Redraw;
        key := 0;
      end;
    until key <> 0;
  finally
    NcConsoleQuiesce; // see ncconsole: makes the teardown safe on Windows
    notcurses_stop(nc);
    NcConsoleRestore;
  end;
end.
