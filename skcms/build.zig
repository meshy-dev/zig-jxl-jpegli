//! Zig build for Google's skcms color management library
//!
//! Based on upstream Bazel/CMake build system.
//! Source: https://skia.googlesource.com/skcms
//!
//! Note: skcms upstream is vendored via git subtree in upstream/
//! because Zig's package fetcher doesn't support googlesource.com URLs.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const skcms_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Add include path for skcms headers (from upstream subtree)
    skcms_mod.addIncludePath(b.path("upstream"));
    skcms_mod.addIncludePath(b.path("upstream/src"));

    // Check for SIMD support based on target architecture
    const arch = target.result.cpu.arch;
    const is_x86_64 = arch == .x86_64;

    // Add base sources from upstream subtree
    skcms_mod.addCSourceFiles(.{
        .root = b.path("upstream"),
        .files = base_sources,
        .flags = cxx_flags,
    });

    // Add SIMD sources for x86_64 (skcms has internal runtime dispatch)
    if (is_x86_64) {
        skcms_mod.addCSourceFiles(.{
            .root = b.path("upstream"),
            .files = simd_sources,
            .flags = cxx_flags,
        });
    }

    const skcms = b.addLibrary(.{
        .name = "skcms",
        .linkage = .static,
        .root_module = skcms_mod,
    });

    // Install skcms header from upstream subtree
    skcms.installHeader(b.path("upstream/skcms.h"), "skcms.h");

    b.installArtifact(skcms);
}

const cxx_flags: []const []const u8 = &.{
    "-std=c++17",
    "-fPIC",
    "-fno-exceptions",
    "-fno-rtti",
    "-Wall",
    "-Wno-psabi", // Suppress ABI warnings on ARM
};

// Base skcms sources (always included)
// Source: https://skia.googlesource.com/skcms/+/refs/heads/main/BUILD.bazel
const base_sources: []const []const u8 = &.{
    "skcms.cc",
    "src/skcms_TransformBaseline.cc",
};

// SIMD sources for x86_64
const simd_sources: []const []const u8 = &.{
    "src/skcms_TransformHsw.cc",
    "src/skcms_TransformSkx.cc",
};
