# regen.ps1 - Regenerate src/notcurses.pas from the vendored notcurses headers.
#
# Pipeline:
#   1. Copy the vendored headers to a temp dir, expanding the preterunicode()
#      function-like macro so that chet-cli can translate the NCKEY_* defines.
#   2. Run chet-cli (Chet, the libclang-based C-header-to-Pascal translator)
#      with NOTCURSES_FFI defined and `inline` blanked out, so that the
#      static inline helper functions are translated as regular imports
#      (they are exported as real symbols by libnotcurses-ffi).
#   3. Post-process the generated unit:
#        - insert FPC compatibility directives and type shims
#        - declare timespec and ncwchar_t (wchar_t differs per platform)
#        - split imports across the three notcurses libraries
#          (core / full / ffi) based on third_party/notcurses/ffi.c
#        - remove duplicate declarations (C forward decl + definition)
#        - fix the varargs directive placement
#
# Requires: chet-cli (https://github.com/neslib/Chet CLI build) and a C
# development environment that libclang can use for system headers (any
# Visual Studio with C++ suffices).

param(
  [string]$ChetCli = 'C:\Users\badb\Documents\Embarcadero\Studio\Tools\chet-cli\ChetCLI.exe'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$vendored = Join-Path $repo 'third_party\notcurses'
$outPas = Join-Path $repo 'src\notcurses.pas'

if (-not (Test-Path $ChetCli)) {
  throw "chet-cli not found at '$ChetCli' (pass -ChetCli <path>)"
}

# ---------------------------------------------------------------------------
# 1. Prepare a conversion copy of the headers
# ---------------------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'notcurses-pas-regen'
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force "$work\include\notcurses" | Out-Null
Copy-Item "$vendored\include\notcurses\*.h" "$work\include\notcurses\"

# Expand preterunicode(N) so the NCKEY_* macros become plain expressions that
# Chet knows how to turn into Pascal constants.
$nckeys = "$work\include\notcurses\nckeys.h"
(Get-Content $nckeys -Raw) -replace 'preterunicode\((\d+)\)', '(($1) + PRETERUNICODEBASE)' |
  Set-Content $nckeys -NoNewline

# ---------------------------------------------------------------------------
# 2. Run chet-cli
# ---------------------------------------------------------------------------
& $ChetCli generate `
  --headers "$work\include\notcurses" `
  --out $outPas `
  --lib-const NOTCURSES_LIB `
  --platform win64=libnotcurses-3.dll `
  --platform linux64=libnotcurses.so.3 `
  --platform macarm=libnotcurses.3.dylib `
  --platform macintel=libnotcurses.3.dylib `
  --clang-arg "-I$work\include" `
  --clang-arg '-D__MINGW32__' `
  --clang-arg '-DNOTCURSES_FFI' `
  --clang-arg '-Dinline=' `
  --enum-handling const `
  --char utf8char `
  --comments keep `
  --unconvertible comment
if ($LASTEXITCODE -ne 0) { throw "chet-cli failed with exit code $LASTEXITCODE" }

# ---------------------------------------------------------------------------
# 3. Post-process the generated unit
# ---------------------------------------------------------------------------

# chet-cli reads the (UTF-8) headers as ANSI and writes its output as UTF-8,
# so every non-ASCII character comes out double-encoded. Undo that.
$cp1252 = [System.Text.Encoding]::GetEncoding(1252,
  [System.Text.EncoderExceptionFallback]::new(),
  [System.Text.DecoderExceptionFallback]::new())
$utf8strict = [System.Text.UTF8Encoding]::new($false, $true)
function Repair-Mojibake([string]$s) {
  if ($s -notmatch '[^\x00-\x7F]') { return $s }
  try { return $utf8strict.GetString($cp1252.GetBytes($s)) } catch { return $s }
}

# The string constants of ncseqs.h are wchar_t (L"...") literals in C, whose
# element width differs per platform. Chet also garbles their content, so we
# re-emit every one of them ourselves as a UTF8String typed constant, decoding
# the C literals straight from the vendored header.
function Decode-CLiteral([string]$body) {
  $sb = [System.Text.StringBuilder]::new()
  $k = 0
  while ($k -lt $body.Length) {
    $c = $body[$k]
    if ($c -eq '\') {
      $k++
      $e = $body[$k]
      if ($e -ceq 'u') {
        [void]$sb.Append([char]::ConvertFromUtf32([Convert]::ToInt32($body.Substring($k + 1, 4), 16))); $k += 4
      } elseif ($e -ceq 'U') {
        [void]$sb.Append([char]::ConvertFromUtf32([Convert]::ToInt32($body.Substring($k + 1, 8), 16))); $k += 8
      } elseif ($e -eq '\') {
        [void]$sb.Append('\')
      } elseif ($e -eq '"') {
        [void]$sb.Append('"')
      } else {
        throw "unhandled C escape '\$e' in ncseqs.h"
      }
      $k++
    } else {
      [void]$sb.Append($c)
      $k++
    }
  }
  $sb.ToString()
}

$seqText = (Get-Content "$vendored\include\notcurses\ncseqs.h" -Raw) -replace "\\\r?\n", ' '
$seqConsts = [ordered]@{}
foreach ($m in [regex]::Matches($seqText, '(?m)^\s*#define\s+(NC\w+)\s+(.+)$')) {
  $name = $m.Groups[1].Value
  $value = ''
  foreach ($lit in [regex]::Matches($m.Groups[2].Value, '"((?:[^"\\]|\\.)*)"')) {
    $value += Decode-CLiteral $lit.Groups[1].Value
  }
  $seqConsts[$name] = $value
}
if ($seqConsts.Count -lt 40) { throw "ncseqs.h parse looks wrong ($($seqConsts.Count) macros)" }

function Format-SeqConst([string]$name, [string]$value) {
  # Split on rune boundaries so astral glyphs are never cut in half.
  $chunks = [System.Collections.Generic.List[string]]::new()
  $cur = [System.Text.StringBuilder]::new()
  $n = 0
  foreach ($rune in $value.EnumerateRunes()) {
    [void]$cur.Append($rune.ToString())
    if ((++$n) -eq 32) { $chunks.Add($cur.ToString()); [void]$cur.Clear(); $n = 0 }
  }
  if ($cur.Length -gt 0) { $chunks.Add($cur.ToString()) }
  $lines = @()
  for ($k = 0; $k -lt $chunks.Count; $k++) {
    $lit = "'" + ($chunks[$k] -replace "'", "''") + "'"
    if ($k -eq 0) { $prefix = "  ${name}: UTF8String = " } else { $prefix = '    ' }
    if ($k -lt $chunks.Count - 1) { $suffix = ' +' } else { $suffix = ';' }
    $lines += ($prefix + $lit + $suffix)
  }
  $lines
}

# Symbols exported by libnotcurses-ffi (the un-inlined static inline helpers);
# the list is authoritative: third_party/notcurses/ffi.c, itself generated by
# notcurses' tools/generate_ffi.py.
$ffiSrc = Get-Content "$vendored\ffi.c" -Raw
$ffiSrc = $ffiSrc -replace '(?m)^\s*//.*$', '' -replace '(?m)^#.*$', ''
$ffiSet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($chunk in ($ffiSrc -split ';')) {
  if ($chunk -match '(\w+)\s*\(') { [void]$ffiSet.Add($Matches[1]) }
}
[void]$ffiSet.Remove('__attribute__')

# Symbols exported by libnotcurses (the multimedia-enabling entry points,
# defined in notcurses' src/media/shim.c). Everything else lives in
# libnotcurses-core.
$fullSet = @('notcurses_init', 'ncdirect_init')

$lines = [System.Collections.Generic.List[string]]::new()
foreach ($l in (Get-Content $outPas)) { $lines.Add((Repair-Mojibake $l)) }
$out = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()
$seqEmitted = $false

$i = 0
while ($i -lt $lines.Count) {
  $line = $lines[$i]

  # --- unit header: add the do-not-edit notice ------------------------------
  if ($line -match '^\{ This unit is automatically generated by ChetCLI') {
    $out.Add('{ Pascal (Delphi / Free Pascal) binding for Notcurses 3.0.17')
    $out.Add('  https://github.com/dankamongmen/notcurses')
    $out.Add('')
    $out.Add('  Generated by tools/regen.ps1 - DO NOT EDIT MANUALLY.')
    $out.Add(' ' + $line.Substring(1))
    $i++
    continue
  }

  # --- drop the leaked parse-time define ------------------------------------
  if ($line -match '^\s*NOTCURSES_FFI = 1;') {
    $i++
    continue
  }

  # --- FPC directives, right before {$MINENUMSIZE 4} ------------------------
  if ($line -eq '{$MINENUMSIZE 4}') {
    $out.Add('{$IFDEF FPC}')
    $out.Add('  {$MODE DELPHI}')
    $out.Add('  {$PACKRECORDS C}')
    $out.Add('{$ENDIF}')
    $out.Add($line)
    $i++
    continue
  }

  # --- interface: type shims for compilers lacking UTF8Char -----------------
  if ($line -eq 'interface') {
    $out.Add($line)
    $out.Add('')
    $out.Add('{$IF not Declared(UTF8Char)}')
    $out.Add('type')
    $out.Add('  // Delphi 10.4+ declares these in System; FPC 3.2 does not.')
    $out.Add('  UTF8Char = AnsiChar;')
    $out.Add('  PUTF8Char = ^UTF8Char;')
    $out.Add('{$ENDIF}')
    $i++
    continue
  }

  # --- library constants block ---------------------------------------------
  if ($line -match '^\s*\{\$IF Defined\(WIN64\)\}') {
    # Skip the generated platform block up to and including its {$ENDIF}
    while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s*\{\$ENDIF\}') { $i++ }
    $i++  # skip the {$ENDIF} itself
    $out.Add('  { Notcurses ships three shared libraries:')
    $out.Add('      - notcurses-core: the complete core API;')
    $out.Add('      - notcurses:      notcurses_init/ncdirect_init, which enable the')
    $out.Add('                        multimedia backend (FFmpeg/OIIO) and then defer')
    $out.Add('                        to their notcurses-core _core_init counterparts;')
    $out.Add('      - notcurses-ffi:  the static inline helpers of the C API, exported')
    $out.Add('                        as real symbols (BUILD_FFI_LIBRARY).')
    $out.Add('    Each import below names the library that actually exports it, which')
    $out.Add('    matters on Windows, where symbols are not resolved transitively. }')
    $out.Add('  {$IF Defined(MSWINDOWS)}')
    $out.Add('  NOTCURSES_CORE_LIB = ''libnotcurses-core-3.dll'';')
    $out.Add('  NOTCURSES_LIB      = ''libnotcurses-3.dll'';')
    $out.Add('  NOTCURSES_FFI_LIB  = ''libnotcurses-ffi-3.dll'';')
    $out.Add('  _PU = '''';')
    $out.Add('  {$ELSEIF Defined(MACOS) or Defined(DARWIN)}')
    $out.Add('  NOTCURSES_CORE_LIB = ''libnotcurses-core.3.dylib'';')
    $out.Add('  NOTCURSES_LIB      = ''libnotcurses.3.dylib'';')
    $out.Add('  NOTCURSES_FFI_LIB  = ''libnotcurses-ffi.3.dylib'';')
    $out.Add('  _PU = '''';')
    $out.Add('  {$ELSE}  // Linux and other ELF platforms')
    $out.Add('  NOTCURSES_CORE_LIB = ''libnotcurses-core.so.3'';')
    $out.Add('  NOTCURSES_LIB      = ''libnotcurses.so.3'';')
    $out.Add('  NOTCURSES_FFI_LIB  = ''libnotcurses-ffi.so.3'';')
    $out.Add('  _PU = '''';')
    $out.Add('  {$ENDIF}')
    continue
  }

  # --- version-ordering constant, after the VERNUM defines ------------------
  if ($line -match '^\s*NOTCURSES_VERNUM_TWEAK = ') {
    $out.Add($line)
    $out.Add('  // NOTCURSES_VERSION_COMPARABLE(NOTCURSES_VERNUM_MAJOR, _MINOR, _PATCH)')
    $out.Add('  NOTCURSES_VERNUM_ORDERED = (NOTCURSES_VERNUM_MAJOR shl 16) +')
    $out.Add('    (NOTCURSES_VERNUM_MINOR shl 8) + NOTCURSES_VERNUM_PATCH;')
    $i++
    continue
  }

  # --- replace the ncseqs.h glyph constants (see above) ---------------------
  if ($line -match "^\s*(NC\w+) = '" -and $seqConsts.Contains($Matches[1])) {
    if (-not $seqEmitted) {
      $seqEmitted = $true
      $out.Add('  { The ncseqs.h constants are wchar_t strings in C (width differs per')
      $out.Add('    platform); they are provided here as UTF-8 instead, ready for the')
      $out.Add('    UTF-8 based notcurses API. }')
      foreach ($kv in $seqConsts.GetEnumerator()) {
        foreach ($cl in (Format-SeqConst $kv.Key $kv.Value)) { $out.Add($cl) }
      }
    }
    $i++
    continue
  }

  # --- NCALIGN_TOP/_BOTTOM alias defines appear before the ncalign_e enum
  #     constants they refer to; move them right after those -----------------
  if ($line -match '^\s*NCALIGN_(TOP|BOTTOM) = NCALIGN_') {
    $i++
    continue
  }
  if ($line -match '^\s*NCALIGN_RIGHT = \d+;') {
    $out.Add($line)
    $out.Add('  NCALIGN_TOP = NCALIGN_LEFT;')
    $out.Add('  NCALIGN_BOTTOM = NCALIGN_RIGHT;')
    $i++
    continue
  }

  # --- drop the generated PWideChar forward (replaced by Pncwchar_t) --------
  if ($line -match '^\s*PWideChar = \^WideChar;') {
    $i++
    continue
  }

  # --- inject timespec / ncwchar_t after the last builtin forward decl ------
  if ($line -match '^\s*PPointer = \^Pointer;') {
    $out.Add($line)
    $out.Add('')
    $out.Add('  // struct timespec from <time.h>: tv_sec is time_t (64-bit on every')
    $out.Add('  // supported target), tv_nsec is a C long (32-bit on Win64, pointer-')
    $out.Add('  // sized elsewhere). Only 64-bit platforms are supported.')
    $out.Add('  timespec = record')
    $out.Add('    tv_sec: Int64;')
    $out.Add('    tv_nsec: {$IFDEF MSWINDOWS}LongInt{$ELSE}NativeInt{$ENDIF};')
    $out.Add('  end;')
    $out.Add('  Ptimespec = ^timespec;')
    $out.Add('')
    $out.Add('  // C wchar_t: 16-bit (UTF-16 unit) on Windows, 32-bit elsewhere.')
    $out.Add('  ncwchar_t = {$IFDEF MSWINDOWS}WideChar{$ELSE}UCS4Char{$ENDIF};')
    $out.Add('  Pncwchar_t = ^ncwchar_t;')
    $i++
    continue
  }

  # --- function/procedure declaration blocks --------------------------------
  if ($line -match '^(function|procedure)\s+(&?\w+)') {
    $name = $Matches[2].TrimStart('&')
    $block = [System.Collections.Generic.List[string]]::new()
    while ($i -lt $lines.Count) {
      $block.Add($lines[$i])
      if ($lines[$i] -match '^\s+external\s') { $i++; break }
      $i++
    }
    # Skip the blank line following a dropped duplicate
    if (-not $seen.Add($name)) {
      if ($i -lt $lines.Count -and $lines[$i] -eq '') { $i++ }
      continue
    }
    # C: `API int (*ncplane_resizecb(const struct ncplane* n))(struct ncplane*);`
    # (a function returning a function pointer) is garbled by Chet.
    if ($name -eq 'ncplane_resizecb') {
      $block[0] = 'function ncplane_resizecb(const n: Pncplane): ncplane_set_resizecb_resizecb; cdecl;'
    }
    for ($j = 0; $j -lt $block.Count; $j++) {
      $b = $block[$j]
      # varargs must follow the calling convention
      $b = $b -replace '\): (\w+) varargs; cdecl;', '): $1; cdecl; varargs;'
      # wchar_t must not be mapped to the Windows-only 16-bit WideChar
      $b = $b -replace '\bPWideChar\b', 'Pncwchar_t' -replace '\bWideChar\b', 'ncwchar_t'
      # route the import to the library that actually exports the symbol
      if ($b -match '^\s+external\s') {
        if ($ffiSet.Contains($name)) {
          $b = $b -replace 'external NOTCURSES_LIB ', 'external NOTCURSES_FFI_LIB '
        } elseif ($fullSet -notcontains $name) {
          $b = $b -replace 'external NOTCURSES_LIB ', 'external NOTCURSES_CORE_LIB '
        }
      }
      $out.Add($b)
    }
    continue
  }

  # --- everywhere else: fix wchar_t references (callback types etc.) --------
  $out.Add(($line -replace '\bPWideChar\b', 'Pncwchar_t' -replace '\bWideChar\b', 'ncwchar_t'))
  $i++
}

# UTF-8 with BOM: both dcc and fpc then read the glyph literals correctly.
Set-Content -Path $outPas -Value $out -Encoding utf8BOM

Remove-Item -Recurse -Force $work

$fn = ($out | Where-Object { $_ -match '^\s+external\s' }).Count
Write-Host "OK: $outPas regenerated ($($out.Count) lines, $fn imports," `
  "$($ffiSet.Count) ffi symbols)"
