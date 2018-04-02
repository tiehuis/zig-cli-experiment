const Builder = @import("std").build.Builder;

pub fn build(b: &Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zig", "src/main.zig");
    exe.setBuildMode(mode);

    exe.setOutputPath("./zig");

    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
}
