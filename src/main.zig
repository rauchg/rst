// rst — a fast terminal reset.
//
// Restores sane kernel TTY state and emits the terminal's terminfo reset
// strings, without the one-second hardware-settling sleep inherited from
// 3BSD's tset(1). See README.md for the rationale and prior art.
//
// Licensed under the Apache License, Version 2.0.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
    if (builtin.target.os.tag == .macos) {
        @cInclude("sys/ttydefaults.h");
    }
});

const terminfo = @import("terminfo.zig");

// Escape sequences not consistently covered by older terminfo entries. Only
// send these for known VT-compatible terminals; terminfo handles the reset.
const vt_cleanup_sequence =
    "\x1b[?2026l" ++ // synchronized output off
    "\x1b[?1000;1002;1003;1004;1006;2004l"; // mouse, focus, paste off

const vt_fallback_sequence =
    "\x1bc" ++ // RIS: reset terminal state
    "\x1b[!p" ++ // DECSTR: soft terminal reset
    "\x1b[?3;4l" ++ // 80 columns, smooth scrolling off
    "\x1b[4l" ++ // insert mode off
    "\x1b>" ++ // normal numeric keypad
    "\x1b(B" ++ // ASCII in the G0 character set
    "\x1b[?7h" ++ // wraparound on
    "\x1b[0m" ++ // default rendition
    "\x1b[?25h"; // cursor visible

const Tty = struct {
    fd: c_int,
    owned: bool,
};

