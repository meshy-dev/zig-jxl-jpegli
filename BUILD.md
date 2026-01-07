# JPEG XL / Jpegli Zig Build System - Build Documentation

This document details how the Zig build system for libjxl and jpegli translates the upstream CMake build, handles SIMD runtime dispatch, and provides pointers to relevant upstream source code for future maintenance.

## Summary

This build system implements:

✅ **Runtime SIMD dispatch** - Full SSE2 → AVX2 → AVX512 dispatch on all x86_64 targets  
✅ **Upstream source list tracking** - Build follows `lib/jxl_lists.cmake` exactly  
✅ **Highway integration** - Portable SIMD with runtime target selection  
✅ **skcms integration** - Color management with AVX2/AVX512 dispatch  
✅ **Cross-compilation** - Works for all targets including baseline x86_64  
✅ **Native builds** - Full optimization on host CPU with all SIMD variants  

### How SIMD works

The build compiles ALL SIMD variants (including AVX512) for x86_64 targets. At runtime, the library detects CPU capabilities and selects the best code path. A binary built for baseline x86_64 will still use AVX512 instructions on CPUs that support them.

## Table of Contents

1. [Overview](#overview)
2. [Upstream Source References](#upstream-source-references)
3. [SIMD Runtime Dispatch](#simd-runtime-dispatch)
4. [Build Options](#build-options)
5. [Cross-Compilation](#cross-compilation)
6. [Technical Notes](#technical-notes)
7. [Maintenance Checklist](#maintenance-checklist)

---

## Overview

The Zig build system replicates the upstream CMake build by:

1. **Following upstream source lists** from `lib/jxl_lists.cmake` exactly
2. **Compiling SIMD variants** with appropriate per-variant compiler flags
3. **Linking all variants** into libraries that perform runtime CPU dispatch

### Supported Architectures

| Architecture | SIMD Support | Runtime Dispatch |
|--------------|--------------|------------------|
| x86_64 | SSE2, AVX2, AVX512 | ✅ Yes |
| aarch64 | NEON | ✅ Yes (via Highway) |
| Other | Scalar fallback | N/A |

---

## Upstream Source References

The build system closely follows upstream CMake source lists.

### Main Build Files

| Component | Upstream Reference | Zig Implementation |
|-----------|-------------------|-------------------|
| Source Lists | `lib/jxl_lists.cmake` | `build.zig` (inline source arrays) |
| libjxl Build | `lib/jxl.cmake` | `buildJxl()` function |
| jpegli Build | `lib/jpegli.cmake` | `buildJpegli()` function |
| Threads Build | `lib/jxl_threads.cmake` | `buildJxlThreads()` function |

### Dependencies

| Dependency | Upstream Build | Zig Build |
|------------|----------------|-----------|
| Highway | `CMakeLists.txt` | `highway/build.zig` |
| Brotli | `cmake/` | `brotli/build.zig` |
| skcms | `BUILD.bazel` | `skcms/build.zig` |

---

## SIMD Runtime Dispatch

Both Highway and skcms use **runtime CPU detection** to select the best SIMD implementation.

### Highway Runtime Dispatch

Highway is a portable SIMD library that compiles code for multiple targets and dispatches at runtime.

**How it works:**

1. Highway uses `__attribute__((target(...)))` to compile functions for multiple SIMD levels
2. At runtime, CPUID detection selects the best available implementation
3. All targets (SSE2, AVX2, AVX512) are compiled into the binary

Highway 1.2.0+ automatically handles the `evex512` feature required by Clang 18-21 (see [Technical Notes](#clang-18-21-evex512-requirement)).

### skcms Runtime Dispatch

skcms uses explicit SIMD variants compiled with different flags:

| Variant | Source File | Compiler Flags |
|---------|-------------|----------------|
| Baseline | `skcms_TransformBaseline.cc` | None (portable C++) |
| Haswell | `skcms_TransformHsw.cc` | `+avx +avx2 +f16c +fma` |
| Skylake-X | `skcms_TransformSkx.cc` | `+avx512f ... +evex512` |

We use `-Xclang -target-feature -Xclang +feature` to add SIMD features without affecting the baseline:

```zig
mod.addCSourceFiles(.{
    .files = &.{"src/skcms_TransformSkx.cc"},
    .flags = &(cxx_flags ++ [_][]const u8{
        "-Xclang", "-target-feature", "-Xclang", "+avx512f",
        // ... other features ...
        "-Xclang", "-target-feature", "-Xclang", "+evex512",
    }),
});
```

### libjxl's enc_fast_lossless.cc

This file has its own AVX512 runtime dispatch (separate from Highway) using `__attribute__((target(...)))`. We patch it at build time to add `evex512` for Clang 18-21 compatibility. See [Technical Notes](#libjxl-enc_fast_losslesscc-patching) for details.

---

## Build Options

### Standard Zig Options

| Option | Description | Default |
|--------|-------------|---------|
| `-Dtarget=<triple>` | Cross-compilation target | Host architecture |
| `-Dcpu=<cpu>` | Target CPU baseline | `baseline` |
| `-Doptimize=<mode>` | Optimization level | `Debug` |

### Project-Specific Options

| Option | Description | Default |
|--------|-------------|---------|
| `-Dstrip=<bool>` | Strip debug symbols from CLI binaries | `true` for release |

### Examples

```bash
# Debug build for local testing
zig build -Doptimize=Debug

# Release build with optimizations
zig build -Doptimize=ReleaseFast

# Cross-compile to baseline x86_64 (includes AVX512 runtime dispatch!)
zig build -Dtarget=x86_64-linux -Dcpu=baseline -Doptimize=ReleaseFast

# Cross-compile to aarch64 Linux
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast
```

---

## Cross-Compilation

### x86_64 Targets

All x86_64 targets include full SIMD runtime dispatch:

| Baseline | SSE2 | AVX2 | AVX512 |
|----------|------|------|--------|
| baseline | ✅ | ✅ | ✅ |
| x86_64_v2 | ✅ | ✅ | ✅ |
| x86_64_v3 | ✅ | ✅ | ✅ |
| x86_64_v4 | ✅ | ✅ | ✅ |

The baseline only affects which instructions are used for "generic" code. SIMD-specific code paths are always available via runtime dispatch.

### ARM64 Targets

```bash
# Generic aarch64 (NEON dispatch via Highway)
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast
```

---

## Technical Notes

### Clang 18-21 evex512 Requirement

LLVM 18 introduced the `evex512` target feature to control 512-bit vector width for AVX512 instructions (part of Intel AVX10 support). When using `__attribute__((target("avx512f,...")))` for runtime dispatch, the target string must include `evex512` for 512-bit intrinsics to work on Clang 18-21. Without it:

```
error: always_inline function '_mm512_set1_ps' requires target feature 'evex512',
but would be inlined into function 'Set' that is compiled without support for 'evex512'
```

**Highway 1.2.0+** handles this automatically by detecting the compiler version and conditionally adding `evex512` to target strings. We use a newer Highway version than upstream libjxl bundles to get this fix. See `hwy/ops/set_macros-inl.h`:

```cpp
#if (1800 <= HWY_COMPILER_CLANG && HWY_COMPILER_CLANG < 2200)
#define HWY_HAVE_EVEX512 1
// ...
#define HWY_TARGET_STR_AVX3_VL512 ",evex512"
```

**Note:** Clang 22+ removed `evex512` entirely ([LLVM PR #157034](https://github.com/llvm/llvm-project/pull/157034)). When Zig upgrades to LLVM 22+, the evex512 workarounds in this build system will need to be removed (they'll cause errors). Look for `TODO` comments referencing LLVM 22.

### libjxl enc_fast_lossless.cc Patching

The file `lib/jxl/enc_fast_lossless.cc` has its own AVX512 runtime dispatch (separate from Highway) using `__attribute__((target(...)))`. These target strings don't include `evex512`, so we patch them at build time via `sed`:

```zig
fn getJxlPatchedSources(b: *Build, libjxl: *Dependency) Build.LazyPath {
    const sed = b.addSystemCommand(&.{
        "sed",
        "-e", "s/target(\"avx512vbmi2\")/target(\"avx512vbmi2,evex512\")/g",
        // ...
    });
    // ...
}
```

**When to remove:** If libjxl upstream adds `evex512` to `enc_fast_lossless.cc` target strings.

**References:**
- [LLVM commit introducing evex512](https://github.com/llvm/llvm-project/commit/24194090e17b599522a080d502ab0f68125d53dd)
- [LLVM issue #70002](https://github.com/llvm/llvm-project/issues/70002) - "LLVM 18 breaks inlining callees with compatible target attributes"
- [Highway issue #2705](https://github.com/google/highway/issues/2705) - Tracking evex512 compatibility

### skcms SIMD Flags

skcms compiles separate source files for each SIMD level. We use `-Xclang -target-feature` instead of `-mavx512f` because Zig's cross-compilation adds a global `-mcpu` flag that can override `-m` flags. The `-Xclang` form passes features directly to Clang's frontend, bypassing this.

```zig
// In skcms/build.zig
pub const avx512_flags = [_][]const u8{
    "-Xclang", "-target-feature", "-Xclang", "+avx512f",
    // ... other features ...
    "-Xclang", "-target-feature", "-Xclang", "+evex512",
};
```

---

## Maintenance Checklist

### Updating for New Upstream Releases

1. **Check `lib/jxl_lists.cmake` for source list changes**
   - Compare `JPEGXL_INTERNAL_DEC_SOURCES` with `jxl_dec_sources`
   - Compare `JPEGXL_INTERNAL_ENC_SOURCES` with `jxl_enc_sources`

2. **Check if libjxl adds evex512 to enc_fast_lossless.cc**
   - If upstream fixes this, remove `getJxlPatchedSources()` from `build.zig`

3. **When Zig upgrades to LLVM 22+**
   - Remove evex512 workarounds (search for `TODO` comments referencing LLVM 22)
   - The `+evex512` flag and source patching will cause build errors on LLVM 22+

3. **Highway version divergence**
   - We use a newer Highway than upstream libjxl bundles (for evex512 support)
   - When updating libjxl, check if their bundled Highway now includes the fix
   - Highway API is stable, so newer versions should be compatible

4. **Test cross-compilation**
   ```bash
   zig build -Dtarget=x86_64-linux -Dcpu=baseline -Doptimize=ReleaseFast
   zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast
   ```

5. **Verify runtime dispatch**
   ```bash
   ./zig-out/bin/cjxl --version  # Shows [AVX3_ZEN4,...] etc.
   ```

---

## References

- **libjxl repository**: https://github.com/libjxl/libjxl
- **Highway repository**: https://github.com/google/highway
- **skcms repository**: https://skia.googlesource.com/skcms
- **Zig build system**: https://ziglang.org/documentation/master/#Build-System
