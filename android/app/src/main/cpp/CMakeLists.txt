# libnative_llm.so — PixEmber ローカルLLM ネイティブラッパ。
#
# llama.cpp 本体（libllama.so / libggml*.so）は flutter_llm 検証済みビルドを
# jniLibs にそのまま同梱し、ここでは C ラッパ 1ファイルだけを NDK でビルドする。
# llama.cpp のソース再ビルド・改変は一切行わない（SHA 050dde5 固定遵守）。
#
# 注意: libggml-hexagon.so / libggml-opencl.so は直接リンクしない。
# 両者は依存する QNN シンボルが APK 内に無いため dlopen 時に解決失敗する
# （flutter_llm 実測済み）。llama_backend_init() が実行時に内部で dlopen する。
# CPU パス（libggml-cpu.so）だけは llama.cpp が DT_NEEDED で必要とするため
# 明示リンクする。

cmake_minimum_required(VERSION 3.22.1)
project(native_llm C)

set(CMAKE_C_STANDARD 11)

# ネイティブビルド対象 ABI は arm64-v8a のみ。それ以外の ABI 構成が
# Gradle 側で走っても（flutter プラグイン起因で ndk.abiFilters が
# externalNativeBuild に効かない）ビルド失敗しないよう、スタブを
# 生成して正常終了する。実 .so は arm64-v8a の APK にのみ同梱される。
if(NOT ANDROID_ABI STREQUAL "arm64-v8a")
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/native_llm_stub.c"
       "typedef int nllm_stub_t; /* arm64-v8a only */\n")
  add_library(native_llm SHARED "${CMAKE_CURRENT_BINARY_DIR}/native_llm_stub.c")
  return()
endif()

add_library(native_llm SHARED native_llm.c)

target_include_directories(native_llm PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include)

target_compile_options(native_llm PRIVATE -Wall -Wextra)

# jniLibs の検証済みプリビルト .so を IMPORTED としてリンク
# （実行時は同じ nativeLibraryDir 内の DT_NEEDED として解決される）。
foreach(_lib llama ggml ggml-base ggml-cpu)
    add_library(${_lib} SHARED IMPORTED)
    set_target_properties(${_lib} PROPERTIES
        IMPORTED_LOCATION
        "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/lib${_lib}.so")
endforeach()

target_link_libraries(native_llm
    llama
    ggml
    ggml-base
    ggml-cpu
    android
    log)
