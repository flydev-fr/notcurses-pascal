unit ncconsole;

// Windows console preparation for Notcurses.
//
// Notcurses has a defect on Windows consoles (as of 3.0.17): the
// cbreak_mode() call that disables line buffering and echo is compiled out
// under __MINGW32__ (src/lib/termdesc.c, the call sits inside a
// `#ifndef __MINGW32__` block). Run under Windows Terminal / conhost, the
// console therefore stays in cooked echo mode, with three symptoms:
//   - the replies to notcurses' startup interrogation (DA1, the 256-color
//     palette dump, mode reports...) are echoed to the screen as escape
//     garbage by the console's line editor (ESC shown as ^[);
//   - reads block until Enter is pressed, so keyboard input appears dead;
//   - initialization stalls waiting for replies it cannot read.
//
// Call NcConsolePrepare BEFORE notcurses_core_init / notcurses_init /
// ncdirect_core_init / ncdirect_init, and NcConsoleRestore after stopping
// notcurses. Both are safe no-ops on non-Windows platforms and when no
// console is attached (e.g. output redirected).

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

// A second upstream defect matters for teardown: on Windows the notcurses
// input thread is never stopped (src/lib/in.c, stop_inputlayer is compiled
// out, upstream issue #2192), and notcurses_stop/ncdirect_stop tear state
// down under that live thread, which can corrupt the C heap
// (STATUS_HEAP_CORRUPTION, usually reported at process exit; whether it
// fires depends on heap layout, so it can look nondeterministic).
// Guidance, validated empirically under a ConPTY test harness:
//   - short-lived direct-mode programs: skip ncdirect_stop entirely on
//     Windows (reset styles/colors yourself, then NcConsoleRestore; the
//     process is exiting anyway) - see examples/direct.dpr;
//   - full-screen programs: call NcConsoleQuiesce, then notcurses_stop
//     (needed to leave the alternate screen), then NcConsoleRestore;
//   - never read console input between init and stop: stealing queued
//     events engages the input thread in a blocking read and widens the
//     teardown race. Draining is safe once the program is out of notcurses,
//     which is what NcConsoleRestore does.

interface

procedure NcConsolePrepare;
procedure NcConsoleQuiesce;
procedure NcConsoleRestore;

// Windows has no push notification for terminal resizes (the NCKEY_RESIZE
// event is SIGWINCH-based, POSIX only), so a program that wants to follow
// resizes polls the console geometry and calls notcurses_refresh + redraws
// when it changes. NcConsoleSize reads the current geometry the same way
// notcurses itself does (visible-window height, buffer width) WITHOUT
// triggering a repaint - polling notcurses_refresh instead repaints the
// whole screen every tick and flickers. Returns False when there is no
// console (and on non-Windows platforms, where NCKEY_RESIZE does the job).
function NcConsoleSize(out rows, cols: Cardinal): Boolean;

// Yet another Windows quirk: notcurses' built-in Windows escape table
// defines "clear" as bare ESC[2J (real terminfo uses ESC[H ESC[2J), and the
// rasterizer assumes the cursor sits at home after a clear. The first full
// frame therefore gets painted starting at the CURRENT cursor position -
// typically the shell prompt row - shifting the whole top of the screen
// off, and the damage tracker then believes those cells are correct and
// never repairs them. Call NcConsoleHome right before rendering a full
// frame (simplest: at the top of your redraw routine). No-op off Windows.
procedure NcConsoleHome;

// With the FFmpeg multimedia backend loaded, the notcurses teardown heap
// corruption (see above) gets much easier to trigger; the reliable pattern
// for a full-screen media program on Windows is to skip notcurses_stop
// entirely and restore the terminal by hand: NcConsoleLeaveScreen resets
// the SGR state, leaves the alternate screen and re-shows the cursor
// (process exit reclaims the memory). Follow it with NcConsoleRestore.
// No-op off Windows, where the normal notcurses_stop path is safe.
procedure NcConsoleLeaveScreen;

implementation

