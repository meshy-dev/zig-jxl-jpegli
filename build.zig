//! Zig build for libjxl + jpegli
//!
//! This build file provides:
//! - libjxl: JPEG XL encoder/decoder library
//! - libjxl_threads: Multi-threaded parallel runner
//! - libjpegli: High-quality JPEG encoder/decoder (libjpeg-compatible)
//! - CLI tools: cjxl, djxl, cjpegli, djpegli
//!
//! Based on upstream CMake build system from https://github.com/libjxl/libjxl

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const strip_cli = b.option(bool, "strip", "Strip debug symbols from CLI binaries (default: true for release builds)") orelse (optimize != .Debug);

    // Check if we can use x86-64-v3 baseline (AVX2+) to reduce binary size
    const use_avx2_baseline = b.option(bool, "avx2-baseline", "Use AVX2 as minimum SIMD baseline, disabling SSE2/SSE3/SSE4 codepaths (reduces binary size)") orelse detectAvx2Baseline(target);

    // Get upstream libjxl source
    const libjxl = b.dependency("libjxl", .{});
    const libjpeg_turbo = b.dependency("libjpeg_turbo", .{});

    // ============== Internal libraries (not installed) ==============

    // Build vendored sub-packages
    const brotli = buildBrotli(b, target, optimize);
    const hwy = buildHighway(b, target, optimize, use_avx2_baseline);
    const skcms = buildSkcms(b, target, optimize);

    // ============== jxl_cms (internal) ==============
    const jxl_cms = buildJxlCms(b, target, optimize, libjxl, hwy, skcms, use_avx2_baseline);

    // ============== libjxl (public) ==============
    const jxl = buildJxl(b, target, optimize, libjxl, hwy, brotli, jxl_cms, use_avx2_baseline);
    b.installArtifact(jxl);

    // ============== libjxl_threads (public) ==============
    const jxl_threads = buildJxlThreads(b, target, optimize, libjxl);
    b.installArtifact(jxl_threads);

    // ============== libjpegli (public) ==============
    const jpegli = buildJpegli(b, target, optimize, libjxl, libjpeg_turbo, hwy, use_avx2_baseline);
    b.installArtifact(jpegli);

    // ============== CLI tools (optional) ==============
    // jxl_extras library (internal, for CLI tools)
    const jxl_extras = buildJxlExtras(b, target, optimize, libjxl, libjpeg_turbo, hwy, jxl, jxl_threads, jpegli, skcms, use_avx2_baseline);

    // jxl_tool library (internal, for CLI tools)
    const jxl_tool = buildJxlTool(b, target, optimize, libjxl, hwy, use_avx2_baseline);

    // cjxl - JXL encoder
    const cjxl = buildCjxl(b, target, optimize, libjxl, jxl, jxl_threads, jxl_extras, jxl_tool, hwy, brotli, jxl_cms, skcms, use_avx2_baseline, strip_cli);
    b.installArtifact(cjxl);

    // djxl - JXL decoder
    const djxl = buildDjxl(b, target, optimize, libjxl, jxl, jxl_threads, jxl_extras, jxl_tool, hwy, brotli, jxl_cms, skcms, use_avx2_baseline, strip_cli);
    b.installArtifact(djxl);

    // cjpegli - JPEG encoder (via jpegli)
    const cjpegli_exe = buildCjpegli(b, target, optimize, libjxl, libjpeg_turbo, jxl_extras, jxl_tool, jpegli, hwy, use_avx2_baseline, strip_cli);
    b.installArtifact(cjpegli_exe);

    // djpegli - JPEG decoder (via jpegli)
    const djpegli_exe = buildDjpegli(b, target, optimize, libjxl, libjpeg_turbo, jxl_extras, jxl_tool, jpegli, hwy, use_avx2_baseline, strip_cli);
    b.installArtifact(djpegli_exe);
}

/// Detect if target CPU supports AVX2 baseline (x86-64-v3 or higher)
fn detectAvx2Baseline(target: std.Build.ResolvedTarget) bool {
    const arch = target.result.cpu.arch;
    if (arch != .x86_64) return false;

    // Check if the target CPU model supports AVX2
    const cpu_model = target.result.cpu.model;
    // x86-64-v3 baseline includes: AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE, XSAVE
    return cpu_model.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2));
}

/// Check if target CPU supports AVX512F
fn targetHasAvx512(target: std.Build.ResolvedTarget) bool {
    if (target.result.cpu.arch != .x86_64) return false;
    return target.result.cpu.model.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx512f));
}

/// Get HWY_DISABLED_TARGETS macro value based on target CPU capabilities
fn getHwyDisabledTargets(target: std.Build.ResolvedTarget, use_avx2_baseline: bool) ?[]const u8 {
    // Highway target constants (from hwy/highway.h):
    // HWY_AVX3_SPR = (1LL << 4)  - AVX512 with FP16
    // HWY_AVX3_ZEN4 = (1LL << 5) - AVX512 for Zen4
    // HWY_AVX3_DL = (1LL << 6)   - AVX512 with VNNI/BF16
    // HWY_AVX3 = (1LL << 7)      - AVX512 F/BW/CD/DQ/VL
    // HWY_SSE4 = (1LL << 11)
    // HWY_SSSE3 = (1LL << 12)
    // HWY_SSE2 = (1LL << 14)

    const has_avx512 = targetHasAvx512(target);
    const avx512_targets = "(HWY_AVX3_SPR | HWY_AVX3_ZEN4 | HWY_AVX3_DL | HWY_AVX3)";
    const sse_targets = "(HWY_SSE2 | HWY_SSSE3 | HWY_SSE4)";

    if (use_avx2_baseline and !has_avx512) {
        // x86-64-v3: disable both SSE (below baseline) and AVX512 (not supported)
        return "(" ++ sse_targets ++ " | " ++ avx512_targets ++ ")";
    } else if (use_avx2_baseline) {
        // x86-64-v4 or higher: only disable SSE (below baseline)
        return sse_targets;
    } else if (!has_avx512) {
        // Generic x86-64 without AVX512: disable AVX512 targets
        return avx512_targets;
    }
    // Full AVX512 support, no targets need to be disabled
    return null;
}

