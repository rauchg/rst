// terminfo.zig — a minimal reader for the compiled terminfo format.
//
// Reads only what rst needs: the reset/initialization string capabilities
// (rs1/rs2/rs3, falling back to is1/is2/is3). This replaces the ncurses
// setupterm/tigetstr/tputs dependency with ~150 lines that parse the frozen
// terminfo binary format directly.
//
// Format reference: ncurses include/Caps and the terminfo(5) manual. The
// binary layout has been stable since the SVr4 era:
//
//   header:  6 int16 (little-endian) — magic, name-size, #bool, #num,
//            #string-offsets, string-table-size
//   names:   NUL-terminated terminal names, padded to even
//   booleans: #bool bytes, padded to even
//   numbers:  #num * int16 (little-endian; -1 = absent)
//   strings:  #str * int16 offset into the string table (-1 = absent,
//            -2 = canceled)
//   str table: string-table-size bytes, NUL-terminated entries
//
// String capabilities may embed delay padding of the form $<N> or $<N*>,
// optionally with a trailing '/' (to usexon_pad). Physical terminals may need
// delays or pad bytes here; rst targets terminal emulators and removes markers.
//
// Licensed under the Apache License, Version 2.0.

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

/// Wrapper around the C getenv so terminfo.zig stays self-contained.
fn getenv(name: [:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name.ptr);
    if (ptr == null) return null;
    return std.mem.span(ptr);
}

// The terminfo compiled-entry magic numbers.
const magic_standard: u16 = 0o0432; // 0x011A
const magic_extended: u16 = 0o01036; // 0x021E

// Canonical ncurses string-capability indices (stable across all ncurses
// versions; extracted from the libncurses strnames table). We only need the
// reset and initialization strings.
const str_is1: usize = 48;
const str_is2: usize = 49;
const str_is3: usize = 50;
const str_rs1: usize = 122;
const str_rs2: usize = 123;
const str_rs3: usize = 124;
const str_clear_margins: usize = 270; // mgc: clear right and left soft margins

pub const Entry = struct {
    data: []const u8,
    str_table_start: usize,
    str_table_end: usize,
    str_off_table: usize,
    str_count: usize,

    fn getStringRaw(self: Entry, index: usize) !?[]const u8 {
        if (index >= self.str_count) return null;
        const off = std.mem.readInt(i16, self.data[self.str_off_table + index * 2 ..][0..2], .little);
        if (off < 0) return null; // -1 absent, -2 canceled

        const relative: usize = @intCast(off);
        const table_len = self.str_table_end - self.str_table_start;
        if (relative >= table_len) return error.TerminfoBadStringOffset;

        const rest = self.data[self.str_table_start + relative .. self.str_table_end];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.TerminfoUnterminatedString;
        return rest[0..end];
    }

    /// Return a capability with terminfo delay markers removed. The returned
    /// slice may reference the entry data or memory allocated from `allocator`.
    fn getStringExpanded(self: Entry, allocator: std.mem.Allocator, index: usize) !?[]const u8 {
        const raw = try self.getStringRaw(index) orelse return null;
        return try expandPadding(allocator, raw);
    }
};

/// Locate and parse the terminfo entry for `term`. Searches the standard
/// database locations in ncurses' order: $TERMINFO, $HOME/.terminfo, then the
//  system directories. `buf` holds the file contents; the returned Entry
/// references it.
pub fn load(allocator: std.mem.Allocator, term: []const u8, buf: *std.ArrayList(u8)) !Entry {
    if (!isValidTermName(term)) return error.InvalidTermName;

    // 1. $TERMINFO
    if (getenv("TERMINFO")) |ti| {
        if (try tryPath(allocator, buf, ti, term)) |e| return e;
    }

    // 2. $HOME/.terminfo
    if (getenv("HOME")) |home| {
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(allocator);
        try path.appendSlice(allocator, home);
        try path.appendSlice(allocator, "/.terminfo");
        if (try tryPath(allocator, buf, path.items, term)) |e| return e;
    }

    // 3. $TERMINFO_DIRS — colon-separated list of directories
    if (getenv("TERMINFO_DIRS")) |dirs| {
        var it = std.mem.splitScalar(u8, dirs, ':');
        while (it.next()) |dir| {
            const d = if (dir.len == 0) "/usr/share/terminfo" else dir;
            if (try tryPath(allocator, buf, d, term)) |e| return e;
        }
    }

    // 4. System defaults. /usr/share/terminfo is the common Linux/BSD path;
    //    /usr/share/misc/terminfo and /lib/terminfo appear on some systems.
    const sys_dirs = [_][]const u8{
        "/usr/share/terminfo",
        "/usr/share/misc/terminfo",
        "/lib/terminfo",
        "/usr/local/share/terminfo",
    };
    for (sys_dirs) |dir| {
        if (try tryPath(allocator, buf, dir, term)) |e| return e;
    }

    return error.TerminfoNotFound;
}

