//! Zig build for Google's skcms color management library
//!
//! Based on upstream Bazel/CMake build system.
//! Source: https://skia.googlesource.com/skcms
//!
//! Runtime SIMD dispatch: skcms uses runtime CPU detection to select the best
//! implementation. SIMD variants are compiled with explicit target feature flags
//! via -Xclang, and the library selects the best one at runtime.
//!
//! Note: skcms upstream is vendored via git subtree in upstream/
//! because Zig's package fetcher doesn't support googlesource.com URLs.
//!
//! TODO: When Zig upgrades to LLVM 22+, the evex512 flag becomes unnecessary.

const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const skcms_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    skcms_mod.addIncludePath(b.path("upstream"));
    skcms_mod.addIncludePath(b.path("upstream/src"));
    skcms_mod.addCSourceFiles(.{
        .root = b.path("upstream"),
        .files = &base_sources,
        .flags = &cxx_flags,
    });

    // Add SIMD variants for x86_64 (runtime dispatch)
    addSimdVariants(skcms_mod, b.path("upstream"), target.result.cpu.arch);

    const skcms = b.addLibrary(.{
        .name = "skcms",
        .linkage = .static,
        .root_module = skcms_mod,
    });

    skcms.installHeader(b.path("upstream/skcms.h"), "skcms.h");
    b.installArtifact(skcms);
}

/// Add SIMD variant source files for x86_64.
/// Uses -Xclang -target-feature to enable features without affecting baseline.
pub fn addSimdVariants(mod: *Build.Module, root: Build.LazyPath, arch: std.Target.Cpu.Arch) void {
    if (arch != .x86_64) return;

    // AVX2/Haswell variant
    mod.addCSourceFiles(.{
        .root = root,
        .files = &.{"src/skcms_TransformHsw.cc"},
        .flags = &(cxx_flags ++ avx2_flags),
    });

    // AVX512/Skylake-X variant
    mod.addCSourceFiles(.{
        .root = root,
        .files = &.{"src/skcms_TransformSkx.cc"},
        .flags = &(cxx_flags ++ avx512_flags),
    });
}

// Exported flag arrays for use by main build.zig
pub const cxx_flags = [_][]const u8{
    "-std=c++17",
    "-fPIC",
    "-fno-exceptions",
    "-fno-rtti",
    "-Wall",
    "-Wno-psabi",
};

pub const avx2_flags = [_][]const u8{
    "-Xclang", "-target-feature", "-Xclang", "+avx",
    "-Xclang", "-target-feature", "-Xclang", "+avx2",
    "-Xclang", "-target-feature", "-Xclang", "+f16c",
    "-Xclang", "-target-feature", "-Xclang", "+fma",
};

// TODO: Remove evex512 when Zig upgrades to LLVM 22+
pub const avx512_flags = [_][]const u8{
    "-Xclang", "-target-feature", "-Xclang", "+avx",
    "-Xclang", "-target-feature", "-Xclang", "+avx2",
    "-Xclang", "-target-feature", "-Xclang", "+f16c",
    "-Xclang", "-target-feature", "-Xclang", "+fma",
    "-Xclang", "-target-feature", "-Xclang", "+avx512f",
    "-Xclang", "-target-feature", "-Xclang", "+avx512dq",
    "-Xclang", "-target-feature", "-Xclang", "+avx512cd",
    "-Xclang", "-target-feature", "-Xclang", "+avx512bw",
    "-Xclang", "-target-feature", "-Xclang", "+avx512vl",
    "-Xclang", "-target-feature", "-Xclang", "+evex512",
};

pub const base_sources = [_][]const u8{
    "skcms.cc",
    "src/skcms_TransformBaseline.cc",
};
