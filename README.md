# notcurses-pas

Pascal (Delphi / Free Pascal) binding for [Notcurses](https://github.com/dankamongmen/notcurses) 3.0.17.

- `src/notcurses.pas` — the full public C API: 609 functions, constants, structs, callbacks. Generated, do not edit.
- `src/ncconsole.pas` — required helpers for Windows consoles (see below).
- Delphi 10.4+ (tested: Delphi 12) and FPC 3.2+ (`{$MODE DELPHI}`). 64-bit targets: Windows, Linux, macOS.

## Native libraries

Notcurses splits its API across three libraries; each import names the one
that exports it (Windows does not resolve symbols transitively):

- `notcurses-core` — the whole core API (`notcurses_core_init`, planes, input, widgets)
- `notcurses` — only `notcurses_init` / `ncdirect_init`, which enable the FFmpeg backend
- `notcurses-ffi` — the 236 `static inline` helpers, exported as real symbols

Install:

- Debian/Ubuntu: `apt install libnotcurses3 libnotcurses-core3 libnotcurses-ffi3`
- Fedora: `dnf install notcurses` — macOS: `brew install notcurses`
- Windows: MSYS2 **UCRT64** package `mingw-w64-ucrt-x86_64-notcurses` + its
  dependencies, next to the exe or on PATH. Not the msvcrt (`mingw-w64-x86_64`)
  build: its CRT has no UTF-8 locale, every non-ASCII glyph renders as `�`.

Stay on `notcurses_core_init`/`ncdirect_core_init` and you don't need
`notcurses` nor FFmpeg at runtime.

## Quick start

```pascal
program hello;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
uses ncconsole, notcurses;
var
  opts: notcurses_options;
  nc: Pnotcurses;
  std: Pncplane;
begin
  FillChar(opts, SizeOf(opts), 0);
  opts.flags := NCOPTION_SUPPRESS_BANNERS;
  NcConsolePrepare;                       // required on Windows
  nc := notcurses_core_init(@opts, nil);
  if nc = nil then Halt(1);
  std := notcurses_stdplane(nc);
  ncplane_set_fg_rgb8(std, $52, $C8, $FF);
  ncplane_putstr_yx(std, 1, 2, 'Hello from Pascal!');
  notcurses_render(nc);
  notcurses_get_blocking(nc, nil);
  NcConsoleQuiesce;
  notcurses_stop(nc);
  NcConsoleRestore;
end.
```

```
fpc -Mdelphi -Fusrc examples/hello.dpr        # FPC
dcc64 -Usrc examples\hello.dpr                # Delphi
```

Examples: `hello` (full screen, resize-aware), `direct` (inline output),
`ncinfo` (capabilities, glyph/emoji coverage), `ncimage` (sixel/kitty image),
`ncvideo` (video player). `tests/smoke.dpr` checks the libraries load.

## Windows

Notcurses 3.0.17 has several Windows console defects; `ncconsole.pas` works
around them (details at each declaration, all reproduced under the ConPTY
harness in `tests/harness/`):

- `NcConsolePrepare` **before init** — upstream never leaves cooked/echo mode
  on Windows: garbage echo, dead keyboard, stalled init.
- `NcConsoleQuiesce` before `notcurses_stop`, `NcConsoleRestore` last —
  teardown races the never-stopped input thread (heap corruption), and late
  terminal replies would be pasted into the shell prompt.
- `NcConsoleHome` before any full repaint (first render, `notcurses_refresh`)
  — the Windows "clear" escape doesn't home the cursor, the rasterizer
  assumes it does.
- Media programs: skip `notcurses_stop` and `ncvisual_destroy` entirely and
  exit via `NcConsoleLeaveScreen` + `NcConsoleRestore` (see `ncimage`).

## Multimedia

`notcurses_init` enables `ncvisual` via FFmpeg 9 (`avcodec-63`…). On Windows
the [BtbN win64 shared n9.0 build](https://github.com/BtbN/FFmpeg-Builds/releases)
is a self-contained DLL set. One upstream trap: decoding non-RGBA frames
corrupts the heap (`force_rgba()` memcpys an `AVFrame` and clones its
buffer refs). `ncvideo` auto-detects this and pre-converts with
ffmpeg/ffprobe when available; by hand:

```
ffmpeg -i input.mp4 -an -vf format=rgba -c:v png output.mov
```

## Regenerating

`pwsh tools/regen.ps1` — parses the vendored headers
(`third_party/notcurses/`) with
[**chet-cli**](https://github.com/flydev-fr/chet-cli) (libclang-based
C-header translator), then post-processes: import split from `ffi.c`, NCKEY macro
expansion, `ncseqs.h` glyph tables re-emitted as `UTF8String` constants,
FPC shims, `timespec`/`ncwchar_t`. Needs Windows + chet-cli + Visual C++.

Translation choices: C enums become integer constants; strings are
`PUTF8Char`; `wchar_t` is `ncwchar_t` (16-bit Windows / 32-bit elsewhere);
`FILE*` is `PPointer` (pass `nil` for stdout); variadics are
`cdecl; varargs;`.

## License

Apache 2.0, same as Notcurses (see `third_party/notcurses/COPYRIGHT`).
