# Builds abi_check.c with MSVC, for tools/abi/check.ps1 (Windows). Linux and macOS use tools/abi/check.sh.
cmake_minimum_required(VERSION 3.21)
project(abi_check LANGUAGES C)

set(UPSTREAM "${CMAKE_CURRENT_SOURCE_DIR}/../../upstream")
add_executable(abi_check abi_check.c)
set_target_properties(abi_check PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)
target_include_directories(abi_check PRIVATE "${UPSTREAM}/dear_bindings" "${UPSTREAM}/imgui" "${UPSTREAM}")
target_compile_definitions(abi_check PRIVATE "IMGUI_USER_CONFIG=\"imconfig_odin.h\"")
target_compile_options(abi_check PRIVATE /W3 /WX /utf-8)