fn isValidTermName(term: []const u8) bool {
    if (term.len == 0 or term.len > 255) return false;
    for (term) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '+'))
            return false;
    }
    return !std.mem.eql(u8, term, ".") and !std.mem.eql(u8, term, "..");
}

/// Try the two on-disk layouts ncurses uses: a subdirectory named after the
/// first hex char of the term name, and a subdirectory named after the first
/// ASCII char. The hex layout (e.g. /usr/share/terminfo/78/xterm-256color)
/// is the SVr4 convention; the ASCII layout is the older BSD convention.
fn tryPath(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), dir: []const u8, term: []const u8) !?Entry {
    if (term.len == 0) return null;

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(allocator);

    // Hex-first-char subdirectory (SVr4). ncurses uses the first character's
    // byte value as two lowercase hex digits.
    const hex = "0123456789abcdef";
    const sub = [_]u8{ hex[(term[0] >> 4) & 0xf], hex[term[0] & 0xf] };

    try path.appendSlice(allocator, dir);
    try path.append(allocator, '/');
    try path.appendSlice(allocator, &sub);
    try path.append(allocator, '/');
    try path.appendSlice(allocator, term);
    if (loadFile(allocator, buf, path.items)) |e| {
        return e;
    } else |_| {}

    // ASCII-first-char subdirectory (BSD).
    path.clearRetainingCapacity();
    try path.appendSlice(allocator, dir);
    try path.append(allocator, '/');
    try path.appendSlice(allocator, term[0..1]);
    try path.append(allocator, '/');
    try path.appendSlice(allocator, term);
    if (loadFile(allocator, buf, path.items)) |e| {
        return e;
    } else |_| {}

    return null;
}

fn loadFile(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), path: []const u8) !Entry {
    // Open via the C syscall directly (path is absolute). This keeps
    // terminfo.zig independent of the changing std.fs API.
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = c.open(path_z.ptr, c.O_RDONLY);
    if (fd < 0) return error.TerminfoOpenFailed;
    defer _ = c.close(fd);

    const max_entry = 32768; // extended format entries can be up to 32 KB
    buf.clearRetainingCapacity();
    const slice = try buf.addManyAsSlice(allocator, max_entry);
    var total: usize = 0;
    while (total < slice.len) {
        const n = c.read(fd, slice.ptr + total, slice.len - total);
        if (n < 0) {
            if (errno() == c.EINTR) continue;
            return error.TerminfoReadFailed;
        }
        if (n == 0) break;
        total += @intCast(n);
    }
    if (total == slice.len) {
        var extra: [1]u8 = undefined;
        while (true) {
            const n = c.read(fd, &extra, extra.len);
            if (n < 0) {
                if (errno() == c.EINTR) continue;
                return error.TerminfoReadFailed;
            }
            if (n > 0) return error.TerminfoTooLarge;
            break;
        }
    }
    buf.items = buf.items[0..total];
    return parse(buf.items);
}

fn errno() c_int {
    if (comptime builtin.target.os.tag.isDarwin()) {
        return c.__error().*;
    } else {
        return std.c._errno().*;
    }
}

pub fn parse(data: []const u8) !Entry {
    if (data.len < 12) return error.TerminfoTooSmall;
    const magic = std.mem.readInt(u16, data[0..2], .little);
    if (magic != magic_standard and magic != magic_extended) return error.TerminfoBadMagic;

    const name_size = std.mem.readInt(u16, data[2..4], .little);
    const bool_count = std.mem.readInt(u16, data[4..6], .little);
    const num_count = std.mem.readInt(u16, data[6..8], .little);
    const str_off_count = std.mem.readInt(u16, data[8..10], .little);
    const str_table_size = std.mem.readInt(u16, data[10..12], .little);

    // The extended number format (magic 0x021E, ncurses 6.1+) stores numeric
    // capabilities as 32-bit integers instead of 16-bit. The string capability
    // indices are the same in both formats; only the numbers-section width
    // differs, which shifts where the string offset table begins.
    const num_width: usize = if (magic == magic_extended) 4 else 2;

    var off: usize = 12;
    off += name_size;
    if (off % 2 != 0) off += 1; // names padded to even
    off += bool_count;
    if (off % 2 != 0) off += 1; // booleans padded to even
    off += num_count * num_width;
    const str_off_table = off;
    const str_table_start = str_off_table + str_off_count * 2;
    const str_table_end = str_table_start + str_table_size;

    if (str_table_start > data.len or str_table_end > data.len)
        return error.TerminfoTruncated;

    return .{
        .data = data,
        .str_off_table = str_off_table,
        .str_table_start = str_table_start,
        .str_table_end = str_table_end,
        .str_count = str_off_count,
    };
}

