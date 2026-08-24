#!/usr/bin/env python3
# Portable PTY test for rst.
#
# Spawns a child inside a pseudo-terminal, puts the TTY into a deliberately
# broken raw/no-echo state, runs the freshly built rst binary, and verifies
# that the kernel termios state was repaired (canonical mode + echo restored).
# Exercises the real code path the tool is built for; does not benchmark.
#
# Usage: scripts/pty-test.py [path/to/rst]
#
# Licensed under the Apache License, Version 2.0.

import os
import pty
import subprocess
import sys
import termios

CANON = termios.ICANON
ECHO = termios.ECHO


def child_main(rst_path):
    # Deliberately break the controlling terminal: raw, no echo, no signals.
    fd = os.open(os.ctermid(), os.O_RDWR)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0  # c_iflag
    attrs[1] = 0  # c_oflag
    attrs[3] = 0  # c_lflag: drop ICANON | ECHO | ISIG
    attrs[6] = [0] * len(attrs[6])  # c_cc
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    # Sanity check: confirm we actually broke it.
    broken = termios.tcgetattr(fd)
    assert not (broken[3] & CANON), "setup failed: ICANON still set"
    assert not (broken[3] & ECHO), "setup failed: ECHO still set"

    # Run rst. It should repair the TTY and exit 0. Set TERM explicitly:
    # CI runners often have TERM unset or pointing at a missing terminfo entry.
    env = os.environ.copy()
    env["TERM"] = "xterm-256color"
    result = subprocess.run(
        [rst_path],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        # Restore before we die so the test terminal is not left broken.
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        os.close(fd)
        print("FAIL: rst exited non-zero", file=sys.stderr)
        sys.exit(1)

    # Verify rst repaired the kernel TTY state.
    repaired = termios.tcgetattr(fd)
    ok = bool(repaired[3] & CANON) and bool(repaired[3] & ECHO)
    os.close(fd)
    if not ok:
        print("FAIL: rst did not restore ICANON+ECHO", file=sys.stderr)
        sys.exit(1)
    print("OK: rst restored canonical mode and echo")
    sys.exit(0)


def main():
    rst_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join("zig-out", "bin", "rst")
    if not os.path.exists(rst_path):
        print(f"FAIL: rst binary not found at {rst_path}", file=sys.stderr)
        sys.exit(2)

    pid, fd = pty.fork()
    if pid == 0:
        child_main(rst_path)
        return

    # Parent: read whatever the child writes (reset escapes etc.), wait.
    try:
        while True:
            data = os.read(fd, 4096)
            if not data:
                break
    except OSError:
        pass

    _, status = os.waitpid(pid, 0)
    rc = os.waitstatus_to_exitcode(status)
    if rc != 0:
        print(f"FAIL: child exited {rc}", file=sys.stderr)
        sys.exit(rc)
    # Restore the parent's own terminal in case reset escapes leaked.
    print("pty test passed")


if __name__ == "__main__":
    main()
