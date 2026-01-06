/* Copyright (c) the JPEG XL Project Authors. All rights reserved.
 *
 * Use of this source code is governed by a BSD-style
 * license that can be found in the LICENSE file.
 *
 * Pre-generated export header for zig-jxl-jpegli build system.
 * For static library builds, all symbols are exported as regular functions.
 */

#ifndef JXL_THREADS_EXPORT_H
#define JXL_THREADS_EXPORT_H

/* Static library build - no special export/import needed */
#ifdef JXL_STATIC_DEFINE
#  define JXL_THREADS_EXPORT
#  define JXL_THREADS_NO_EXPORT
#else
#  ifdef _WIN32
#    ifdef JXL_THREADS_INTERNAL_LIBRARY_BUILD
#      define JXL_THREADS_EXPORT __declspec(dllexport)
#    else
#      define JXL_THREADS_EXPORT __declspec(dllimport)
#    endif
#  else
#    ifdef JXL_THREADS_INTERNAL_LIBRARY_BUILD
#      define JXL_THREADS_EXPORT __attribute__((visibility("default")))
#    else
#      define JXL_THREADS_EXPORT
#    endif
#  endif
#  define JXL_THREADS_NO_EXPORT __attribute__((visibility("hidden")))
#endif

#ifndef JXL_THREADS_DEPRECATED
#  ifdef __GNUC__
#    define JXL_THREADS_DEPRECATED __attribute__ ((__deprecated__))
#  elif defined(_MSC_VER)
#    define JXL_THREADS_DEPRECATED __declspec(deprecated)
#  else
#    define JXL_THREADS_DEPRECATED
#  endif
#endif

#ifndef JXL_THREADS_DEPRECATED_EXPORT
#  define JXL_THREADS_DEPRECATED_EXPORT JXL_THREADS_EXPORT JXL_THREADS_DEPRECATED
#endif

#ifndef JXL_THREADS_DEPRECATED_NO_EXPORT
#  define JXL_THREADS_DEPRECATED_NO_EXPORT JXL_THREADS_NO_EXPORT JXL_THREADS_DEPRECATED
#endif

#endif /* JXL_THREADS_EXPORT_H */