{$IFDEF MSWINDOWS}
uses
  {$IFDEF FPC}Windows{$ELSE}Winapi.Windows{$ENDIF};

var
  SavedMode: DWORD = 0;
  SavedModeValid: Boolean = False;

// A fresh CONIN$ handle: the input mode and queue belong to the console
// itself, and the process std handle may be gone by the time we clean up.
function OpenConIn: THandle;
begin
  Result := CreateFile('CONIN$', GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
end;

procedure NcConsolePrepare;
var
  hin: THandle;
  mode: DWORD;
begin
  hin := OpenConIn;
  if hin = INVALID_HANDLE_VALUE then
    Exit;
  if GetConsoleMode(hin, mode) then
  begin
    if not SavedModeValid then
    begin
      SavedMode := mode;
      SavedModeValid := True;
    end;
    SetConsoleMode(hin, mode and not (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT));
  end;
  CloseHandle(hin);
end;

// Read-and-discard console input until it stays quiet for 250ms (1s cap).
procedure DrainConIn(hin: THandle);
var
  recs: array [0..63] of TInputRecord;
  nread, avail: DWORD;
  idle, total: Integer;
begin
  idle := 0;
  total := 0;
  while (idle < 5) and (total < 20) do
  begin
    if not GetNumberOfConsoleInputEvents(hin, avail) then
      Break;
    if avail = 0 then
    begin
      Sleep(50);
      Inc(idle);
      Inc(total);
      Continue;
    end;
    idle := 0;
    if not ReadConsoleInput(hin, recs[0], Length(recs), nread) then
      Break;
  end;
end;

procedure NcConsoleQuiesce;
begin
  // No reads here (see the unit comment): just give the notcurses input
  // thread time to finish its startup work and park itself.
  Sleep(300);
end;

procedure NcConsoleRestore;
var
  hin: THandle;
begin
  if not SavedModeValid then
    Exit;
  hin := OpenConIn;
  if hin <> INVALID_HANDLE_VALUE then
  begin
    DrainConIn(hin);
    SetConsoleMode(hin, SavedMode);
    CloseHandle(hin);
  end;
  SavedModeValid := False;
end;
procedure NcConsoleHome;
var
  hout: THandle;
  pos: TCoord;
begin
  hout := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if hout = INVALID_HANDLE_VALUE then
    Exit;
  pos.X := 0;
  pos.Y := 0;
  SetConsoleCursorPosition(hout, pos);
  CloseHandle(hout);
end;

procedure NcConsoleLeaveScreen;
const
  seq: AnsiString = #27'[0m'#27'[?1049l'#27'[?25h';
var
  hout: THandle;
  written: DWORD;
begin
  hout := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if hout = INVALID_HANDLE_VALUE then
    Exit;
  WriteFile(hout, seq[1], Length(seq), written, nil);
  CloseHandle(hout);
end;

function NcConsoleSize(out rows, cols: Cardinal): Boolean;
var
  hout: THandle;
  csbi: TConsoleScreenBufferInfo;
begin
  Result := False;
  rows := 0;
  cols := 0;
  hout := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if hout = INVALID_HANDLE_VALUE then
    Exit;
  if GetConsoleScreenBufferInfo(hout, csbi) then
  begin
    // same computation as notcurses' update_term_dimensions on Windows
    rows := Cardinal(csbi.srWindow.Bottom - csbi.srWindow.Top + 1);
    cols := Cardinal(csbi.dwSize.X);
    Result := True;
  end;
  CloseHandle(hout);
end;
{$ELSE}
procedure NcConsolePrepare;
begin
end;

procedure NcConsoleQuiesce;
begin
end;

procedure NcConsoleRestore;
begin
end;

function NcConsoleSize(out rows, cols: Cardinal): Boolean;
begin
  rows := 0;
  cols := 0;
  Result := False;
end;

procedure NcConsoleHome;
begin
end;

procedure NcConsoleLeaveScreen;
begin
end;
{$ENDIF}

end.
