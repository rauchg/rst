<img width="115" height="86.4" style="margin-bottom: -10px" alt="make-transparent-old-school-cropped" src="https://github.com/user-attachments/assets/77dcf905-73fe-4d9b-82d2-de953f84d2e6" />

# rst

`rst` is a fast terminal reset for macOS and Linux. When your terminals "breaks", you run `reset`, but it takes a second. `rst` takes 2 milliseconds. 

It repairs the kernel TTY state and emits the terminal's terminfo reset strings, without the 1s sleep that `reset` inherits from 3BSD's `tset(1)`, meant for mechanical printer-and-ink terminals to 'settle down'.

- **Fast**: ~**2ms** vs **~1 second** for `/usr/bin/reset`.
- **Tiny**: 162 KB, smaller than the system `reset` (164 KB) it replaces.
- **Self-contained**: parses the terminfo database itself; links only libc, no ncurses.
- **Compatible**: emits the same reset strings as ncurses `tput reset`, and falls back to VT escapes when no terminfo entry exists (e.g. SSH to an older host).

## What it does

1. **Kernel TTY state.** Restores canonical/cooked input, echo, signals, CR/NL mapping, and output processing. Only repairs *disabled* control characters, preserving user customizations such as an erase key set to `^H` (matching ncurses). Uses `TCSAFLUSH` to discard stale typeahead a crashed raw-mode program may have left in the input queue. Undoes a stuck `^S` / `TCOOFF` via `tcflow(TCOON)` before touching termios, so reset itself can't hang behind stopped output. Refuses to run as a background job (checks `tcgetpgrp`) so it never writes to another job's terminal.
2. **Terminal emulator state.** Reads the terminal's compiled terminfo entry directly (no ncurses dependency) and emits the terminal's reset strings in the same order ncurses `tput reset` uses — `rs1`, `rs2`, `clear_margins`, `rs3`, with each `rsN` falling back to the corresponding `isN` when absent. For known VT-compatible terminals it first sends a small hard-coded cleanup sequence (synchronized output, mouse, focus, paste off), and only when no terminfo entry is found does it use a hard-coded VT fallback. That makes it recover even when a terminfo entry is absent (e.g. SSHing from a newer terminal to an older host).

It locates a TTY on stderr, stdout, stdin (reopened read-write), or `/dev/tty`.

## Examples

