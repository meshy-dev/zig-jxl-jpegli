# zig-jxl-jpegli

Zig build system for [libjxl](https://github.com/libjxl/libjxl) (JPEG XL) and [jpegli](https://github.com/libjxl/libjxl/tree/main/lib/jpegli) (high-quality JPEG).

> **NOTE**: This conversion process from the original CMake build to Zig build is heavily AI/LLM driven. Please take the time to read and verify the `build.zig` file to ensure correctness yourself.

## Features

- **libjxl** - Full JPEG XL encoder/decoder library
- **libjxl_threads** - Multi-threaded parallel runner
- **libjpegli** - High-quality JPEG encoder/decoder (libjpeg-compatible API)
- **Full SIMD support** - Uses [Google Highway](https://github.com/google/highway) for portable SIMD
- **Cross-platform** - Builds with Zig's cross-compilation support

## Building

```bash
# Debug build
zig build

# Release build  
zig build -Doptimize=ReleaseFast

# Cross-compile example
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
```

## Output

### Libraries

| Library | Description |
|---------|-------------|
| `zig-out/lib/libjxl.a` | JPEG XL encoder/decoder |
| `zig-out/lib/libjxl_threads.a` | Threading support |
| `zig-out/lib/libjpegli.a` | JPEG encoder/decoder (libjpeg-compatible) |

### CLI Tools

| Tool | Description | Supported Formats |
|------|-------------|-------------------|
| `zig-out/bin/cjxl` | JPEG XL encoder | PPM/PGM/PFM → JXL |
| `zig-out/bin/djxl` | JPEG XL decoder | JXL → PPM/PGM/PFM |
| `zig-out/bin/cjpegli` | JPEG encoder (jpegli) | PPM/PGM/PFM → JPEG |
| `zig-out/bin/djpegli` | JPEG decoder (jpegli) | JPEG → PPM/PGM/PFM |

### Headers

| Header | Description |
|--------|-------------|
| `zig-out/include/jxl/*.h` | libjxl public headers |
| `zig-out/include/jpeglib.h` | libjpeg-compatible API |
| `zig-out/include/jconfig.h`, `jmorecfg.h`, `jerror.h` | libjpeg support headers |

## Usage

### As a Zig dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .jxl_jpegli = .{
        .url = "git+https://github.com/meshy-dev/zig-jxl-jpegli#<commit>",
        .hash = "<hash>",
    },
},
```

In your `build.zig`:

```zig
const jxl_jpegli = b.dependency("jxl_jpegli", .{
    .target = target,
    .optimize = optimize,
});

// Link libjxl
exe.linkLibrary(jxl_jpegli.artifact("jxl"));
exe.linkLibrary(jxl_jpegli.artifact("jxl_threads"));

// Or link libjpegli for JPEG support
exe.linkLibrary(jxl_jpegli.artifact("jpegli"));
```

## Dependencies

All dependencies are fetched automatically via Zig's package manager:

| Dependency | Source | License | Purpose |
|------------|--------|---------|---------|
| libjxl | [github.com/libjxl/libjxl](https://github.com/libjxl/libjxl) | BSD-3-Clause | Core JPEG XL + jpegli |
| highway | [github.com/google/highway](https://github.com/google/highway) | Apache-2.0 | SIMD |
| brotli | [github.com/google/brotli](https://github.com/google/brotli) | MIT | Compression |
| libjpeg-turbo | [github.com/libjpeg-turbo/libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) | IJG/BSD/zlib | Headers only |

### skcms (vendored)

[skcms](https://skia.googlesource.com/skcms) is vendored in `skcms/` because Zig's package fetcher doesn't support `googlesource.com` URLs.

To update skcms:
```bash
git subtree pull --prefix=skcms https://skia.googlesource.com/skcms <new-commit> --squash
```

## Upstream References

When updating this build, check these upstream CMake files for source list changes:

- [lib/jxl_lists.cmake](https://github.com/libjxl/libjxl/blob/main/lib/jxl_lists.cmake) - Source file lists
- [lib/jxl.cmake](https://github.com/libjxl/libjxl/blob/main/lib/jxl.cmake) - libjxl build
- [lib/jxl_threads.cmake](https://github.com/libjxl/libjxl/blob/main/lib/jxl_threads.cmake) - Threads
- [lib/jpegli.cmake](https://github.com/libjxl/libjxl/blob/main/lib/jpegli.cmake) - jpegli build
- [highway CMakeLists.txt](https://github.com/google/highway/blob/master/CMakeLists.txt#L356-L367) - Highway sources
- [skcms BUILD.bazel](https://skia.googlesource.com/skcms/+/refs/heads/main/BUILD.bazel) - skcms sources

## Vendored Sub-packages

This repository includes three vendored sub-packages with their own `build.zig`:

| Package | Location | Description |
|---------|----------|-------------|
| Brotli | `brotli/` | Compression library |
| Highway | `highway/` | SIMD library |
| skcms | `skcms/` | Color management |

Each can be built independently for testing:

```bash
cd brotli && zig build
cd highway && zig build
cd skcms && zig build
```

## License

See [LICENSE.md](LICENSE.md) for full license information.

- Build scripts (`build.zig`, `build.zig.zon`, etc.): MIT
- libjxl / jpegli: BSD-3-Clause
- Brotli: MIT
- Highway: Apache-2.0
- skcms: BSD-3-Clause
- libjpeg-turbo: IJG/BSD/zlib
