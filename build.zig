const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode") orelse .safe;
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    module.addAnonymousImport("LICENSE", .{ .root_source_file = b.path("LICENSE") });
    const exe = b.addExecutable(.{ .name = "ampz", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Open the music library").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
