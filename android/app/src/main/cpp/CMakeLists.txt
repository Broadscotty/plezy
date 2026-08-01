cmake_minimum_required(VERSION 3.22.1)
project(plezy_native)

option(DOVI_ENABLE_LIBDOVI "Link real libdovi" ON)
set(DOVI_LIBDOVI_PREBUILT_ROOT "" CACHE PATH "Path to prebuilt libdovi")
set(MPV_FFMPEG_ROOT "" CACHE PATH "Path to libmpv's FFmpeg headers and shared libraries")

add_library(dovi_bridge SHARED dovi_bridge.cpp)

if(DOVI_ENABLE_LIBDOVI)
    add_library(dovi_static STATIC IMPORTED)
    set_target_properties(dovi_static PROPERTIES
        IMPORTED_LOCATION "${DOVI_LIBDOVI_PREBUILT_ROOT}/${ANDROID_ABI}/lib/libdovi.a")
    target_compile_definitions(dovi_bridge PRIVATE DOVI_REAL_LINKED=1)
    target_include_directories(dovi_bridge PRIVATE ${CMAKE_SOURCE_DIR}/include)

    # Per-ABI: link Rust's required libraries (compiler-rt + libunwind)
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        target_link_libraries(dovi_bridge PRIVATE dovi_static log
            "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/libclang_rt.builtins-aarch64-android.a"
            "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/aarch64/libunwind.a")
    elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
        target_link_libraries(dovi_bridge PRIVATE dovi_static log
            "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/libclang_rt.builtins-arm-android.a"
            "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/arm/libunwind.a")
    elseif(ANDROID_ABI STREQUAL "x86_64")
        target_link_libraries(dovi_bridge PRIVATE dovi_static log
            "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/libclang_rt.builtins-x86_64-android.a"
            "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/x86_64/libunwind.a")
    elseif(ANDROID_ABI STREQUAL "x86")
        target_link_libraries(dovi_bridge PRIVATE dovi_static log
            "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/libclang_rt.builtins-i686-android.a"
            "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/i686/libunwind.a")
    else()
        target_link_libraries(dovi_bridge PRIVATE dovi_static log)
    endif()
else()
    target_compile_definitions(dovi_bridge PRIVATE DOVI_REAL_LINKED=0)
    target_link_libraries(dovi_bridge PRIVATE log)
endif()

foreach(ffmpeg_library avcodec avutil swresample)
    add_library(${ffmpeg_library} SHARED IMPORTED)
    set_target_properties(${ffmpeg_library} PROPERTIES
        IMPORTED_LOCATION "${MPV_FFMPEG_ROOT}/native/${ANDROID_ABI}/lib${ffmpeg_library}.so")
endforeach()

add_library(ffmpegJNI SHARED
    media3_ffmpeg_decoder/ffmpeg_jni.cc)
target_compile_features(ffmpegJNI PRIVATE cxx_std_17)
# NDK 29 + Flutter snap header conflict: snap's glibc stdlib.h
# conflicts with NDK sysroot. Unset _FORTIFY_SOURCE to avoid.
target_compile_options(ffmpegJNI PRIVATE -U_FORTIFY_SOURCE)
target_include_directories(ffmpegJNI PRIVATE
    "${MPV_FFMPEG_ROOT}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/media3_ffmpeg_decoder")
target_link_libraries(ffmpegJNI PRIVATE
    avcodec
    avutil
    swresample
    android
    log)
