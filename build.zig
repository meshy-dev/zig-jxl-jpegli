//! Zig build for libjxl + jpegli
//!
//! This build file provides:
//! - libjxl: JPEG XL encoder/decoder library
//! - libjxl_threads: Multi-threaded parallel runner
//! - libjpegli: High-quality JPEG encoder/decoder (libjpeg-compatible)
//! - CLI tools: cjxl, djxl, cjpegli, djpegli
//!
//! Runtime SIMD dispatch: Highway and skcms use runtime CPU detection to select
//! the best SIMD implementation. The build system compiles all SIMD variants for
//! the target architecture, and the libraries automatically detect CPU capabilities
//! at runtime to choose the optimal code path. This allows binaries built on generic
//! x86_64 to still use AVX2/AVX512 when available, without requiring separate builds.
//!
//! Based on upstream CMake build system from https://github.com/libjxl/libjxl

const std = @import("std");
const Build = std.Build;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Compile = Build.Step.Compile;
const Dependency = Build.Dependency;

// Import sub-package build module for shared SIMD flag definitions
const skcms_build = @import("skcms/build.zig");

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip_cli = b.option(
        bool,
        "strip",
        "Strip debug symbols from CLI binaries (default: true for release builds)",
    ) orelse (optimize != .Debug);

    const libjxl = b.dependency("libjxl", .{});
    const libjpeg_turbo = b.dependency("libjpeg_turbo", .{});

    // Build vendored sub-packages
    const brotli = buildBrotli(b, target, optimize);
    const hwy = buildHighway(b, target, optimize);
    const skcms = buildSkcms(b, target, optimize);

    // Internal libraries
    const jxl_cms = buildJxlCms(b, target, optimize, libjxl, hwy, skcms);

    // Public libraries
    const jxl = buildJxl(b, target, optimize, libjxl, hwy, brotli, jxl_cms);
    const jxl_threads = buildJxlThreads(b, target, optimize, libjxl);
    const jpegli = buildJpegli(b, target, optimize, libjxl, libjpeg_turbo, hwy);

    b.installArtifact(jxl);
    b.installArtifact(jxl_threads);
    b.installArtifact(jpegli);

    // CLI tools
    const jxl_extras = buildJxlExtras(b, target, optimize, libjxl, libjpeg_turbo, hwy, jxl, jxl_threads, jpegli, skcms);
    const jxl_tool = buildJxlToolLib(b, target, optimize, libjxl, hwy);

    const cli_tools = [_]CliTool{
        .{ .name = "cjxl", .source = "cjxl_main.cc", .needs_full_jxl = true },
        .{ .name = "djxl", .source = "djxl_main.cc", .needs_full_jxl = true },
        .{ .name = "cjpegli", .source = "cjpegli.cc", .needs_full_jxl = false },
        .{ .name = "djpegli", .source = "djpegli.cc", .needs_full_jxl = false },
    };

    for (cli_tools) |tool| {
        const exe = if (tool.needs_full_jxl)
            buildJxlCliTool(b, target, optimize, libjxl, tool, jxl_extras, jxl_tool, jxl, jxl_threads, hwy, brotli, jxl_cms, skcms, strip_cli)
        else
            buildJpegliCliTool(b, target, optimize, libjxl, libjpeg_turbo, tool, jxl_extras, jxl_tool, jpegli, hwy, strip_cli);
        b.installArtifact(exe);
    }
}

const CliTool = struct {
    name: []const u8,
    source: []const u8,
    needs_full_jxl: bool,
};

fn createCxxModule(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
) *Build.Module {
    return b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
}

fn addJxlIncludePaths(
    mod: *Build.Module,
    b: *Build,
    libjxl: *Dependency,
    highway_upstream: *Dependency,
) void {
    mod.addIncludePath(libjxl.path(""));
    mod.addIncludePath(libjxl.path("lib"));
    mod.addIncludePath(libjxl.path("lib/include"));
    mod.addIncludePath(b.path(""));
    addHwyIncludes(mod, highway_upstream);
}

