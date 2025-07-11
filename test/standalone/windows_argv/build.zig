const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    if (builtin.os.tag != .windows) return;

    const optimize: std.builtin.OptimizeMode = .Debug;

    const lib_gnu = b.addLibrary(.{
        .linkage = .static,
        .name = "toargv-gnu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib.zig"),
            .target = b.resolveTargetQuery(.{
                .abi = .gnu,
            }),
            .optimize = optimize,
        }),
    });
    const verify_gnu = b.addExecutable(.{
        .name = "verify-gnu",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = b.resolveTargetQuery(.{
                .abi = .gnu,
            }),
            .optimize = optimize,
        }),
    });
    verify_gnu.root_module.addCSourceFile(.{
        .file = b.path("verify.c"),
        .flags = &.{ "-DUNICODE", "-D_UNICODE" },
    });
    verify_gnu.mingw_unicode_entry_point = true;
    verify_gnu.root_module.linkLibrary(lib_gnu);
    verify_gnu.root_module.link_libc = true;

    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    fuzz.root_module.linkSystemLibrary("advapi32", .{});

    const fuzz_max_iterations = b.option(u64, "iterations", "The max fuzz iterations (default: 100)") orelse 100;
    const fuzz_iterations_arg = std.fmt.allocPrint(b.allocator, "{}", .{fuzz_max_iterations}) catch @panic("oom");

    const fuzz_seed = b.option(u64, "seed", "Seed to use for the PRNG (default: random)") orelse seed: {
        var buf: [8]u8 = undefined;
        try std.posix.getrandom(&buf);
        break :seed std.mem.readInt(u64, &buf, builtin.cpu.arch.endian());
    };
    const fuzz_seed_arg = std.fmt.allocPrint(b.allocator, "{}", .{fuzz_seed}) catch @panic("oom");

    const run_gnu = b.addRunArtifact(fuzz);
    run_gnu.setName("fuzz-gnu");
    run_gnu.addArtifactArg(verify_gnu);
    run_gnu.addArgs(&.{ fuzz_iterations_arg, fuzz_seed_arg });
    run_gnu.expectExitCode(0);

    test_step.dependOn(&run_gnu.step);

    // Only target the MSVC ABI if MSVC/Windows SDK is available
    const has_msvc = has_msvc: {
        const sdk = std.zig.WindowsSdk.find(b.allocator, builtin.cpu.arch) catch |err| switch (err) {
            error.OutOfMemory => @panic("oom"),
            else => break :has_msvc false,
        };
        defer sdk.free(b.allocator);
        break :has_msvc true;
    };
    if (has_msvc) {
        const lib_msvc = b.addLibrary(.{
            .linkage = .static,
            .name = "toargv-msvc",
            .root_module = b.createModule(.{
                .root_source_file = b.path("lib.zig"),
                .target = b.resolveTargetQuery(.{
                    .abi = .msvc,
                }),
                .optimize = optimize,
            }),
        });
        const verify_msvc = b.addExecutable(.{
            .name = "verify-msvc",
            .root_module = b.createModule(.{
                .root_source_file = null,
                .target = b.resolveTargetQuery(.{
                    .abi = .msvc,
                }),
                .optimize = optimize,
            }),
        });
        verify_msvc.root_module.addCSourceFile(.{
            .file = b.path("verify.c"),
            .flags = &.{ "-DUNICODE", "-D_UNICODE" },
        });
        verify_msvc.root_module.linkLibrary(lib_msvc);
        verify_msvc.root_module.link_libc = true;

        const run_msvc = b.addRunArtifact(fuzz);
        run_msvc.setName("fuzz-msvc");
        run_msvc.addArtifactArg(verify_msvc);
        run_msvc.addArgs(&.{ fuzz_iterations_arg, fuzz_seed_arg });
        run_msvc.expectExitCode(0);

        test_step.dependOn(&run_msvc.step);
    }
}