Common ways to break your terminal — and how `rst` recovers them. Type `rst` blind (you won't see it, but it will execute) and hit Enter to recover.

| Break command | What it does | rst fixes |
|---|---|---|
| `cat /dev/urandom` | Binary garbage leaves random escape sequences and alternate charset active | ✓ |
| `kill -9 <vim-pid>` | Killed TUI app leaves terminal in raw mode with echo off | ✓ |
| `printf '\e[?1049h'` | Enters alternate screen; scrollback vanishes | ✓ |
| `printf '\e[?25l'` | Hides the cursor | ✓ |
| `printf '\e[8m'` | Invisible (concealed) text | ✓ |
| `printf '\e(0'` | DEC line-drawing charset; text becomes garbage symbols | ✓ |
| `printf '\e[4h'` | Insert mode; typing pushes text right | ✓ |
| `printf '\e[?5h'` | Reverse video | ✓ |
| `stty raw` | Raw mode; line editing dies (use Ctrl-J to submit) | ✓ |
| `printf '\e[3;10;20t'` | Resizes the terminal window (on supporting terminals) | ✓ |
| `printf '\e[r\e[H'` | Resets scroll region and moves cursor home | ✓ |
| `stty -opost -onlcr` | Disables output processing; `ls` columns stairstep | ✓ |
| `printf '\e[?1003h\e[?1006h'` | Enables mouse reporting; clicking/dragging spews escape garbage into your prompt | ✓ |
| `stty -icanon min 1; stty -isig` | Disables canonical mode and signals; Ctrl-C and line editing stop working | ✓ |

## Build

Requires [Zig 0.16.0](https://ziglang.org). No ncurses or other external libraries — `rst` parses the terminfo database itself and links only libc:

```sh
zig build --release
```

The binary is installed to `zig-out/bin/rst`. It links only the system C library (`libSystem` on macOS, `libc` on Linux) — no shared-library dependency on ncurses.

## Install

```sh
zig build --release
install -m 0755 zig-out/bin/rst /usr/local/bin/rst
```

Or put it anywhere earlier on `PATH` than `/usr/bin` to shadow the system `reset`.

## Test

A portable PTY test builds the binary, puts a TTY into a deliberately broken raw/no-echo state, runs `rst`, and verifies that canonical mode and echo were restored:

```sh
zig build test
python3 scripts/pty-test.py zig-out/bin/rst
```

The unit suite includes a seed corpus for the terminfo parser. On architectures supported by Zig's native fuzzer (including CI's x86_64 Linux runner), run 100,000 fuzz iterations with `zig build test -Drelease --fuzz=100K`.

## Prior art

The mechanism is established prior art; `rst` is a polished, cross-platform Zig package, not the first fast reset.

- **BusyBox `reset`** — a ~676-byte applet that emits fixed reset escapes, runs `stty sane`, and performs no settling sleep. ([console-tools/reset.c](https://github.com/mirror/busybox/blob/master/console-tools/reset.c))
- **Toybox `reset`** — the closest philosophical match. Its source says: *"In 1979 3BSD's tset had a sleep(1) to let mechanical printer-and-ink terminals 'settle down'. We're not doing that."* ([toys/other/reset.c](https://github.com/landley/toybox/blob/master/toys/other/reset.c), [2015 introduction](https://github.com/landley/toybox/commit/5b2644cafc8a619b617ba0fbb5473667dbd634ba), [2023 cooked-mode fix](https://github.com/landley/toybox/commit/d93384a1050919c093ffa2532e88e7371db9ac33))
- **ncurses `tput reset`** — upstream ncurses moved the terminal-mode part of `reset` into `tput reset` in [2016](https://github.com/mirror/ncurses/commit/29a36e53e1f77a0c3672f2e267d573823d6a9a60) and refined it in [2017](https://github.com/mirror/ncurses/commit/58552e8c767a70f8f0bd591fecdf576fa8216e3e), without `tset`'s hardware-settling wait. ([tput(1)](https://invisible-island.net/ncurses/man/tput.1.html))

A no-code fast alternative on any system with ncurses is:

```sh
reset -I && tput reset
```

`rst` packages the same idea into a single dependency-free standalone binary — it reads the terminfo database itself rather than linking ncurses.

## Differences from ncurses

The reset work `rst` performs is the same mechanism as ncurses `reset` / `tput reset` (both funnel into ncurses' `progs/reset_cmd.c`), minus the legacy sleep. For completeness, the exact, deliberate differences — verified against the ncurses source — are:

- **The settling sleep is removed.** `/usr/bin/reset` calls `napms(1000)` after emitting the reset strings (`tset.c`), a hardware-settling delay retained from 3BSD for mechanical terminals. `tput reset` never had it. `rst` matches `tput reset`: no sleep.
- **No tabstop reprogramming.** Between `rs2` and `rs3`, ncurses' `reset_tabstops` clears and re-sets hardware tab stops using the `init_tabs`, `clear_all_tabs`, and `set_tab` capabilities. `rst` omits this; terminal emulators do not use hardware tabs, so it is dead work there. This matters only for a real terminal with non-default tab stops.
- **No `reset_file`/`init_file`.** ncurses can `cat` a per-terminal initialization file named by the `rf`/`if` capability. `rst` does not read or emit arbitrary files during reset.
- **No alternate margin fallback.** If `clear_margins` (`mgc`) is absent, ncurses falls back to `set_lr_margin` / `set_left_margin`+`set_right_margin` (and a space-fill when only the latter pair exists). `rst` sends `mgc` only; on a terminal lacking `mgc` it clears no margins.
- **VT cleanup prelude is extra.** For known VT-compatible terminals `rst` first sends a short sequence to disable synchronized output, mouse reporting, focus events, and bracketed paste. ncurses does not do this; it relies on the terminfo strings alone.
- **Missing-entry fallback is extra.** When no terminfo entry exists, ncurses aborts; `rst` instead emits a fixed VT reset sequence so a terminal emulator can still be recovered (common when SSHing to an older host).
- **Simpler padding handling.** `rst` removes terminfo `$<delay>` markers instead of sleeping or emitting pad bytes scaled to baud rate the way `tputs` does. Terminal emulators process output instantly; this only affects physical serial terminals.

The one behavioral difference that matters for the common case is the removed settling delay. For a real serial or physical terminal where the delay, tabstops, or margin fallbacks matter, use `/usr/bin/reset`.

## Benchmark

Measured on macOS 26.6 / arm64 (Apple Silicon) in a pseudo-TTY harness. Absolute numbers vary by machine and harness overhead; the intentional one-second delay dominates the conclusion.

```text
/usr/bin/reset:     1012 ms   (napms(1000) settling sleep)
/usr/bin/reset -I:     2.7 ms  (TTY repair only, skips the sleep)
/usr/bin/tput reset:   3.2 ms
rst:                  1.9 ms
```

`rst` is the fastest of the variants — dropping the ncurses dependency eliminates library initialization overhead — and ~530× faster than `/usr/bin/reset` for the common terminal-emulator case.

## Status

CI builds and runs the PTY test on macOS arm64 and Linux x86_64. Tagged releases publish binaries for macOS and Linux on arm64 and x86_64; Linux binaries are statically linked, while macOS binaries link only the system `libSystem`.

## License

Apache-2.0. See [LICENSE](LICENSE).