fn buildBrotli(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const brotli_upstream = b.dependency("brotli_upstream", .{});

    const brotli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    brotli_mod.addIncludePath(brotli_upstream.path("c/include"));
    brotli_mod.addCSourceFiles(.{
        .root = brotli_upstream.path("c"),
        .files = brotli_sources,
        .flags = c_flags,
    });

    // Platform-specific defines
    const os_tag = target.result.os.tag;
    if (os_tag == .linux) {
        brotli_mod.addCMacro("OS_LINUX", "1");
    } else if (os_tag == .freebsd) {
        brotli_mod.addCMacro("OS_FREEBSD", "1");
    } else if (os_tag == .macos) {
        brotli_mod.addCMacro("OS_MACOSX", "1");
    }

    const brotli = b.addLibrary(.{
        .name = "brotli",
        .linkage = .static,
        .root_module = brotli_mod,
    });
    return brotli;
}

fn buildHighway(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, use_avx2_baseline: bool) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});

    const hwy_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    hwy_mod.addIncludePath(highway_upstream.path(""));
    hwy_mod.addCSourceFiles(.{
        .root = highway_upstream.path(""),
        .files = hwy_sources,
        .flags = cxx_flags,
    });
    hwy_mod.addCMacro("HWY_STATIC_DEFINE", "1");

    // Configure disabled SIMD targets based on CPU capabilities
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        hwy_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }

    const hwy = b.addLibrary(.{
        .name = "hwy",
        .linkage = .static,
        .root_module = hwy_mod,
    });
    return hwy;
}

fn buildSkcms(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const skcms_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Add include path for skcms headers (vendored via git subtree)
    skcms_mod.addIncludePath(b.path("skcms/upstream"));
    skcms_mod.addIncludePath(b.path("skcms/upstream/src"));

    // Add base sources from upstream subtree
    skcms_mod.addCSourceFiles(.{
        .root = b.path("skcms/upstream"),
        .files = skcms_base_sources,
        .flags = cxx_flags,
    });

    // Add SIMD sources for x86_64
    if (target.result.cpu.arch == .x86_64) {
        // AVX2/Haswell sources (always included for x86_64)
        skcms_mod.addCSourceFiles(.{
            .root = b.path("skcms/upstream"),
            .files = skcms_avx2_sources,
            .flags = cxx_flags,
        });

        // AVX512/Skylake-X sources (only when target supports AVX512)
        if (targetHasAvx512(target)) {
            skcms_mod.addCSourceFiles(.{
                .root = b.path("skcms/upstream"),
                .files = skcms_avx512_sources,
                .flags = cxx_flags,
            });
        } else {
            // Disable SKX code path in skcms when AVX512 is not available
            skcms_mod.addCMacro("SKCMS_DISABLE_SKX", "1");
        }
    }

    const skcms = b.addLibrary(.{
        .name = "skcms",
        .linkage = .static,
        .root_module = skcms_mod,
    });
    return skcms;
}

fn buildJxlCms(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
    hwy: *std.Build.Step.Compile,
    skcms: *std.Build.Step.Compile,
    use_avx2_baseline: bool,
) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});

    const jxl_cms_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Include paths - libjxl uses "lib/..." includes so we need the repo root
    jxl_cms_mod.addIncludePath(libjxl.path("")); // Repo root for "lib/..." includes
    jxl_cms_mod.addIncludePath(libjxl.path("lib"));
    jxl_cms_mod.addIncludePath(libjxl.path("lib/include"));
    jxl_cms_mod.addIncludePath(b.path("")); // For generated headers
    jxl_cms_mod.addIncludePath(b.path("skcms/upstream"));
    jxl_cms_mod.addIncludePath(highway_upstream.path("")); // Highway headers

    // Add highway include from artifact
    jxl_cms_mod.linkLibrary(hwy);
    jxl_cms_mod.linkLibrary(skcms);

    // Compile flags and macros
    jxl_cms_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    jxl_cms_mod.addCMacro("JPEGXL_ENABLE_SKCMS", "1");
    jxl_cms_mod.addCMacro("JXL_STATIC_DEFINE", "1");
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        jxl_cms_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }

    jxl_cms_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_cms_sources,
        .flags = cxx_flags,
    });

    const jxl_cms = b.addLibrary(.{
        .name = "jxl_cms",
        .linkage = .static,
        .root_module = jxl_cms_mod,
    });

    return jxl_cms;
}

