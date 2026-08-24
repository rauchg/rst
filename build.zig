const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
        .single_threaded = true,
    });

    // rst reads the compiled terminfo database itself (src/terminfo.zig) and
    // has no ncurses dependency — only libc for termios/syscalls.

    const exe = b.addExecutable(.{
        .name = "rst",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run rst on the current terminal");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(main_tests).step);

    const terminfo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/terminfo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // Zig's native fuzzer requires the LLVM backend; unsupported architectures
    // still execute the seed corpus as ordinary unit tests.
    terminfo_tests.use_llvm = true;
    test_step.dependOn(&b.addRunArtifact(terminfo_tests).step);
}