pub fn main() u8 {
    run() catch |err| {
        // A background job must not modify or write to another job's terminal.
        // Stay silent because even diagnostics can trigger SIGTTOU with TOSTOP.
        if (err != error.NotForegroundProcess)
            std.debug.print("rst: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run() !void {
    const tty = findTty() orelse return error.NoTerminal;
    defer {
        if (tty.owned) _ = c.close(tty.fd);
    }

    const foreground = c.tcgetpgrp(tty.fd);
    if (foreground >= 0 and foreground != c.getpgrp())
        return error.NotForegroundProcess;

    // Undo a literal ^S or an explicit TCOOFF before using a draining termios
    // update. Otherwise reset itself can wait behind stopped terminal output.
    while (c.tcflow(tty.fd, c.TCOON) != 0) {
        if (errno() != c.EINTR) return error.ResumeOutputFailed;
    }

    var mode: c.struct_termios = undefined;
    while (c.tcgetattr(tty.fd, &mode) != 0) {
        if (errno() != c.EINTR) return error.GetTerminalStateFailed;
    }

    // Restore the terminal-driver properties that commonly make a crashed TUI
    // look broken: canonical input, echo, signals, CR/NL mapping, and output.
    mode.c_iflag &= ~@as(
        c.tcflag_t,
        c.IGNBRK | c.PARMRK | c.INPCK | c.ISTRIP | c.INLCR | c.IGNCR | c.IXOFF | c.IXANY,
    );
    mode.c_iflag |= c.BRKINT | c.IGNPAR | c.ICRNL | c.IXON | c.IMAXBEL;

    mode.c_oflag &= ~@as(
        c.tcflag_t,
        c.OCRNL | c.ONOCR | c.ONLRET | c.OFILL | c.OFDEL |
            c.NLDLY | c.CRDLY | c.TABDLY | c.BSDLY | c.VTDLY | c.FFDLY,
    );
    mode.c_oflag |= c.OPOST | c.ONLCR;

    mode.c_cflag &= ~@as(c.tcflag_t, c.CSIZE | c.PARENB | c.PARODD | c.CSTOPB | c.CLOCAL);
    mode.c_cflag |= c.CS8 | c.CREAD;

    mode.c_lflag &= ~(@as(c.tcflag_t, c.ECHONL) |
        @as(c.tcflag_t, c.NOFLSH) |
        @as(c.tcflag_t, c.TOSTOP) |
        @as(c.tcflag_t, c.ECHOPRT) |
        @as(c.tcflag_t, c.FLUSHO) |
        @as(c.tcflag_t, c.PENDIN) |
        @as(c.tcflag_t, c.EXTPROC));
    mode.c_lflag |= c.ISIG | c.ICANON | c.IEXTEN | c.ECHO | c.ECHOE | c.ECHOK | c.ECHOKE | c.ECHOCTL;

    // Match ncurses: only repair disabled control characters. Preserve valid
    // user customizations such as an erase key set to ^H. The defaults come
    // from the platform's ttydefaults: BSD/macOS exposes the C* macros via
    // sys/ttydefaults.h; glibc does not, so we use the standard POSIX values.
    repairChar(&mode, c.VEOF, ccDefault(.eof));
    repairChar(&mode, c.VERASE, ccDefault(.erase));
    repairChar(&mode, c.VWERASE, ccDefault(.werase));
    repairChar(&mode, c.VKILL, ccDefault(.kill));
    repairChar(&mode, c.VREPRINT, ccDefault(.reprint));
    repairChar(&mode, c.VINTR, ccDefault(.intr));
    repairChar(&mode, c.VQUIT, ccDefault(.quit));
    repairChar(&mode, c.VSUSP, ccDefault(.susp));
    repairChar(&mode, c.VSTART, ccDefault(.start));
    repairChar(&mode, c.VSTOP, ccDefault(.stop));
    repairChar(&mode, c.VLNEXT, ccDefault(.lnext));
    repairChar(&mode, c.VDISCARD, ccDefault(.discard));
    if (comptime builtin.target.os.tag.isDarwin()) {
        repairChar(&mode, c.VDSUSP, c.CDSUSP);
        repairChar(&mode, c.VSTATUS, c.CSTATUS);
    }

    // Toybox uses TCSAFLUSH for crash recovery, discarding stale typeahead that
    // a raw-mode application may have left in the input queue.
    while (c.tcsetattr(tty.fd, c.TCSAFLUSH, &mode) != 0) {
        if (errno() != c.EINTR) return error.SetTerminalStateFailed;
    }

    try resetDisplay(tty.fd);
}

fn resetDisplay(fd: c_int) !void {
    const term = std.mem.span(c.getenv("TERM") orelse return error.TermNotSet);
    const vt_compatible = isVtCompatible(term);

    if (vt_compatible) try writeAll(fd, vt_cleanup_sequence);

    // Parse the terminal's compiled terminfo entry ourselves, avoiding the
    // ncurses dependency. If no entry is found, a known VT emulator can still
    // be recovered with a fixed escape sequence (common when SSHing from a
    // newer terminal to an older host whose terminfo DB lacks the entry).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entry_buf: std.ArrayList(u8) = .empty;
    const e = terminfo.load(alloc, term, &entry_buf) catch |err| switch (err) {
        error.TerminfoNotFound => {
            if (vt_compatible) return writeAll(fd, vt_fallback_sequence);
            return error.TerminfoNotFound;
        },
        else => return err,
    };

    const caps = try terminfo.resetStrings(e, alloc);

    // Emit the reset strings the way ncurses send_init_strings(use_reset=TRUE)
    // does. For each numbered string ncurses picks rs when present, else is:
    //     (use_reset && reset_Nstring) ? reset_Nstring : init_Nstring
    // so the rs->is fallback is per-string, not all-or-nothing. Between rs2 and
    // rs3 ncurses also clears soft margins (clear_margins), then resets tab
    // stops and cat's reset_file; we clear margins but omit the tabstop and
    // reset_file steps (see README "Differences from ncurses").
    var sent = false;
    if (try emit(fd, caps.rs1, caps.is1)) sent = true;
    if (try emit(fd, caps.rs2, caps.is2)) sent = true;
    if (caps.clear_margins) |s| {
        try writeAll(fd, s);
        sent = true;
    }
    if (try emit(fd, caps.rs3, caps.is3)) sent = true;

    if (!sent and vt_compatible) try writeAll(fd, vt_fallback_sequence);
}

/// Send the reset string if present, else the corresponding init string.
/// Mirrors ncurses' per-string `(use_reset && rs) ? rs : is` selection.
/// Returns true if a string was written.
fn emit(fd: c_int, rs: ?[]const u8, is: ?[]const u8) !bool {
    const s = rs orelse is orelse return false;
    try writeAll(fd, s);
    return true;
}

fn isVtCompatible(term: []const u8) bool {
    const prefixes = [_][]const u8{
        "xterm", "screen", "tmux", "rxvt", "vt", "ansi", "linux", "cygwin", "st", "alacritty", "kitty", "wezterm", "foot", "ghostty",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, term, prefix)) return true;
    }
    return false;
}