fn buildJxl(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
    hwy: *std.Build.Step.Compile,
    brotli: *std.Build.Step.Compile,
    jxl_cms: *std.Build.Step.Compile,
    use_avx2_baseline: bool,
) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});
    const brotli_upstream = b.dependency("brotli_upstream", .{});

    const jxl_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Include paths - libjxl uses "lib/..." includes so we need the repo root
    jxl_mod.addIncludePath(libjxl.path("")); // Repo root for "lib/..." includes
    jxl_mod.addIncludePath(libjxl.path("lib"));
    jxl_mod.addIncludePath(libjxl.path("lib/include"));
    jxl_mod.addIncludePath(b.path("")); // For generated headers
    jxl_mod.addIncludePath(b.path("skcms/upstream"));
    jxl_mod.addIncludePath(highway_upstream.path("")); // Highway headers
    jxl_mod.addIncludePath(brotli_upstream.path("c/include")); // Brotli headers

    // Link dependencies
    jxl_mod.linkLibrary(hwy);
    jxl_mod.linkLibrary(brotli);
    jxl_mod.linkLibrary(jxl_cms);

    // Compile flags and macros
    jxl_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    jxl_mod.addCMacro("JPEGXL_ENABLE_SKCMS", "1");
    jxl_mod.addCMacro("JXL_STATIC_DEFINE", "1");
    jxl_mod.addCMacro("JXL_INTERNAL_LIBRARY_BUILD", "1");
    jxl_mod.addCMacro("JPEGXL_ENABLE_TRANSCODE_JPEG", "0");
    jxl_mod.addCMacro("JPEGXL_ENABLE_BOXES", "0");
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        jxl_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }
    // Disable AVX512 in fast lossless encoder when target doesn't support it
    if (!targetHasAvx512(target)) {
        jxl_mod.addCMacro("FJXL_ENABLE_AVX512", "0");
    }

    // Add decoder sources
    jxl_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_dec_sources,
        .flags = cxx_flags,
    });

    // Add encoder sources
    jxl_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_enc_sources,
        .flags = cxx_flags,
    });

    const jxl = b.addLibrary(.{
        .name = "jxl",
        .linkage = .static,
        .root_module = jxl_mod,
    });

    // Install public headers
    jxl.installHeader(b.path("jxl/version.h"), "jxl/version.h");
    jxl.installHeader(b.path("jxl/jxl_export.h"), "jxl/jxl_export.h");
    jxl.installHeadersDirectory(libjxl.path("lib/include/jxl"), "jxl", .{
        .include_extensions = &.{".h"},
        .exclude_extensions = &.{"_cxx.h"}, // Exclude C++ wrapper headers for now
    });

    return jxl;
}

fn buildJxlThreads(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const jxl_threads_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Include paths - libjxl uses "lib/..." includes so we need the repo root
    jxl_threads_mod.addIncludePath(libjxl.path("")); // Repo root for "lib/..." includes
    jxl_threads_mod.addIncludePath(libjxl.path("lib"));
    jxl_threads_mod.addIncludePath(libjxl.path("lib/include"));
    jxl_threads_mod.addIncludePath(b.path("")); // For generated headers

    // Compile flags and macros
    jxl_threads_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    jxl_threads_mod.addCMacro("JXL_STATIC_DEFINE", "1");
    jxl_threads_mod.addCMacro("JXL_THREADS_INTERNAL_LIBRARY_BUILD", "1");

    jxl_threads_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_threads_sources,
        .flags = cxx_flags,
    });

    const jxl_threads = b.addLibrary(.{
        .name = "jxl_threads",
        .linkage = .static,
        .root_module = jxl_threads_mod,
    });

    // Install public headers
    jxl_threads.installHeader(b.path("jxl/jxl_threads_export.h"), "jxl/jxl_threads_export.h");
    jxl_threads.installHeader(libjxl.path("lib/include/jxl/thread_parallel_runner.h"), "jxl/thread_parallel_runner.h");
    jxl_threads.installHeader(libjxl.path("lib/include/jxl/resizable_parallel_runner.h"), "jxl/resizable_parallel_runner.h");

    return jxl_threads;
}

fn buildJpegli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
    libjpeg_turbo: *std.Build.Dependency,
    hwy: *std.Build.Step.Compile,
    use_avx2_baseline: bool,
) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});

    const jpegli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Include paths - libjxl uses "lib/..." includes so we need the repo root
    jpegli_mod.addIncludePath(libjxl.path("")); // Repo root for "lib/..." includes
    jpegli_mod.addIncludePath(libjxl.path("lib"));
    jpegli_mod.addIncludePath(libjxl.path("lib/include")); // For jxl/types.h
    jpegli_mod.addIncludePath(libjpeg_turbo.path(""));
    jpegli_mod.addIncludePath(b.path("")); // For jconfig.h
    jpegli_mod.addIncludePath(highway_upstream.path("")); // Highway headers

    // Link highway
    jpegli_mod.linkLibrary(hwy);

    // Compile flags and macros
    jpegli_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        jpegli_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }

    jpegli_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jpegli_sources,
        .flags = cxx_flags,
    });

    const jpegli = b.addLibrary(.{
        .name = "jpegli",
        .linkage = .static,
        .root_module = jpegli_mod,
    });

    // Install libjpeg-compatible headers
    jpegli.installHeader(b.path("jconfig.h"), "jconfig.h");
    jpegli.installHeader(libjpeg_turbo.path("jpeglib.h"), "jpeglib.h");
    jpegli.installHeader(libjpeg_turbo.path("jmorecfg.h"), "jmorecfg.h");
    jpegli.installHeader(libjpeg_turbo.path("jerror.h"), "jerror.h");

    return jpegli;
}

