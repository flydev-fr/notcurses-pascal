program inputdump;
// Diagnostic helper: after another program in the same console exits, report
// whatever is still sitting unread in the console input buffer (this is what
// the shell would echo back at the next prompt). Control characters are shown
// in caret notation.
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}Windows{$ELSE}Winapi.Windows{$ENDIF};

var
  h: THandle;
  recs: array [0..127] of TInputRecord;
  nread, navail, total: DWORD;
  i: Integer;
  idle: Integer;
  s: string;
  ch: WideChar;
begin
  h := GetStdHandle(STD_INPUT_HANDLE);
  total := 0;
  s := '';
  idle := 0;
  // poll for ~1s so that late-arriving terminal replies are counted too
  while idle < 10 do
  begin
    if not GetNumberOfConsoleInputEvents(h, navail) then Break;
    if navail = 0 then
    begin
      Sleep(100);
      Inc(idle);
      Continue;
    end;
    idle := 0;
    if not ReadConsoleInputW(h, recs[0], Length(recs), nread) then Break;
    for i := 0 to Integer(nread) - 1 do
      if (recs[i].EventType = KEY_EVENT) and recs[i].Event.KeyEvent.bKeyDown then
      begin
        ch := recs[i].Event.KeyEvent.UnicodeChar;
        if ch = #0 then Continue;
        Inc(total);
        if Length(s) < 300 then
        begin
          if ch = #27 then s := s + '^['
          else if ch < ' ' then s := s + '^' + Chr(Ord('@') + Ord(ch))
          else s := s + string(ch);
        end;
      end;
  end;
  Writeln('LEFTOVER-INPUT-CHARS: ', total);
  if total > 0 then
    Writeln('LEFTOVER-SAMPLE: ', s);
end.
