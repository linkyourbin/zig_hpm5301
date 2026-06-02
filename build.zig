const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .abi = .eabi,
        .ofmt = .elf,
        .cpu_features_add = std.Target.riscv.featureSet(&.{
            .m,
            .a,
            .c,
            .zicsr,
            .zifencei,
        }),
    });

    const exe = b.addExecutable(.{
        .name = "ssd1306_i2c_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .strip = false,
        }),
    });
    exe.entry = .{ .symbol_name = "_start" };
    exe.setLinkerScript(b.path("src/hpm5301_flash_xip.ld"));

    const bin = exe.addObjCopy(.{
        .basename = "ssd1306_i2c_test.bin",
        .format = .bin,
    });

    b.installArtifact(exe);
    b.getInstallStep().dependOn(&b.addInstallBinFile(bin.getOutput(), "ssd1306_i2c_test.bin").step);
}
