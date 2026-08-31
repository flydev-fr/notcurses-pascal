program smoke;
// TTY-less smoke test: exercises one import from libnotcurses-core and a few
// from libnotcurses-ffi, and cross-checks values computed by the C library
// against the constants declared in the binding.
// Exit code 0 = pass; anything else = fail.
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  notcurses;

procedure Check(cond: Boolean; const what: string);
begin
  if cond then
    Writeln('ok   - ', what)
  else
  begin
    Writeln('FAIL - ', what);
    Halt(1);
  end;
end;

var
  ver: string;
  major, minor, patch, tweak: Integer;
  chans: UInt64;
begin
  // libnotcurses-core
  ver := string(notcurses_version());
  Check(ver <> '', 'notcurses_version() = ' + ver);
  notcurses_version_components(@major, @minor, @patch, @tweak);
  Check((major = NOTCURSES_VERNUM_MAJOR) and (minor = NOTCURSES_VERNUM_MINOR),
    Format('version components %d.%d.%d.%d match binding (%d.%d.%d)',
      [major, minor, patch, tweak,
       NOTCURSES_VERNUM_MAJOR, NOTCURSES_VERNUM_MINOR, NOTCURSES_VERNUM_PATCH]));

  // libnotcurses-ffi (un-inlined static inline helpers)
  chans := 0;
  Check(ncchannels_set_fg_rgb8(@chans, $11, $22, $33) = 0, 'ncchannels_set_fg_rgb8');
  Check((chans shr 32) and $FFFFFF = $112233, 'fg rgb stored in upper channel');
  Check(ncchannels_fg_rgb(chans) = $112233, 'ncchannels_fg_rgb round-trip');
  Check(nckey_synthesized_p(NCKEY_UP), 'nckey_synthesized_p(NCKEY_UP)');
  Check(not nckey_synthesized_p(Ord('A')), 'not nckey_synthesized_p(''A'')');

  Writeln('SMOKE OK');
end.