fn repairChar(mode: *c.struct_termios, index: usize, default: c.cc_t) void {
    const value = mode.c_cc[index];
    if (value == c._POSIX_VDISABLE or value == 0)
        mode.c_cc[index] = default;
}

/// Standard control-character default values from `ttydefaults.h`. BSD/macOS
/// exposes these as the C* macros (included via sys/ttydefaults.h); glibc does
/// not expose them, so we encode the conventional POSIX values here. The bytes
/// are the ASCII control characters: ^C, ^\, ^D, ^H, ^U, ^W, ^R, ^Q, ^S, ^V, ^O, ^Z.
const CcKind = enum { eof, erase, werase, kill, reprint, intr, quit, susp, start, stop, lnext, discard };

fn ccDefault(kind: CcKind) c.cc_t {
    if (comptime builtin.target.os.tag.isDarwin()) {
        return switch (kind) {
            .eof => c.CEOF,
            .erase => c.CERASE,
            .werase => c.CWERASE,
            .kill => c.CKILL,
            .reprint => c.CREPRINT,
            .intr => c.CINTR,
            .quit => c.CQUIT,
            .susp => c.CSUSP,
            .start => c.CSTART,
            .stop => c.CSTOP,
            .lnext => c.CLNEXT,
            .discard => c.CDISCARD,
        };
    } else {
        return switch (kind) {
            .eof => 0o4, // ^D
            .erase => 0o177, // DEL (glibc default; ^H is also common)
            .werase => 0o27, // ^W
            .kill => 0o25, // ^U
            .reprint => 0o22, // ^R
            .intr => 0o3, // ^C
            .quit => 0o34, // ^\
            .susp => 0o32, // ^Z
            .start => 0o21, // ^Q
            .stop => 0o23, // ^S
            .lnext => 0o26, // ^V
            .discard => 0o17, // ^O
        };
    }
}

// Portable errno read. Darwin exposes errno through the thread-local `__error()`
// symbol; Linux/glibc exposes the `errno` macro expansion directly.
fn errno() c_int {
    if (comptime builtin.target.os.tag.isDarwin()) {
        return c.__error().*;
    } else {
        return std.c._errno().*;
    }
}

fn findTty() ?Tty {
    // stderr and stdout are normally writable. stdin is often O_RDONLY, so do
    // not select it for both tcsetattr and terminal output.
    const writable = [_]c_int{ c.STDERR_FILENO, c.STDOUT_FILENO };
    for (writable) |fd| {
        if (c.isatty(fd) == 1 and isWritable(fd)) return .{ .fd = fd, .owned = false };
    }

    // If stdin is a TTY but not the controlling terminal, reopen its device
    // read-write instead of attempting to write through a likely O_RDONLY fd.
    if (c.isatty(c.STDIN_FILENO) == 1) {
        var path: [1024]u8 = undefined;
        if (c.ttyname_r(c.STDIN_FILENO, &path, path.len) == 0) {
            const fd = c.open(&path, c.O_RDWR | c.O_NOCTTY);
            if (fd >= 0) return .{ .fd = fd, .owned = true };
        }
    }

    const fd = c.open("/dev/tty", c.O_RDWR | c.O_NOCTTY);
    if (fd >= 0) return .{ .fd = fd, .owned = true };
    return null;
}

fn isWritable(fd: c_int) bool {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0) return false;
    return (flags & c.O_ACCMODE) != c.O_RDONLY;
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const count = c.write(fd, bytes.ptr + written, bytes.len - written);
        if (count < 0) {
            if (errno() == c.EINTR) continue;
            return error.TerminalWriteFailed;
        }
        if (count == 0) return error.TerminalWriteMadeNoProgress;
        written += @intCast(count);
    }
}

test "emit distinguishes an absent capability from a write failure" {
    try std.testing.expect(!try emit(-1, null, null));
    try std.testing.expectError(error.TerminalWriteFailed, emit(-1, "reset", null));
}
