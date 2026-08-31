program direct;
// Direct mode example: styled, colored output that cooperates with the
// regular terminal scrollback (no full-screen takeover).
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  ncconsole,
  notcurses;

var
  nd: Pncdirect;
begin
  Writeln('linked against notcurses ', string(notcurses_version()));

  // Required on Windows consoles - see the ncconsole unit.
  NcConsolePrepare;
  nd := ncdirect_core_init(nil, nil, NCDIRECT_OPTION_DRAIN_INPUT);
  if nd = nil then
  begin
    NcConsoleRestore;
    Writeln(ErrOutput, 'ncdirect_core_init failed (not running in a terminal?)');
    Halt(1);
  end;
  try
    ncdirect_set_styles(nd, NCSTYLE_BOLD);
    ncdirect_set_fg_rgb8(nd, $FF, $88, $00);
    ncdirect_putstr(nd, 0, 'bold orange');

    ncdirect_set_styles(nd, NCSTYLE_ITALIC);
    ncdirect_set_fg_rgb8(nd, $52, $C8, $FF);
    ncdirect_putstr(nd, 0, ' italic blue');

    ncdirect_set_styles(nd, NCSTYLE_NONE);
    ncdirect_set_fg_default(nd);
    ncdirect_putstr(nd, 0, ' and back to normal.'#10);
  finally
    {$IFDEF MSWINDOWS}
    // ncdirect_stop corrupts the heap on Windows (racy teardown against the
    // never-stopped input thread, upstream #2192). In direct mode there is
    // nothing it restores that we have not already reset above, so skip it
    // and put the console back ourselves.
    NcConsoleRestore;
    {$ELSE}
    ncdirect_stop(nd);
    {$ENDIF}
  end;
end.
