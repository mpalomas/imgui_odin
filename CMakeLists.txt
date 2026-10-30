# Builds Dear ImGui and its C API (dear_bindings) from upstream/ on Windows, with MSVC (cl or clang-cl):
# dcimgui.lib (static), and dcimgui.dll with its import library dcimgui.dll.lib (shared), named as
# vendor:wgpu names wgpu-native's. Run by tools/build_imgui.ps1, which installs them in lib/windows-<arch>/.
# Linux and macOS use tools/build_imgui.sh.
#
# Built with upstream/imconfig_odin.h, which the bindings are generated for. No exceptions, RTTI or
# thread-safe statics, and the static C runtime (/MT), which Odin programs link (libcmt): the DLL needs no
# Visual C++ redistributable. IM_ASSERT stays on, as ImGui recommends: it reports API misuse.
#
# Options: DCIMGUI_STATIC, DCIMGUI_SHARED (both ON).
cmake_minimum_required(VERSION 3.21)
project(dcimgui LANGUAGES CXX)

if(NOT MSVC)
    message(FATAL_ERROR "CMakeLists.txt builds with MSVC only: on Linux and macOS, run tools/build_imgui.sh")
endif()

option(DCIMGUI_STATIC "Build the static library, dcimgui.lib" ON)
option(DCIMGUI_SHARED "Build the shared library, dcimgui.dll" ON)

set(IMGUI "${CMAKE_CURRENT_SOURCE_DIR}/upstream/imgui")
set(BINDINGS "${CMAKE_CURRENT_SOURCE_DIR}/upstream/dear_bindings")
if(NOT EXISTS "${IMGUI}/imgui.cpp" OR NOT EXISTS "${BINDINGS}/dcimgui_nodefaultargfunctions.cpp")
    message(FATAL_ERROR "no sources in upstream/: run tools/update_imgui.ps1")
endif()
set(SOURCES
    "${IMGUI}/imgui.cpp"
    "${IMGUI}/imgui_draw.cpp"
    "${IMGUI}/imgui_tables.cpp"
    "${IMGUI}/imgui_widgets.cpp"
    "${IMGUI}/imgui_demo.cpp"
    "${BINDINGS}/dcimgui_nodefaultargfunctions.cpp"
)

set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded)
# Replaced by /EHs-c- and /GR- below.
string(REGEX REPLACE "/EH[a-z]+|/GR" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")

# The sources are compiled once per library, since CIMGUI_API differs: empty in the static library, and
# dllexport in the DLL, which exports the C API only. /Gy and /Gw let the programs' linker drop the unused
# API (/OPT:REF, which Odin passes). /MP compiles the files in parallel.
function(dcimgui_configure target api)
    target_include_directories(${target} PRIVATE "${IMGUI}" "${BINDINGS}" "${CMAKE_CURRENT_SOURCE_DIR}/upstream")
    target_compile_definitions(${target} PRIVATE
        "IMGUI_USER_CONFIG=\"imconfig_odin.h\""
        "CIMGUI_API=${api}"
        _HAS_EXCEPTIONS=0
    )
    target_compile_options(${target} PRIVATE /O2 /GR- /EHs-c- /Zc:threadSafeInit- /Gy /Gw /utf-8 /W3 /MP)
endfunction()

if(DCIMGUI_STATIC)
    add_library(dcimgui_static STATIC ${SOURCES})
    set_target_properties(dcimgui_static PROPERTIES OUTPUT_NAME dcimgui)
    dcimgui_configure(dcimgui_static "")
    # No default library directives (/Zl): the program chooses the C runtime.
    target_compile_options(dcimgui_static PRIVATE /Zl)
    install(TARGETS dcimgui_static ARCHIVE DESTINATION .)
endif()

if(DCIMGUI_SHARED)
    add_library(dcimgui_shared SHARED ${SOURCES})
    # dcimgui.dll.lib, so that it does not overwrite the static dcimgui.lib.
    set_target_properties(dcimgui_shared PROPERTIES OUTPUT_NAME dcimgui ARCHIVE_OUTPUT_NAME dcimgui.dll)
    dcimgui_configure(dcimgui_shared "__declspec(dllexport)")
    target_link_options(dcimgui_shared PRIVATE /OPT:REF /OPT:ICF)
    install(TARGETS dcimgui_shared RUNTIME DESTINATION . ARCHIVE DESTINATION .)
endif()