fn buildJxlExtras(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
    libjpeg_turbo: *std.Build.Dependency,
    hwy: *std.Build.Step.Compile,
    jxl: *std.Build.Step.Compile,
    jxl_threads: *std.Build.Step.Compile,
    jpegli: *std.Build.Step.Compile,
    skcms: *std.Build.Step.Compile,
    use_avx2_baseline: bool,
) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});

    const jxl_extras_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Include paths
    jxl_extras_mod.addIncludePath(libjxl.path("")); // Repo root
    jxl_extras_mod.addIncludePath(libjxl.path("lib"));
    jxl_extras_mod.addIncludePath(libjxl.path("lib/include"));
    jxl_extras_mod.addIncludePath(libjpeg_turbo.path(""));
    jxl_extras_mod.addIncludePath(b.path("")); // For generated headers
    jxl_extras_mod.addIncludePath(b.path("skcms/upstream"));
    jxl_extras_mod.addIncludePath(highway_upstream.path("")); // Highway headers

    // Link dependencies
    jxl_extras_mod.linkLibrary(hwy);
    jxl_extras_mod.linkLibrary(jxl);
    jxl_extras_mod.linkLibrary(jxl_threads);
    jxl_extras_mod.linkLibrary(jpegli);
    jxl_extras_mod.linkLibrary(skcms);

    // Compile flags and macros
    jxl_extras_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    jxl_extras_mod.addCMacro("JXL_STATIC_DEFINE", "1");
    jxl_extras_mod.addCMacro("JPEGXL_ENABLE_SKCMS", "1");
    // Enable jpegli codec
    jxl_extras_mod.addCMacro("JPEGXL_ENABLE_JPEGLI", "1");
    // Disable codecs we don't have dependencies for
    jxl_extras_mod.addCMacro("JPEGXL_ENABLE_APNG", "0");
    jxl_extras_mod.addCMacro("JPEGXL_ENABLE_GIF", "0");
    jxl_extras_mod.addCMacro("JPEGXL_ENABLE_JPEG", "0");
    jxl_extras_mod.addCMacro("JPEGXL_ENABLE_EXR", "0");
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        jxl_extras_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }

    // Core extras sources
    jxl_extras_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_extras_sources,
        .flags = cxx_flags,
    });

    // Extras for tools
    jxl_extras_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_extras_for_tools_sources,
        .flags = cxx_flags,
    });

    // PNM codec (no dependencies)
    jxl_extras_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_codec_pnm_sources,
        .flags = cxx_flags,
    });

    // PGX codec (no dependencies)
    jxl_extras_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_codec_pgx_sources,
        .flags = cxx_flags,
    });

    // JXL codec (no dependencies)
    jxl_extras_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_codec_jxl_sources,
        .flags = cxx_flags,
    });

    // NPY codec (no dependencies)
    jxl_extras_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_codec_npy_sources,
        .flags = cxx_flags,
    });

    // jpegli codec
    jxl_extras_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_codec_jpegli_sources,
        .flags = cxx_flags,
    });

    // Stub codecs (these compile to stubs when JPEGXL_ENABLE_*=0)
    jxl_extras_mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = jxl_codec_stub_sources,
        .flags = cxx_flags,
    });

    const jxl_extras = b.addLibrary(.{
        .name = "jxl_extras",
        .linkage = .static,
        .root_module = jxl_extras_mod,
    });

    return jxl_extras;
}

fn buildJxlTool(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
    hwy: *std.Build.Step.Compile,
    use_avx2_baseline: bool,
) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});

    const jxl_tool_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Include paths
    jxl_tool_mod.addIncludePath(libjxl.path("")); // Repo root
    jxl_tool_mod.addIncludePath(libjxl.path("lib"));
    jxl_tool_mod.addIncludePath(libjxl.path("lib/include"));
    jxl_tool_mod.addIncludePath(b.path("")); // For generated headers
    jxl_tool_mod.addIncludePath(highway_upstream.path("")); // Highway headers

    // Link dependencies
    jxl_tool_mod.linkLibrary(hwy);

    // Compile flags
    jxl_tool_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    jxl_tool_mod.addCMacro("JXL_STATIC_DEFINE", "1");
    jxl_tool_mod.addCMacro("JPEGXL_VERSION", "\"0.12.0\"");
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        jxl_tool_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }

    jxl_tool_mod.addCSourceFiles(.{
        .root = libjxl.path("tools"),
        .files = jxl_tool_sources,
        .flags = cxx_flags,
    });

    const jxl_tool = b.addLibrary(.{
        .name = "jxl_tool",
        .linkage = .static,
        .root_module = jxl_tool_mod,
    });

    return jxl_tool;
}