fn addJxlCommonMacros(mod: *Build.Module) void {
    mod.addCMacro("HWY_STATIC_DEFINE", "1");
    mod.addCMacro("JXL_STATIC_DEFINE", "1");
}

fn addHwyIncludes(mod: *Build.Module, highway_upstream: *Dependency) void {
    mod.addIncludePath(highway_upstream.path(""));
}

fn buildBrotli(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) *Compile {
    const upstream = b.dependency("brotli_upstream", .{});
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addIncludePath(upstream.path("c/include"));
    mod.addCSourceFiles(.{
        .root = upstream.path("c"),
        .files = &brotli_sources,
        .flags = &c_flags,
    });

    // Platform-specific defines
    switch (target.result.os.tag) {
        .linux => mod.addCMacro("OS_LINUX", "1"),
        .freebsd => mod.addCMacro("OS_FREEBSD", "1"),
        .macos => mod.addCMacro("OS_MACOSX", "1"),
        else => {},
    }

    return b.addLibrary(.{
        .name = "brotli",
        .linkage = .static,
        .root_module = mod,
    });
}

fn buildHighway(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) *Compile {
    const upstream = b.dependency("highway", .{});
    const mod = createCxxModule(b, target, optimize);

    addHwyIncludes(mod, upstream);
    mod.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &hwy_sources,
        .flags = &cxx_flags,
    });
    mod.addCMacro("HWY_STATIC_DEFINE", "1");

    return b.addLibrary(.{
        .name = "hwy",
        .linkage = .static,
        .root_module = mod,
    });
}

/// Generate a patched enc_fast_lossless.cc with evex512 added to target attributes.
/// This file has its own AVX512 runtime dispatch that also needs the evex512 fix.
/// TODO: When Zig upgrades to LLVM 22+, evex512 is removed and this patching becomes unnecessary.
fn getJxlPatchedSources(b: *Build, libjxl: *Dependency) Build.LazyPath {
    const sed = b.addSystemCommand(&.{
        "sed",
        // Patch target("avx512vbmi2") -> target("avx512vbmi2,evex512")
        "-e", "s/target(\"avx512vbmi2\")/target(\"avx512vbmi2,evex512\")/g",
        // Patch target("avx512cd,...,avx512vbmi") -> add evex512
        "-e", "s/avx512f,avx512vbmi\")/avx512f,avx512vbmi,evex512\")/g",
        // Patch #pragma GCC target for avx512
        "-e", "s/avx512f,avx512vbmi\"/avx512f,avx512vbmi,evex512\"/g",
    });
    sed.addFileArg(libjxl.path("lib/jxl/enc_fast_lossless.cc"));

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(sed.captureStdOut(), "jxl/enc_fast_lossless.cc");
    return wf.getDirectory();
}

fn buildSkcms(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) *Compile {
    const mod = createCxxModule(b, target, optimize);
    const root = b.path("skcms/upstream");

    mod.addIncludePath(root);
    mod.addIncludePath(b.path("skcms/upstream/src"));
    mod.addCSourceFiles(.{
        .root = root,
        .files = &skcms_build.base_sources,
        .flags = &skcms_build.cxx_flags,
    });

    // Use skcms/build.zig's SIMD variant logic
    skcms_build.addSimdVariants(mod, root, target.result.cpu.arch);

    return b.addLibrary(.{
        .name = "skcms",
        .linkage = .static,
        .root_module = mod,
    });
}