/// Remove terminfo $<delay> markers. Terminal emulators do not need physical
/// output delays; the vast majority of reset strings contain no markers.
fn expandPadding(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    // Fast path: no '$' means no padding, return as-is.
    if (std.mem.indexOfScalar(u8, raw, '$') == null) return raw;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '<') {
            // Parse $<N[*][/]> delay. N may be a decimal, possibly with '*'.
            const close = std.mem.indexOfScalarPos(u8, raw, i + 2, '>') orelse {
                // No closing '>'; not a valid delay, emit literally.
                try out.append(allocator, raw[i]);
                i += 1;
                continue;
            };
            const spec = raw[i + 2 .. close];
            // Parse the leading number.
            var num_end: usize = 0;
            while (num_end < spec.len and (spec[num_end] >= '0' and spec[num_end] <= '9' or spec[num_end] == '.')) {
                num_end += 1;
            }
            const num_str = spec[0..num_end];
            const ms = std.fmt.parseFloat(f64, num_str) catch 0;
            const proportional = std.mem.indexOfScalar(u8, spec, '*') != null;

            // For a hard delay (no '*'), emit no padding bytes — a terminal
            // emulator processes output instantly and the delay would just
            // stall. For proportional padding ('*'), tputs emits pad bytes
            // scaled by baud; on a PTY at 9600 baud this rounds to ~0 for the
            // sub-millisecond delays in reset strings. Skip both in practice.
            _ = ms;
            _ = proportional;

            i = close + 1;
            continue;
        }
        try out.append(allocator, raw[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

pub const ResetStrings = struct {
    rs1: ?[]const u8,
    rs2: ?[]const u8,
    rs3: ?[]const u8,
    is1: ?[]const u8,
    is2: ?[]const u8,
    is3: ?[]const u8,
    clear_margins: ?[]const u8,
};

/// Return reset strings with delay markers removed. Slices may reference the
/// entry data or memory allocated from `allocator`.
pub fn resetStrings(e: Entry, allocator: std.mem.Allocator) !ResetStrings {
    return .{
        .rs1 = try e.getStringExpanded(allocator, str_rs1),
        .rs2 = try e.getStringExpanded(allocator, str_rs2),
        .rs3 = try e.getStringExpanded(allocator, str_rs3),
        .is1 = try e.getStringExpanded(allocator, str_is1),
        .is2 = try e.getStringExpanded(allocator, str_is2),
        .is3 = try e.getStringExpanded(allocator, str_is3),
        .clear_margins = try e.getStringExpanded(allocator, str_clear_margins),
    };
}

fn testEntry(data: *[64]u8, string_offset: i16, table: []const u8) !Entry {
    data.* = @splat(0);
    std.mem.writeInt(u16, data[0..2], magic_standard, .little);
    std.mem.writeInt(u16, data[8..10], 1, .little);
    std.mem.writeInt(u16, data[10..12], @intCast(table.len), .little);
    std.mem.writeInt(i16, data[12..14], string_offset, .little);
    @memcpy(data[14 .. 14 + table.len], table);
    return parse(data[0 .. 14 + table.len]);
}

fn fuzzTerminfo(_: void, smith: *std.testing.Smith) !void {
    var input: [32768]u8 = undefined;
    const len = smith.slice(&input);
    const entry = parse(input[0..len]) catch return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = resetStrings(entry, arena.allocator()) catch return;
}

test "fuzz parse and reset strings" {
    try std.testing.fuzz({}, fuzzTerminfo, .{
        .corpus = &.{
            "\x00\x00\x00\x00",
            "\x0c\x00\x00\x00\x1a\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            "\x0c\x00\x00\x00\x1e\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            "\x10\x00\x00\x00\x1a\x01\x00\x00\x00\x00\x01\x00\x02\x00\x00\x00\x78\x00\x00\x00",
        },
    });
}

test "terminal names cannot traverse paths" {
    try std.testing.expect(isValidTermName("xterm-256color"));
    try std.testing.expect(isValidTermName("screen.xterm-256color"));
    try std.testing.expect(!isValidTermName(""));
    try std.testing.expect(!isValidTermName(".."));
    try std.testing.expect(!isValidTermName("../xterm"));
    try std.testing.expect(!isValidTermName("xterm/name"));
    try std.testing.expect(!isValidTermName("xterm name"));
}

test "parse rejects a truncated declared string table" {
    var data: [12]u8 = @splat(0);
    std.mem.writeInt(u16, data[0..2], magic_standard, .little);
    std.mem.writeInt(u16, data[10..12], 1, .little);
    try std.testing.expectError(error.TerminfoTruncated, parse(&data));
}

test "capability rejects an offset outside the string table" {
    var data: [64]u8 = undefined;
    const entry = try testEntry(&data, 2, &.{ 'x', 0 });
    try std.testing.expectError(error.TerminfoBadStringOffset, entry.getStringRaw(0));
}

test "capability requires a terminator inside the string table" {
    var data: [64]u8 = undefined;
    const entry = try testEntry(&data, 0, &.{ 'x', 'y' });
    try std.testing.expectError(error.TerminfoUnterminatedString, entry.getStringRaw(0));
}

test "capability returns a bounded string" {
    var data: [64]u8 = undefined;
    const entry = try testEntry(&data, 0, &.{ 'o', 'k', 0 });
    try std.testing.expectEqualStrings("ok", (try entry.getStringRaw(0)).?);
}
