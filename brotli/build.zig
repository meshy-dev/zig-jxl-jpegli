//! Zig build for Google's Brotli compression library
//!
//! Based on upstream CMake build system.
//! Source: https://github.com/google/brotli

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("brotli", .{});

    // Combined brotli library (common + dec + enc)
    const brotli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    brotli_mod.addIncludePath(upstream.path("c/include"));
    brotli_mod.addCSourceFiles(.{
        .root = upstream.path("c"),
        .files = common_sources ++ dec_sources ++ enc_sources,
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
    brotli.installHeadersDirectory(upstream.path("c/include/brotli"), "brotli", .{});

    b.installArtifact(brotli);
}

const c_flags: []const []const u8 = &.{
    "-fPIC",
    "-Wall",
};

// Common sources
const common_sources: []const []const u8 = &.{
    "common/constants.c",
    "common/context.c",
    "common/dictionary.c",
    "common/platform.c",
    "common/shared_dictionary.c",
    "common/transform.c",
};

// Decoder sources
const dec_sources: []const []const u8 = &.{
    "dec/bit_reader.c",
    "dec/decode.c",
    "dec/huffman.c",
    "dec/state.c",
};

// Encoder sources
const enc_sources: []const []const u8 = &.{
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