fn buildJxlCms(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    libjxl: *Dependency,
    hwy: *Compile,
    skcms: *Compile,
) *Compile {
    const highway_upstream = b.dependency("highway", .{});
    const mod = createCxxModule(b, target, optimize);

    addJxlIncludePaths(mod, b, libjxl, highway_upstream);
    mod.addIncludePath(b.path("skcms/upstream"));

    mod.linkLibrary(hwy);
    mod.linkLibrary(skcms);

    addJxlCommonMacros(mod);
    mod.addCMacro("JPEGXL_ENABLE_SKCMS", "1");

    mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = &jxl_cms_sources,
        .flags = &cxx_flags,
    });

    return b.addLibrary(.{
        .name = "jxl_cms",
        .linkage = .static,
        .root_module = mod,
    });
}

fn buildJxl(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    libjxl: *Dependency,
    hwy: *Compile,
    brotli: *Compile,
    jxl_cms: *Compile,
) *Compile {
    const highway_upstream = b.dependency("highway", .{});
    const brotli_upstream = b.dependency("brotli_upstream", .{});
    const mod = createCxxModule(b, target, optimize);

    addJxlIncludePaths(mod, b, libjxl, highway_upstream);
    mod.addIncludePath(b.path("skcms/upstream"));
    mod.addIncludePath(brotli_upstream.path("c/include"));

    mod.linkLibrary(hwy);
    mod.linkLibrary(brotli);
    mod.linkLibrary(jxl_cms);

    addJxlCommonMacros(mod);
    mod.addCMacro("JXL_INTERNAL_LIBRARY_BUILD", "1");
    mod.addCMacro("JPEGXL_ENABLE_SKCMS", "1");
    mod.addCMacro("JPEGXL_ENABLE_TRANSCODE_JPEG", "0");
    mod.addCMacro("JPEGXL_ENABLE_BOXES", "0");

    mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = &jxl_dec_sources,
        .flags = &cxx_flags,
    });
    mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = &jxl_enc_sources,
        .flags = &cxx_flags,
    });

    // enc_fast_lossless.cc has its own AVX512 target attributes that need evex512 (Clang 18-21)
    // TODO: Remove patching when Zig upgrades to LLVM 22+
    if (target.result.cpu.arch == .x86_64) {
        mod.addCSourceFiles(.{
            .root = getJxlPatchedSources(b, libjxl),
            .files = &.{"jxl/enc_fast_lossless.cc"},
            .flags = &cxx_flags,
        });
    } else {
        mod.addCSourceFiles(.{
            .root = libjxl.path("lib"),
            .files = &.{"jxl/enc_fast_lossless.cc"},
            .flags = &cxx_flags,
        });
    }

    const lib = b.addLibrary(.{
        .name = "jxl",
        .linkage = .static,
        .root_module = mod,
    });

    lib.installHeader(b.path("jxl/version.h"), "jxl/version.h");
    lib.installHeader(b.path("jxl/jxl_export.h"), "jxl/jxl_export.h");
    lib.installHeadersDirectory(libjxl.path("lib/include/jxl"), "jxl", .{
        .include_extensions = &.{".h"},
        .exclude_extensions = &.{"_cxx.h"},
    });

    return lib;
}

fn buildJxlThreads(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    libjxl: *Dependency,
) *Compile {
    const mod = createCxxModule(b, target, optimize);

    mod.addIncludePath(libjxl.path(""));
    mod.addIncludePath(libjxl.path("lib"));
    mod.addIncludePath(libjxl.path("lib/include"));
    mod.addIncludePath(b.path(""));

    addJxlCommonMacros(mod);
    mod.addCMacro("JXL_THREADS_INTERNAL_LIBRARY_BUILD", "1");

    mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = &jxl_threads_sources,
        .flags = &cxx_flags,
    });

    const lib = b.addLibrary(.{
        .name = "jxl_threads",
        .linkage = .static,
        .root_module = mod,
    });

    lib.installHeader(b.path("jxl/jxl_threads_export.h"), "jxl/jxl_threads_export.h");
    lib.installHeader(libjxl.path("lib/include/jxl/thread_parallel_runner.h"), "jxl/thread_parallel_runner.h");
    lib.installHeader(libjxl.path("lib/include/jxl/resizable_parallel_runner.h"), "jxl/resizable_parallel_runner.h");

    return lib;
}