fn buildCjxl(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
    jxl: *std.Build.Step.Compile,
    jxl_threads: *std.Build.Step.Compile,
    jxl_extras: *std.Build.Step.Compile,
    jxl_tool: *std.Build.Step.Compile,
    hwy: *std.Build.Step.Compile,
    brotli: *std.Build.Step.Compile,
    jxl_cms: *std.Build.Step.Compile,
    skcms: *std.Build.Step.Compile,
    use_avx2_baseline: bool,
    strip: bool,
) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});

    const cjxl_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = strip,
    });

    cjxl_mod.addIncludePath(libjxl.path(""));
    cjxl_mod.addIncludePath(libjxl.path("lib"));
    cjxl_mod.addIncludePath(libjxl.path("lib/include"));
    cjxl_mod.addIncludePath(b.path(""));
    cjxl_mod.addIncludePath(b.path("skcms/upstream"));
    cjxl_mod.addIncludePath(highway_upstream.path("")); // Highway headers

    cjxl_mod.linkLibrary(jxl);
    cjxl_mod.linkLibrary(jxl_threads);
    cjxl_mod.linkLibrary(jxl_extras);
    cjxl_mod.linkLibrary(jxl_tool);
    cjxl_mod.linkLibrary(hwy);
    cjxl_mod.linkLibrary(brotli);
    cjxl_mod.linkLibrary(jxl_cms);
    cjxl_mod.linkLibrary(skcms);

    cjxl_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    cjxl_mod.addCMacro("JXL_STATIC_DEFINE", "1");
    cjxl_mod.addCMacro("JPEGXL_ENABLE_SKCMS", "1");
    cjxl_mod.addCMacro("JPEGXL_ENABLE_JPEGLI", "1");
    cjxl_mod.addCMacro("JPEGXL_ENABLE_APNG", "0");
    cjxl_mod.addCMacro("JPEGXL_ENABLE_GIF", "0");
    cjxl_mod.addCMacro("JPEGXL_ENABLE_JPEG", "0");
    cjxl_mod.addCMacro("JPEGXL_ENABLE_EXR", "0");
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        cjxl_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }

    cjxl_mod.addCSourceFiles(.{
        .root = libjxl.path("tools"),
        .files = &.{"cjxl_main.cc"},
        .flags = cxx_flags,
    });

    const cjxl = b.addExecutable(.{
        .name = "cjxl",
        .root_module = cjxl_mod,
    });

    return cjxl;
}

fn buildDjxl(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
    jxl: *std.Build.Step.Compile,
    jxl_threads: *std.Build.Step.Compile,
    jxl_extras: *std.Build.Step.Compile,
    jxl_tool: *std.Build.Step.Compile,
    hwy: *std.Build.Step.Compile,
    brotli: *std.Build.Step.Compile,
    jxl_cms: *std.Build.Step.Compile,
    skcms: *std.Build.Step.Compile,
    use_avx2_baseline: bool,
    strip: bool,
) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});

    const djxl_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = strip,
    });

    djxl_mod.addIncludePath(libjxl.path(""));
    djxl_mod.addIncludePath(libjxl.path("lib"));
    djxl_mod.addIncludePath(libjxl.path("lib/include"));
    djxl_mod.addIncludePath(b.path(""));
    djxl_mod.addIncludePath(b.path("skcms/upstream"));
    djxl_mod.addIncludePath(highway_upstream.path("")); // Highway headers

    djxl_mod.linkLibrary(jxl);
    djxl_mod.linkLibrary(jxl_threads);
    djxl_mod.linkLibrary(jxl_extras);
    djxl_mod.linkLibrary(jxl_tool);
    djxl_mod.linkLibrary(hwy);
    djxl_mod.linkLibrary(brotli);
    djxl_mod.linkLibrary(jxl_cms);
    djxl_mod.linkLibrary(skcms);

    djxl_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    djxl_mod.addCMacro("JXL_STATIC_DEFINE", "1");
    djxl_mod.addCMacro("JPEGXL_ENABLE_SKCMS", "1");
    djxl_mod.addCMacro("JPEGXL_ENABLE_JPEGLI", "1");
    djxl_mod.addCMacro("JPEGXL_ENABLE_APNG", "0");
    djxl_mod.addCMacro("JPEGXL_ENABLE_GIF", "0");
    djxl_mod.addCMacro("JPEGXL_ENABLE_JPEG", "0");
    djxl_mod.addCMacro("JPEGXL_ENABLE_EXR", "0");
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        djxl_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }

    djxl_mod.addCSourceFiles(.{
        .root = libjxl.path("tools"),
        .files = &.{"djxl_main.cc"},
        .flags = cxx_flags,
    });

    const djxl = b.addExecutable(.{
        .name = "djxl",
        .root_module = djxl_mod,
    });

    return djxl;
}

fn buildCjpegli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
    libjpeg_turbo: *std.Build.Dependency,
    jxl_extras: *std.Build.Step.Compile,
    jxl_tool: *std.Build.Step.Compile,
    jpegli: *std.Build.Step.Compile,
    hwy: *std.Build.Step.Compile,
    use_avx2_baseline: bool,
    strip: bool,
) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});

    const cjpegli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = strip,
    });

    cjpegli_mod.addIncludePath(libjxl.path(""));
    cjpegli_mod.addIncludePath(libjxl.path("lib"));
    cjpegli_mod.addIncludePath(libjxl.path("lib/include"));
    cjpegli_mod.addIncludePath(libjpeg_turbo.path(""));
    cjpegli_mod.addIncludePath(b.path(""));
    cjpegli_mod.addIncludePath(highway_upstream.path("")); // Highway headers

    cjpegli_mod.linkLibrary(jxl_extras);
    cjpegli_mod.linkLibrary(jxl_tool);
    cjpegli_mod.linkLibrary(jpegli);
    cjpegli_mod.linkLibrary(hwy);

    cjpegli_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    cjpegli_mod.addCMacro("JPEGXL_ENABLE_JPEGLI", "1");
    cjpegli_mod.addCMacro("JPEGXL_ENABLE_APNG", "0");
    cjpegli_mod.addCMacro("JPEGXL_ENABLE_GIF", "0");
    cjpegli_mod.addCMacro("JPEGXL_ENABLE_JPEG", "0");
    cjpegli_mod.addCMacro("JPEGXL_ENABLE_EXR", "0");
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        cjpegli_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }

    cjpegli_mod.addCSourceFiles(.{
        .root = libjxl.path("tools"),
        .files = &.{"cjpegli.cc"},
        .flags = cxx_flags,
    });

    const cjpegli_exe = b.addExecutable(.{
        .name = "cjpegli",
        .root_module = cjpegli_mod,
    });

    return cjpegli_exe;
}

