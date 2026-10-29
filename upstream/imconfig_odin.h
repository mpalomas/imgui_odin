// The Dear ImGui configuration of the library and the Odin bindings, passed to every compile with
// -DIMGUI_USER_CONFIG by tools/build_imgui.sh, and read by tools/gen to evaluate the #if conditions of
// dcimgui.json. Changing it changes the ABI: rebuild the library and regenerate the bindings.
//
// Only plain `#define NAME` and `#define NAME VALUE` lines: tools/gen does not preprocess this file.
#pragma once

// No legacy API: this is a new binding with no users to keep compatible.
#define IMGUI_DISABLE_OBSOLETE_FUNCTIONS

// 32-bit ImWchar, for codepoints above U+FFFF (emoji).
#define IMGUI_USE_WCHAR32