fn buildJpegli(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    libjxl: *Dependency,
    libjpeg_turbo: *Dependency,
    hwy: *Compile,
) *Compile {
    const highway_upstream = b.dependency("highway", .{});
    const mod = createCxxModule(b, target, optimize);

    mod.addIncludePath(libjxl.path(""));
    mod.addIncludePath(libjxl.path("lib"));
    mod.addIncludePath(libjxl.path("lib/include"));
    mod.addIncludePath(libjpeg_turbo.path(""));
    mod.addIncludePath(b.path(""));
    addHwyIncludes(mod, highway_upstream);

    mod.linkLibrary(hwy);
    mod.addCMacro("HWY_STATIC_DEFINE", "1");

    mod.addCSourceFiles(.{
        .root = libjxl.path("lib"),
        .files = &jpegli_sources,
        .flags = &cxx_flags,
    });

    const lib = b.addLibrary(.{
        .name = "jpegli",
        .linkage = .static,
        .root_module = mod,
    });

    lib.installHeader(b.path("jconfig.h"), "jconfig.h");
    lib.installHeader(libjpeg_turbo.path("jpeglib.h"), "jpeglib.h");
    lib.installHeader(libjpeg_turbo.path("jmorecfg.h"), "jmorecfg.h");
    lib.installHeader(libjpeg_turbo.path("jerror.h"), "jerror.h");

    return lib;
}

fn buildJxlExtras(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    libjxl: *Dependency,
    libjpeg_turbo: *Dependency,
    hwy: *Compile,
    jxl: *Compile,
    jxl_threads: *Compile,
    jpegli: *Compile,
    skcms: *Compile,
) *Compile {
    const highway_upstream = b.dependency("highway", .{});
    const mod = createCxxModule(b, target, optimize);

    addJxlIncludePaths(mod, b, libjxl, highway_upstream);
    mod.addIncludePath(libjpeg_turbo.path(""));
    mod.addIncludePath(b.path("skcms/upstream"));

    mod.linkLibrary(hwy);
    mod.linkLibrary(jxl);
    mod.linkLibrary(jxl_threads);
    mod.linkLibrary(jpegli);
    mod.linkLibrary(skcms);

    addJxlCommonMacros(mod);
    mod.addCMacro("JPEGXL_ENABLE_SKCMS", "1");
    mod.addCMacro("JPEGXL_ENABLE_JPEGLI", "1");
    mod.addCMacro("JPEGXL_ENABLE_APNG", "0");
    mod.addCMacro("JPEGXL_ENABLE_GIF", "0");
    mod.addCMacro("JPEGXL_ENABLE_JPEG", "0");
    mod.addCMacro("JPEGXL_ENABLE_EXR", "0");

    const codec_sources = [_][]const []const u8{
        &jxl_extras_sources,
        &jxl_extras_for_tools_sources,
        &jxl_codec_pnm_sources,
        &jxl_codec_pgx_sources,
        &jxl_codec_jxl_sources,
        &jxl_codec_npy_sources,
        &jxl_codec_jpegli_sources,
        &jxl_codec_stub_sources,
    };

    for (codec_sources) |sources| {
        mod.addCSourceFiles(.{
            .root = libjxl.path("lib"),
            .files = sources,
            .flags = &cxx_flags,
        });
    }

    return b.addLibrary(.{
        .name = "jxl_extras",
        .linkage = .static,
        .root_module = mod,
    });
}