fn buildDjpegli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libjxl: *std.Build.Dependency,
    libjpeg_turbo: *std.Build.Dependency,
    jxl_extras: *std.Build.Step.Compile,
    jxl_tool: *std.Build.Step.Compile,
    jpegli: *std.Build.Step.Compile,
    hwy: *std.Build.Step.Compile,
    use_avx2_baseline: bool,
    strip: bool,
) *std.Build.Step.Compile {
    const highway_upstream = b.dependency("highway", .{});

    const djpegli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = strip,
    });

    djpegli_mod.addIncludePath(libjxl.path(""));
    djpegli_mod.addIncludePath(libjxl.path("lib"));
    djpegli_mod.addIncludePath(libjxl.path("lib/include"));
    djpegli_mod.addIncludePath(libjpeg_turbo.path(""));
    djpegli_mod.addIncludePath(b.path(""));
    djpegli_mod.addIncludePath(highway_upstream.path("")); // Highway headers

    djpegli_mod.linkLibrary(jxl_extras);
    djpegli_mod.linkLibrary(jxl_tool);
    djpegli_mod.linkLibrary(jpegli);
    djpegli_mod.linkLibrary(hwy);

    djpegli_mod.addCMacro("HWY_STATIC_DEFINE", "1");
    djpegli_mod.addCMacro("JPEGXL_ENABLE_JPEGLI", "1");
    djpegli_mod.addCMacro("JPEGXL_ENABLE_APNG", "0");
    djpegli_mod.addCMacro("JPEGXL_ENABLE_GIF", "0");
    djpegli_mod.addCMacro("JPEGXL_ENABLE_JPEG", "0");
    djpegli_mod.addCMacro("JPEGXL_ENABLE_EXR", "0");
    if (getHwyDisabledTargets(target, use_avx2_baseline)) |disabled| {
        djpegli_mod.addCMacro("HWY_DISABLED_TARGETS", disabled);
    }

    djpegli_mod.addCSourceFiles(.{
        .root = libjxl.path("tools"),
        .files = &.{"djpegli.cc"},
        .flags = cxx_flags,
    });

    const djpegli_exe = b.addExecutable(.{
        .name = "djpegli",
        .root_module = djpegli_mod,
    });

    return djpegli_exe;
}

// ============== Compile flags ==============

