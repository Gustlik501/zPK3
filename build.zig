const std = @import("std");

fn addViewerExecutable(
    b: *std.Build,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_artifact = raylib_dep.artifact("raylib");

    const raylib = b.addModule("raylib", .{
        .root_source_file = b.path("vendor/raylib-zig/lib/raylib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.linkLibrary(raylib_artifact);
    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = addViewerExecutable(
        b,
        "quake3_viewer",
        b.path("src/main.zig"),
        target,
        optimize,
    );
    b.installArtifact(exe);

    const build_step = b.step("quake3_viewer_build", "Build the modular Quake 3 PK3 viewer");
    build_step.dependOn(&exe.step);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("quake3_viewer", "Run the modular Quake 3 PK3 viewer");
    run_step.dependOn(&run_cmd.step);

    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    });
    const linux_exe = addViewerExecutable(
        b,
        "quake3_viewer",
        b.path("src/main.zig"),
        linux_target,
        optimize,
    );

    const linux_build_step = b.step(
        "quake3_viewer_build_linux",
        "Cross-build the modular Quake 3 PK3 viewer for Linux x86_64",
    );
    linux_build_step.dependOn(&linux_exe.step);
}