fn buildJxlToolLib(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    libjxl: *Dependency,
    hwy: *Compile,
) *Compile {
    const highway_upstream = b.dependency("highway", .{});
    const mod = createCxxModule(b, target, optimize);

    addJxlIncludePaths(mod, b, libjxl, highway_upstream);
    mod.linkLibrary(hwy);

    addJxlCommonMacros(mod);
    mod.addCMacro("JPEGXL_VERSION", "\"0.12.0\"");

    mod.addCSourceFiles(.{
        .root = libjxl.path("tools"),
        .files = &jxl_tool_sources,
        .flags = &cxx_flags,
    });

    return b.addLibrary(.{
        .name = "jxl_tool",
        .linkage = .static,
        .root_module = mod,
    });
}

fn buildJxlCliTool(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    libjxl: *Dependency,
    tool: CliTool,
    jxl_extras: *Compile,
    jxl_tool: *Compile,
    jxl: *Compile,
    jxl_threads: *Compile,
    hwy: *Compile,
    brotli: *Compile,
    jxl_cms: *Compile,
    skcms: *Compile,
    strip: bool,
) *Compile {
    const highway_upstream = b.dependency("highway", .{});
    const mod = createCxxModule(b, target, optimize);
    mod.strip = strip;

    addJxlIncludePaths(mod, b, libjxl, highway_upstream);
    mod.addIncludePath(b.path("skcms/upstream"));

    const deps = [_]*Compile{ jxl, jxl_threads, jxl_extras, jxl_tool, hwy, brotli, jxl_cms, skcms };
    for (deps) |dep| mod.linkLibrary(dep);

    addJxlCommonMacros(mod);
    mod.addCMacro("JPEGXL_ENABLE_SKCMS", "1");
    mod.addCMacro("JPEGXL_ENABLE_JPEGLI", "1");
    mod.addCMacro("JPEGXL_ENABLE_APNG", "0");
    mod.addCMacro("JPEGXL_ENABLE_GIF", "0");
    mod.addCMacro("JPEGXL_ENABLE_JPEG", "0");
    mod.addCMacro("JPEGXL_ENABLE_EXR", "0");

    mod.addCSourceFiles(.{
        .root = libjxl.path("tools"),
        .files = &.{tool.source},
        .flags = &cxx_flags,
    });

    return b.addExecutable(.{
        .name = tool.name,
        .root_module = mod,
    });
}

fn buildJpegliCliTool(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    libjxl: *Dependency,
    libjpeg_turbo: *Dependency,
    tool: CliTool,
    jxl_extras: *Compile,
    jxl_tool: *Compile,
    jpegli: *Compile,
    hwy: *Compile,
    strip: bool,
) *Compile {
    const highway_upstream = b.dependency("highway", .{});
    const mod = createCxxModule(b, target, optimize);
    mod.strip = strip;

    mod.addIncludePath(libjxl.path(""));
    mod.addIncludePath(libjxl.path("lib"));
    mod.addIncludePath(libjxl.path("lib/include"));
    mod.addIncludePath(libjpeg_turbo.path(""));
    mod.addIncludePath(b.path(""));
    addHwyIncludes(mod, highway_upstream);

    const deps = [_]*Compile{ jxl_extras, jxl_tool, jpegli, hwy };
    for (deps) |dep| mod.linkLibrary(dep);

    mod.addCMacro("HWY_STATIC_DEFINE", "1");
    mod.addCMacro("JPEGXL_ENABLE_JPEGLI", "1");
    mod.addCMacro("JPEGXL_ENABLE_APNG", "0");
    mod.addCMacro("JPEGXL_ENABLE_GIF", "0");
    mod.addCMacro("JPEGXL_ENABLE_JPEG", "0");
    mod.addCMacro("JPEGXL_ENABLE_EXR", "0");

    mod.addCSourceFiles(.{
        .root = libjxl.path("tools"),
        .files = &.{tool.source},
        .flags = &cxx_flags,
    });

    return b.addExecutable(.{
        .name = tool.name,
        .root_module = mod,
    });
}

// ============== Compile flags ==============

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
    // Clang-specific flags from upstream CMake (required for SIMD dispatch)
    "-fno-slp-vectorize",
    "-fno-vectorize",
    "-fmerge-all-constants",
};

