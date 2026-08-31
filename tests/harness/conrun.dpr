program conrun;
// Launcher: gives the child real read-write console handles (CONIN$/CONOUT$),
// as an interactively launched program would have. stderr is passed through
// so `2>file` redirections keep working.
{$APPTYPE CONSOLE}
uses Winapi.Windows;
var
  sa: TSecurityAttributes;
  hin, hout: THandle;
  si: TStartupInfo;
  pi: TProcessInformation;
  cmdline: string;
  i: Integer;
  ec: DWORD;
begin
  sa.nLength := SizeOf(sa);
  sa.lpSecurityDescriptor := nil;
  sa.bInheritHandle := True;
  hin := CreateFile('CONIN$', GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, @sa, OPEN_EXISTING, 0, 0);
  hout := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, @sa, OPEN_EXISTING, 0, 0);
  cmdline := '';
  for i := 1 to ParamCount do
    cmdline := cmdline + ParamStr(i) + ' ';
  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  si.dwFlags := STARTF_USESTDHANDLES;
  si.hStdInput := hin;
  si.hStdOutput := hout;
  si.hStdError := GetStdHandle(STD_ERROR_HANDLE);
  if not CreateProcess(nil, PChar(cmdline), nil, nil, True, 0, nil, nil, si, pi) then
    Halt(97);
  WaitForSingleObject(pi.hProcess, INFINITE);
  GetExitCodeProcess(pi.hProcess, ec);
  Halt(ec);
end.