const cxx_flags: []const []const u8 = &.{
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

// ============== Source file lists ==============

// CMS sources
// Source: https://github.com/libjxl/libjxl/blob/main/lib/jxl_lists.cmake
const jxl_cms_sources: []const []const u8 = &.{
    "jxl/cms/jxl_cms.cc",
};

// Threads sources
const jxl_threads_sources: []const []const u8 = &.{
    "threads/resizable_parallel_runner.cc",
    "threads/thread_parallel_runner.cc",
    "threads/thread_parallel_runner_internal.cc",
};

// Jpegli sources
const jpegli_sources: []const []const u8 = &.{
    "jpegli/adaptive_quantization.cc",
    "jpegli/bit_writer.cc",
    "jpegli/bitstream.cc",
    "jpegli/color_quantize.cc",
    "jpegli/color_transform.cc",
    "jpegli/common.cc",
    "jpegli/decode.cc",
    "jpegli/decode_marker.cc",
    "jpegli/decode_scan.cc",
    "jpegli/destination_manager.cc",
    "jpegli/downsample.cc",
    "jpegli/encode.cc",
    "jpegli/encode_finish.cc",
    "jpegli/encode_streaming.cc",
    "jpegli/entropy_coding.cc",
    "jpegli/error.cc",
    "jpegli/huffman.cc",
    "jpegli/idct.cc",
    "jpegli/input.cc",
    "jpegli/memory_manager.cc",
    "jpegli/quant.cc",
    "jpegli/render.cc",
    "jpegli/simd.cc",
    "jpegli/source_manager.cc",
    "jpegli/upsample.cc",
    // libjpeg API wrapper
    "jpegli/libjpeg_wrapper.cc",
};

// JXL decoder sources (partial list - will be expanded)
const jxl_dec_sources: []const []const u8 = &.{
    "jxl/ac_strategy.cc",
    "jxl/alpha.cc",
    "jxl/ans_common.cc",
    "jxl/blending.cc",
    "jxl/chroma_from_luma.cc",
    "jxl/coeff_order.cc",
    "jxl/color_encoding_internal.cc",
    "jxl/compressed_dc.cc",
    "jxl/convolve_slow.cc",
    "jxl/convolve_symmetric5.cc",
    "jxl/dct_scales.cc",
    "jxl/dec_ans.cc",
    "jxl/dec_bit_reader.cc",
    "jxl/dec_cache.cc",
    "jxl/dec_context_map.cc",
    "jxl/dec_external_image.cc",
    "jxl/dec_frame.cc",
    "jxl/dec_group.cc",
    "jxl/dec_group_border.cc",
    "jxl/dec_huffman.cc",
    "jxl/dec_modular.cc",
    "jxl/dec_noise.cc",
    "jxl/dec_patch_dictionary.cc",
    "jxl/dec_xyb.cc",
    "jxl/decode.cc",
    "jxl/entropy_coder.cc",
    "jxl/epf.cc",
    "jxl/fields.cc",
    "jxl/frame_header.cc",
    "jxl/headers.cc",
    "jxl/huffman_table.cc",
    "jxl/icc_codec.cc",
    "jxl/icc_codec_common.cc",
    "jxl/image.cc",
    "jxl/image_bundle.cc",
    "jxl/image_metadata.cc",
    "jxl/image_ops.cc",
    "jxl/loop_filter.cc",
    "jxl/luminance.cc",
    "jxl/memory_manager_internal.cc",
    "jxl/modular/encoding/dec_ma.cc",
    "jxl/modular/encoding/encoding.cc",
    "jxl/modular/modular_image.cc",
    "jxl/modular/transform/palette.cc",
    "jxl/modular/transform/rct.cc",
    "jxl/modular/transform/squeeze.cc",
    "jxl/modular/transform/squeeze_params.cc",
    "jxl/modular/transform/transform.cc",
    "jxl/opsin_params.cc",
    "jxl/passes_state.cc",
    "jxl/quant_weights.cc",
    "jxl/quantizer.cc",
    "jxl/render_pipeline/low_memory_render_pipeline.cc",
    "jxl/render_pipeline/render_pipeline.cc",
    "jxl/render_pipeline/render_pipeline_stage.cc",
    "jxl/render_pipeline/simple_render_pipeline.cc",
    "jxl/render_pipeline/stage_blending.cc",
    "jxl/render_pipeline/stage_chroma_upsampling.cc",
    "jxl/render_pipeline/stage_cms.cc",
    "jxl/render_pipeline/stage_epf.cc",
    "jxl/render_pipeline/stage_from_linear.cc",
    "jxl/render_pipeline/stage_gaborish.cc",
    "jxl/render_pipeline/stage_noise.cc",
    "jxl/render_pipeline/stage_patches.cc",
    "jxl/render_pipeline/stage_splines.cc",
    "jxl/render_pipeline/stage_spot.cc",
    "jxl/render_pipeline/stage_to_linear.cc",
    "jxl/render_pipeline/stage_tone_mapping.cc",
    "jxl/render_pipeline/stage_upsampling.cc",
    "jxl/render_pipeline/stage_write.cc",
    "jxl/render_pipeline/stage_xyb.cc",
    "jxl/render_pipeline/stage_ycbcr.cc",
    "jxl/simd_util.cc",
    "jxl/splines.cc",
    "jxl/toc.cc",
    // JPEG decoding support for libjxl
    "jxl/decode_to_jpeg.cc",
    "jxl/jpeg/dec_jpeg_data.cc",
    "jxl/jpeg/dec_jpeg_data_writer.cc",
    "jxl/jpeg/jpeg_data.cc",
};

// JXL encoder sources
const jxl_enc_sources: []const []const u8 = &.{
    "jxl/butteraugli/butteraugli.cc",
    "jxl/enc_ac_strategy.cc",
    "jxl/enc_adaptive_quantization.cc",
    "jxl/enc_ans.cc",
    "jxl/enc_ans_simd.cc",
    "jxl/enc_aux_out.cc",
    "jxl/enc_bit_writer.cc",
    "jxl/enc_butteraugli_comparator.cc",
    "jxl/enc_cache.cc",
    "jxl/enc_chroma_from_luma.cc",
    "jxl/enc_cluster.cc",
    "jxl/enc_coeff_order.cc",
    "jxl/enc_comparator.cc",
    "jxl/enc_context_map.cc",
    "jxl/enc_convolve_separable5.cc",
    "jxl/enc_debug_image.cc",
    "jxl/enc_detect_dots.cc",
    "jxl/enc_dot_dictionary.cc",
    "jxl/enc_entropy_coder.cc",
    "jxl/enc_external_image.cc",
    "jxl/enc_fast_lossless.cc",
    "jxl/enc_fields.cc",
    "jxl/enc_frame.cc",
    "jxl/enc_gaborish.cc",
    "jxl/enc_group.cc",
    "jxl/enc_heuristics.cc",
    "jxl/enc_huffman.cc",
    "jxl/enc_huffman_tree.cc",
    "jxl/enc_icc_codec.cc",
    "jxl/enc_image_bundle.cc",
    "jxl/enc_linalg.cc",
    "jxl/enc_lz77.cc",
    "jxl/enc_modular.cc",
    "jxl/enc_modular_simd.cc",
    "jxl/enc_noise.cc",
    "jxl/enc_patch_dictionary.cc",
    "jxl/enc_photon_noise.cc",
    "jxl/enc_progressive_split.cc",
    "jxl/enc_quant_weights.cc",
    "jxl/enc_splines.cc",
    "jxl/enc_toc.cc",
    "jxl/enc_transforms.cc",
    "jxl/enc_xyb.cc",
    "jxl/encode.cc",
    "jxl/modular/encoding/enc_debug_tree.cc",
    "jxl/modular/encoding/enc_encoding.cc",
    "jxl/modular/encoding/enc_ma.cc",
    // Modular transform encoding
    "jxl/modular/transform/enc_palette.cc",
    "jxl/modular/transform/enc_rct.cc",
    "jxl/modular/transform/enc_squeeze.cc",
    "jxl/modular/transform/enc_transform.cc",
    // JPEG encoding support for libjxl
    "jxl/jpeg/enc_jpeg_data.cc",
    "jxl/jpeg/enc_jpeg_data_reader.cc",
    "jxl/jpeg/enc_jpeg_huffman_decode.cc",
};

// C flags (for brotli)
const c_flags: []const []const u8 = &.{
    "-fPIC",
    "-Wall",
};

// Brotli sources
const brotli_sources: []const []const u8 = &.{
    // Common
    "common/constants.c",
    "common/context.c",
    "common/dictionary.c",
    "common/platform.c",
    "common/shared_dictionary.c",
    "common/transform.c",
    // Decoder
    "dec/bit_reader.c",
    "dec/decode.c",
    "dec/huffman.c",
    "dec/state.c",
    // Encoder
    "enc/backward_references.c",
    "enc/backward_references_hq.c",
    "enc/bit_cost.c",
    "enc/block_splitter.c",
    "enc/brotli_bit_stream.c",
    "enc/cluster.c",
    "enc/command.c",
    "enc/compound_dictionary.c",
    "enc/compress_fragment.c",
    "enc/compress_fragment_two_pass.c",
    "enc/dictionary_hash.c",
    "enc/encode.c",
    "enc/encoder_dict.c",
    "enc/entropy_encode.c",
    "enc/fast_log.c",
    "enc/histogram.c",
    "enc/literal_cost.c",
    "enc/memory.c",
    "enc/metablock.c",
    "enc/static_dict.c",
    "enc/utf8_util.c",
};

// Highway SIMD sources
const hwy_sources: []const []const u8 = &.{
    "hwy/abort.cc",
    "hwy/aligned_allocator.cc",
    "hwy/nanobenchmark.cc",
    "hwy/per_target.cc",
    "hwy/print.cc",
    "hwy/targets.cc",
    "hwy/timer.cc",
};

// skcms base sources
const skcms_base_sources: []const []const u8 = &.{
    "skcms.cc",
    "src/skcms_TransformBaseline.cc",
};

// skcms AVX2/Haswell sources (x86_64)
const skcms_avx2_sources: []const []const u8 = &.{
    "src/skcms_TransformHsw.cc",
};

// skcms AVX512/Skylake-X sources (x86_64 with AVX512 only)
const skcms_avx512_sources: []const []const u8 = &.{
    "src/skcms_TransformSkx.cc",
};

// jxl_extras core sources
// Source: https://github.com/libjxl/libjxl/blob/main/lib/jxl_lists.cmake
const jxl_extras_sources: []const []const u8 = &.{
    "extras/alpha_blend.cc",
    "extras/common.cc",
    "extras/compressed_icc.cc",
    "extras/dec/color_description.cc",
    "extras/dec/color_hints.cc",
    "extras/dec/decode.cc",
    "extras/enc/encode.cc",
    "extras/exif.cc",
    "extras/gain_map.cc",
    "extras/mmap.cc",
    "extras/packed_image.cc",
    "extras/time.cc",
};

// Extras for tools
const jxl_extras_for_tools_sources: []const []const u8 = &.{
    "extras/codec.cc",
    "extras/hlg.cc",
    "extras/metrics.cc",
    "extras/packed_image_convert.cc",
    "extras/tone_mapping.cc",
};

// PNM codec (no external dependencies)
const jxl_codec_pnm_sources: []const []const u8 = &.{
    "extras/dec/pnm.cc",
    "extras/enc/pnm.cc",
};

// PGX codec (no external dependencies)
const jxl_codec_pgx_sources: []const []const u8 = &.{
    "extras/dec/pgx.cc",
    "extras/enc/pgx.cc",
};

// JXL codec (no external dependencies)
const jxl_codec_jxl_sources: []const []const u8 = &.{
    "extras/dec/jxl.cc",
    "extras/enc/jxl.cc",
};

// NPY codec (no external dependencies)
const jxl_codec_npy_sources: []const []const u8 = &.{
    "extras/enc/npy.cc",
};

// jpegli codec
const jxl_codec_jpegli_sources: []const []const u8 = &.{
    "extras/dec/jpegli.cc",
    "extras/enc/jpegli.cc",
};

// Stub codec sources (compile to stubs when disabled)
const jxl_codec_stub_sources: []const []const u8 = &.{
    // These compile to stubs when JPEGXL_ENABLE_*=0
    "extras/dec/apng.cc",
    "extras/enc/apng.cc",
    "extras/dec/exr.cc",
    "extras/enc/exr.cc",
    "extras/dec/gif.cc",
    "extras/dec/jpg.cc",
    "extras/enc/jpg.cc",
};

// Tool library sources
const jxl_tool_sources: []const []const u8 = &.{
    "cmdline.cc",
    "codec_config.cc",
    "no_memory_manager.cc",
    "speed_stats.cc",
    "tool_version.cc",
    "tracking_memory_manager.cc",
};
