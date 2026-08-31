# ConPTY test harness

Simulates Windows Terminal well enough to exercise the notcurses Windows
code paths without a human at a terminal. Used to diagnose and validate the
workarounds in src/ncconsole.pas.

- `ConPtyHost.cs` - CreatePseudoConsole host (load with `Add-Type -Path`).
  `[ConPtyHost]::Run(cmdline, workdir, outLog, burstDelayMs, keyDelayMs,
  key, timeoutMs)` runs a command attached to a ConPTY, logs its output,
  and injects a simulated Windows-Terminal reply burst (CPR, 256x OSC 4
  palette reports, OSC 10/11, DECRPM, XTWINOPS, DA1) after `burstDelayMs`,
  plus an optional keystroke. Returns the process exit code.
  Input must be (and is) win32-input-mode encoded - conhost eats raw VT
  reply text arriving on the host input pipe.
- `conrun.dpr` - launcher that hands the child real read-write
  CONIN$/CONOUT$ handles (the host severs std handles, and cmd's `<CON`
  redirection opens read-only, which breaks SetConsoleMode).
- `../inputdump.dpr` - prints whatever is left unread in the console input
  queue, i.e. what the shell would paste at the next prompt.

Typical check, from a PowerShell in a directory containing the notcurses
DLLs and the built examples + tools:

    Add-Type -Path tests\harness\ConPtyHost.cs
    [ConPtyHost]::Run('cmd.exe /c ".\conrun.exe .\direct.exe & ' +
      '.\conrun.exe .\inputdump.exe"', $pwd, "$env:TEMP\conpty.log",
      100, -1, '', 25000)

Expect exit code 0 (no STATUS_HEAP_CORRUPTION) and
`LEFTOVER-INPUT-CHARS: 0` in the log.
