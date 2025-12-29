/* Copyright (c) the JPEG XL Project Authors. All rights reserved.
 *
 * Use of this source code is governed by a BSD-style
 * license that can be found in the LICENSE file.
 *
 * Pre-generated export header for zig-jxl-jpegli build system.
 * For static library builds, all symbols are exported as regular functions.
 */

#ifndef JXL_CMS_EXPORT_H
#define JXL_CMS_EXPORT_H

/* Static library build - no special export/import needed */
#ifdef JXL_STATIC_DEFINE
#  define JXL_CMS_EXPORT
#  define JXL_CMS_NO_EXPORT
#else
#  ifdef _WIN32
#    ifdef JXL_CMS_INTERNAL_LIBRARY_BUILD
#      define JXL_CMS_EXPORT __declspec(dllexport)
#    else
#      define JXL_CMS_EXPORT __declspec(dllimport)
#    endif
#  else
#    ifdef JXL_CMS_INTERNAL_LIBRARY_BUILD
#      define JXL_CMS_EXPORT __attribute__((visibility("default")))
#    else
#      define JXL_CMS_EXPORT
#    endif
#  endif
#  define JXL_CMS_NO_EXPORT __attribute__((visibility("hidden")))
#endif

#ifndef JXL_CMS_DEPRECATED
#  ifdef __GNUC__
#    define JXL_CMS_DEPRECATED __attribute__ ((__deprecated__))
#  elif defined(_MSC_VER)
#    define JXL_CMS_DEPRECATED __declspec(deprecated)
#  else
#    define JXL_CMS_DEPRECATED
#  endif
#endif

#ifndef JXL_CMS_DEPRECATED_EXPORT
#  define JXL_CMS_DEPRECATED_EXPORT JXL_CMS_EXPORT JXL_CMS_DEPRECATED
#endif

#ifndef JXL_CMS_DEPRECATED_NO_EXPORT
#  define JXL_CMS_DEPRECATED_NO_EXPORT JXL_CMS_NO_EXPORT JXL_CMS_DEPRECATED
#endif

#endif /* JXL_CMS_EXPORT_H */