const c_flags = [_][]const u8{
    "-fPIC",
    "-Wall",
};

// ============== Source file lists ==============
// Source: lib/jxl_lists.cmake

const jxl_cms_sources = [_][]const u8{
    "jxl/cms/jxl_cms.cc",
};

const jxl_threads_sources = [_][]const u8{
    "threads/resizable_parallel_runner.cc",
    "threads/thread_parallel_runner.cc",
    "threads/thread_parallel_runner_internal.cc",
};

const jpegli_sources = [_][]const u8{
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
    "jpegli/libjpeg_wrapper.cc",
};

const jxl_dec_sources = [_][]const u8{
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
    "jxl/decode_to_jpeg.cc",
    "jxl/jpeg/dec_jpeg_data.cc",
    "jxl/jpeg/dec_jpeg_data_writer.cc",
    "jxl/jpeg/jpeg_data.cc",
};

const jxl_enc_sources = [_][]const u8{
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
    // enc_fast_lossless.cc handled separately - needs evex512 patch for x86_64
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
    "jxl/jpeg/enc_jpeg_data.cc",
    "jxl/jpeg/enc_jpeg_data_reader.cc",
    "jxl/jpeg/enc_jpeg_huffman_decode.cc",
    "jxl/modular/encoding/enc_debug_tree.cc",
    "jxl/modular/encoding/enc_encoding.cc",
    "jxl/modular/encoding/enc_ma.cc",
    "jxl/modular/transform/enc_palette.cc",
    "jxl/modular/transform/enc_rct.cc",
    "jxl/modular/transform/enc_squeeze.cc",
    "jxl/modular/transform/enc_transform.cc",
};

const jxl_extras_sources = [_][]const u8{
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

const jxl_extras_for_tools_sources = [_][]const u8{
    "extras/codec.cc",
    "extras/hlg.cc",
    "extras/metrics.cc",
    "extras/packed_image_convert.cc",
    "extras/tone_mapping.cc",
};

const jxl_codec_pnm_sources = [_][]const u8{
    "extras/dec/pnm.cc",
    "extras/enc/pnm.cc",
};

const jxl_codec_pgx_sources = [_][]const u8{
    "extras/dec/pgx.cc",
    "extras/enc/pgx.cc",
};

const jxl_codec_jxl_sources = [_][]const u8{
    "extras/dec/jxl.cc",
    "extras/enc/jxl.cc",
};

const jxl_codec_npy_sources = [_][]const u8{
    "extras/enc/npy.cc",
};

const jxl_codec_jpegli_sources = [_][]const u8{
    "extras/dec/jpegli.cc",
    "extras/enc/jpegli.cc",
};

const jxl_codec_stub_sources = [_][]const u8{
    "extras/dec/apng.cc",
    "extras/enc/apng.cc",
    "extras/dec/exr.cc",
    "extras/enc/exr.cc",
    "extras/dec/gif.cc",
    "extras/dec/jpg.cc",
    "extras/enc/jpg.cc",
};

const jxl_tool_sources = [_][]const u8{
    "cmdline.cc",
    "codec_config.cc",
    "no_memory_manager.cc",
    "speed_stats.cc",
    "tool_version.cc",
    "tracking_memory_manager.cc",
};

const brotli_sources = [_][]const u8{
    "common/constants.c",
    "common/context.c",
    "common/dictionary.c",
    "common/platform.c",
    "common/shared_dictionary.c",
    "common/transform.c",
    "dec/bit_reader.c",
    "dec/decode.c",
    "dec/huffman.c",
    "dec/state.c",
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

const hwy_sources = [_][]const u8{
    "hwy/abort.cc",
    "hwy/aligned_allocator.cc",
    "hwy/nanobenchmark.cc",
    "hwy/per_target.cc",
    "hwy/print.cc",
    "hwy/targets.cc",
    "hwy/timer.cc",
};
