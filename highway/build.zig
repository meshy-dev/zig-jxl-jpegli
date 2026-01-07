//! Zig build for Google's Highway SIMD library
//!
//! Highway provides portable SIMD with runtime dispatch. The library automatically
//! detects CPU capabilities and uses the best available instruction set.
//!
//! Based on upstream CMake build system.
//! Source: https://github.com/google/highway/blob/master/CMakeLists.txt

const std = @import("std");
const Build = std.Build;
const Dependency = Build.Dependency;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("highway", .{});

    const hwy_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    hwy_mod.addIncludePath(upstream.path(""));
    hwy_mod.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &hwy_sources,
        .flags = &cxx_flags,
    });
    hwy_mod.addCMacro("HWY_STATIC_DEFINE", "1");

    const hwy = b.addLibrary(.{
        .name = "hwy",
        .linkage = .static,
        .root_module = hwy_mod,
    });

    hwy.installHeadersDirectory(upstream.path("hwy"), "hwy", .{
        .include_extensions = &.{".h"},
    });

    b.installArtifact(hwy);
}

const cxx_flags = [_][]const u8{
    "-std=c++17",
    "-fPIC",
    "-fno-exceptions",
    "-fno-rtti",
    "-Wall",
    "-Wno-builtin-macro-redefined",
    "-D__DATE__=\"redacted\"",
    "-D__TIMESTAMP__=\"redacted\"",
    "-D__TIME__=\"redacted\"",
};

const hwy_sources = [_][]const u8{
    "hwy/abort.cc",
    "hwy/aligned_allocator.cc",
    "hwy/nanobenchmark.cc",
    "hwy/per_target.cc",
    "hwy/print.cc",
    "hwy/targets.cc",
    "hwy/timer.cc",
};
