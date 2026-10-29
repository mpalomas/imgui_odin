package main

import vmem "core:mem/virtual"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

JSON_PATH :: #directory + "../../upstream/dear_bindings/dcimgui_nodefaultargfunctions.json"
CONFIG_PATH :: #directory + "../../upstream/imconfig_odin.h"
GENERATED_PATH :: #directory + "../../imgui/imgui_generated.odin"
ABI_C_PATH :: #directory + "../abi/abi_check.c"
ABI_ODIN_PATH :: #directory + "../abi/odin/main.odin"

CONFIG :: "#define IMGUI_DISABLE_OBSOLETE_FUNCTIONS\n"

// A dcimgui.json document with the given sections (the contents of their JSON arrays).
@(private = "file")
doc :: proc(defines := "", enums := "", typedefs := "", structs := "", functions := "") -> string {
	return fmt.tprintf(
		`{{"defines": [%s], "enums": [%s], "typedefs": [%s], "structs": [%s], "functions": [%s]}}`,
		defines, enums, typedefs, structs, functions,
	)
}

// The items of a JSON array.
@(private = "file")
list :: proc(items: ..string) -> string {
	return strings.join(items, ", ", context.temp_allocator)
}

// Type descriptions.
@(private = "file")
builtin :: proc(name: string) -> string {
	return fmt.tprintf(`{{"kind": "Builtin", "builtin_type": "%s"}}`, name)
}

@(private = "file")
user :: proc(name: string) -> string {
	return fmt.tprintf(`{{"kind": "User", "name": "%s"}}`, name)
}

@(private = "file")
pointer :: proc(inner: string) -> string {
	return fmt.tprintf(`{{"kind": "Pointer", "inner_type": %s}}`, inner)
}

@(private = "file")
const_char :: `{"kind": "Builtin", "builtin_type": "char", "storage_classes": ["const"]}`

@(private = "file")
typedef :: proc(name, type: string) -> string {
	return fmt.tprintf(`{{"name": "%s", "type": {{"description": %s}}}}`, name, type)
}

@(private = "file")
field :: proc(name, type: string, extra := "") -> string {
	return fmt.tprintf(`{{"name": "%s", "type": {{"description": %s}}%s}}`, name, type, extra)
}

@(private = "file")
struct_ :: proc(name: string, fields: ..string) -> string {
	return fmt.tprintf(`{{"name": "%s", "kind": "struct", "fields": [%s]}}`, name, list(..fields))
}

@(private = "file")
arg :: proc(name, type: string, extra := "") -> string {
	return fmt.tprintf(`{{"name": "%s", "type": {{"description": %s}}%s}}`, name, type, extra)
}

@(private = "file")
function :: proc(name, ret: string, args: ..string) -> string {
	return fmt.tprintf(`{{"name": "%s", "return_type": {{"description": %s}}, "arguments": [%s]}}`, name, ret, list(..args))
}

@(private = "file")
element :: proc(name: string, value: i64, expression := "", extra := "") -> string {
	return fmt.tprintf(`{{"name": "%s", "value": %d, "value_expression": "%s"%s}}`, name, value, expression, extra)
}

@(private = "file")
enum_ :: proc(name: string, is_flags: bool, elements: ..string) -> string {
	return fmt.tprintf(`{{"name": "%s", "is_flags_enum": %v, "elements": [%s]}}`, name, is_flags, list(..elements))
}

// Generates Odin from a document and checks that each of `want` appears in the bindings.
@(private = "file")
expect_output :: proc(t: ^testing.T, json: string, want: ..string, config := CONFIG, loc := #caller_location) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	out, err := generate(json, config, "test.json")
	if !testing.expectf(t, err == "", "generate failed: %s", err, loc = loc) {
		return
	}
	for w in want {
		testing.expectf(t, strings.contains(out.bindings, w), "missing:\n%s\nin output:\n%s", w, out.bindings, loc = loc)
	}
}

@(private = "file")
expect_missing :: proc(t: ^testing.T, json: string, unwanted: string, config := CONFIG, loc := #caller_location) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	out, err := generate(json, config, "test.json")
	if testing.expectf(t, err == "", "generate failed: %s", err, loc = loc) {
		testing.expectf(t, !strings.contains(out.bindings, unwanted), "unexpected:\n%s\nin output:\n%s", unwanted, out.bindings, loc = loc)
	}
}

@(private = "file")
expect_error :: proc(t: ^testing.T, json: string, want: string, loc := #caller_location) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	_, err := generate(json, CONFIG, "test.json")
	testing.expectf(t, strings.contains(err, want), "want error containing '%s', got '%s'", want, err, loc = loc)
}

@(test)
test_names :: proc(t: ^testing.T) {
	expect_output(t, doc(
		functions = list(
			function("ImGui_GetIO", pointer(user("ImGuiIO"))),
			function("ImGuiIO_ClearInputKeys", builtin("void"), arg("self", pointer(user("ImGuiIO")))),
			function("ImDrawList_PopClipRect", builtin("void")),
		),
		structs = list(struct_("ImGuiIO", field("DeltaTime", builtin("float"))), struct_("ImDrawList")),
	),
		"IO :: struct {\n\tDeltaTime: f32,\n}",
		"@(link_name = \"ImGui_GetIO\")\n\tGetIO :: proc() -> ^IO ---",
		"IO_ClearInputKeys :: proc(self: ^IO) ---",
		"DrawList_PopClipRect :: proc() ---",
	)
}

@(test)
test_types :: proc(t: ^testing.T) {
	expect_output(t, doc(
		typedefs = list(
			typedef("ImU32", builtin("unsigned_int")),
			typedef("ImGuiID", builtin("unsigned_int")),
			typedef("ImDrawCallback", `{"kind": "Type", "name": "ImDrawCallback", "inner_type": {"kind": "Pointer", "inner_type": {"kind": "Function", "return_type": {"kind": "Builtin", "builtin_type": "void"}, "parameters": [{"kind": "Type", "name": "cmd", "inner_type": {"kind": "Pointer", "inner_type": {"kind": "User", "name": "ImDrawCmd"}}}]}}}`),
		),
		structs = list(
			struct_("ImVec2", field("x", builtin("float")), field("y", builtin("float"))),
			struct_("ImDrawCmd",
				field("Name", pointer(const_char)),
				field("Buf", pointer(builtin("char"))),
				field("User", pointer(builtin("void"))),
				field("Col", user("ImU32")),
				field("Id", user("ImGuiID")),
				field("Pos", user("ImVec2")),
				field("Tag", `{"kind": "Array", "bounds": "32+1", "inner_type": {"kind": "Builtin", "builtin_type": "char"}}`),
				field("Callback", user("ImDrawCallback")),
			),
		),
	),
		"Vec2 :: [2]f32",
		"ID :: u32",
		"DrawCallback :: #type proc \"c\" (cmd: ^DrawCmd)",
		"\tName: cstring,\n\tBuf: [^]u8,\n\tUser: rawptr,\n\tCol: u32,\n\tId: ID,\n\tPos: Vec2,\n\tTag: [33]u8,\n\tCallback: DrawCallback,",
	)
	// Primitive typedefs are replaced by the Odin type.
	expect_missing(t, doc(typedefs = typedef("ImU32", builtin("unsigned_int"))), "U32 ::")
}

@(test)
test_enums :: proc(t: ^testing.T) {
	expect_output(t, doc(
		typedefs = typedef("ImGuiCol", builtin("int")),
		enums = enum_("ImGuiCol_", false,
			element("ImGuiCol_Text", 0),
			element("ImGuiCol_WindowBg", 1),
			element("ImGuiCol_COUNT", 2, extra = `, "is_count": true`),
		),
		structs = list(struct_("ImVec4"), struct_("ImGuiStyle", field("Colors", `{"kind": "Array", "bounds": "ImGuiCol_COUNT", "inner_type": {"kind": "User", "name": "ImVec4"}}`))),
		functions = function("ImGui_GetStyleColorName", pointer(const_char), arg("idx", user("ImGuiCol"))),
	),
		"Col :: enum c.int {\n\tText = 0,\n\tWindowBg = 1,\n}\nCol_COUNT :: 2",
		// Elements 0 to COUNT - 1: an enumerated array.
		"Colors: [Col]Vec4,",
		"GetStyleColorName :: proc(idx: Col) -> cstring ---",
	)
	// Not 0 to COUNT - 1: a fixed array.
	expect_output(t, doc(
		enums = enum_("ImGuiMouseButton_", false,
			element("ImGuiMouseButton_Left", 0),
			element("ImGuiMouseButton_COUNT", 5, extra = `, "is_count": true`),
		),
		structs = struct_("ImGuiIO", field("MouseDown", `{"kind": "Array", "bounds": "ImGuiMouseButton_COUNT", "inner_type": {"kind": "Builtin", "builtin_type": "bool"}}`)),
	), "MouseDown: [MouseButton_COUNT]bool,")
	// Elements with another prefix, and digits.
	expect_output(t, doc(enums = enum_("ImGuiKey", false,
		element("ImGuiKey_0", 536),
		element("ImGuiMod_Ctrl", 4096),
	)), "\t_0 = 536,", "\tMod_Ctrl = 4096,")
}

@(test)
test_flags :: proc(t: ^testing.T) {
	expect_output(t, doc(
		typedefs = typedef("ImGuiWindowFlags", builtin("int")),
		enums = enum_("ImGuiWindowFlags_", true,
			element("ImGuiWindowFlags_None", 0, "0"),
			element("ImGuiWindowFlags_NoTitleBar", 1, "1<<0"),
			element("ImGuiWindowFlags_NoResize", 2, "1<<1"),
			element("ImGuiWindowFlags_NoDecoration", 3, "ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize"),
		),
		functions = function("ImGui_Begin", builtin("bool"), arg("flags", user("ImGuiWindowFlags"), `, "default_value": "0"`)),
	),
		"WindowFlag :: enum c.int {\n\tNoTitleBar = 0,\n\tNoResize = 1,\n}\nWindowFlags :: bit_set[WindowFlag; c.int]",
		"WindowFlags_NoDecoration :: WindowFlags{.NoTitleBar, .NoResize}",
		"Begin :: proc(flags: WindowFlags = {}) -> bool ---",
	)
	// A number in a range of bits: constants, not members.
	expect_output(t, doc(enums = enum_("ImGuiPopupFlags_", true,
		element("ImGuiPopupFlags_MouseButtonLeft", 4, "1<<2"),
		element("ImGuiPopupFlags_MouseButtonRight", 8, "2<<2"),
		element("ImGuiPopupFlags_MouseButtonMiddle", 12, "3<<2"),
		element("ImGuiPopupFlags_NoReopen", 32, "1<<5"),
		element("ImGuiPopupFlags_MouseButtonShift_", 2, "2"),
		element("ImGuiPopupFlags_MouseButtonMask_", 12, "0x0C"),
	)),
		"PopupFlag :: enum c.int {\n\tNoReopen = 5,\n}",
		"PopupFlags_MouseButtonLeft :: transmute(PopupFlags)c.int(4)",
		"PopupFlags_MouseButtonMiddle :: transmute(PopupFlags)c.int(12)",
		"PopupFlags_MouseButtonShift_ :: 2",
		"PopupFlags_MouseButtonMask_ :: transmute(PopupFlags)c.int(12)",
	)
}

@(test)
test_conditionals :: proc(t: ^testing.T) {
	json := doc(typedefs = list(
		`{"name": "ImWchar32", "type": {"description": {"kind": "Builtin", "builtin_type": "unsigned_int"}}}`,
		`{"name": "ImWchar16", "type": {"description": {"kind": "Builtin", "builtin_type": "unsigned_short"}}}`,
		`{"name": "ImWchar", "type": {"description": {"kind": "User", "name": "ImWchar32"}}, "conditionals": [{"condition": "ifdef", "expression": "IMGUI_USE_WCHAR32"}]}`,
		`{"name": "ImWchar", "type": {"description": {"kind": "User", "name": "ImWchar16"}}, "conditionals": [{"condition": "ifndef", "expression": "IMGUI_USE_WCHAR32"}]}`,
		`{"name": "ImOld", "type": {"description": {"kind": "Builtin", "builtin_type": "int"}}, "conditionals": [{"condition": "ifndef", "expression": "IMGUI_DISABLE_OBSOLETE_FUNCTIONS"}]}`,
		`{"name": "ImMsvc", "type": {"description": {"kind": "Builtin", "builtin_type": "int"}}, "conditionals": [{"condition": "if", "expression": "defined(_MSC_VER)&&(_MSC_VER >= 1915)"}]}`,
	))
	expect_output(t, json, "Wchar :: u16")
	expect_output(t, json, "Wchar :: u32", config = CONFIG + "#define IMGUI_USE_WCHAR32\n")
	expect_missing(t, json, "Old ::")
	expect_missing(t, json, "Msvc ::")
	expect_error(t, doc(typedefs = `{"name": "ImX", "type": {"description": {"kind": "Builtin", "builtin_type": "int"}}, "conditionals": [{"condition": "if", "expression": "FOO > 1"}]}`), "unknown condition '#if FOO > 1'")
}

@(test)
test_defaults :: proc(t: ^testing.T) {
	expect_output(t, doc(
		enums = enum_("ImGuiCond_", false, element("ImGuiCond_None", 0), element("ImGuiCond_Always", 1)),
		typedefs = typedef("ImGuiCond", builtin("int")),
		structs = struct_("ImVec2", field("x", builtin("float")), field("y", builtin("float"))),
		functions = function("ImGui_F", builtin("void"),
			arg("p", pointer(builtin("bool")), `, "default_value": "NULL"`),
			arg("b", builtin("bool"), `, "default_value": "false"`),
			arg("cond", user("ImGuiCond"), `, "default_value": "0"`),
			arg("size", user("ImVec2"), `, "default_value": "ImVec2(-FLT_MIN, 0)"`),
			arg("speed", builtin("float"), `, "default_value": "1.0f"`),
			arg("min", builtin("float"), `, "default_value": "-1.f"`),
			arg("max", builtin("float"), `, "default_value": "FLT_MAX"`),
			arg("format", pointer(const_char), `, "default_value": "\"%.3f\""`),
			arg("stride", builtin("int"), `, "default_value": "sizeof(float)"`),
		),
	), `F :: proc(p: ^bool = nil, b: bool = false, cond: Cond = .None, size: Vec2 = {-1.17549435e-38, 0}, speed: f32 = 1.0, min: f32 = -1.0, max: f32 = max(f32), format: cstring = "%.3f", stride: c.int = size_of(f32)) ---`)
	expect_error(t, doc(functions = function("ImGui_F", builtin("void"), arg("x", builtin("int"), `, "default_value": "SOMETHING"`))), "unsupported default value 'SOMETHING'")
}

@(test)
test_wrappers :: proc(t: ^testing.T) {
	expect_output(t, doc(functions = list(
		function("ImGui_TextUnformatted", builtin("void"), arg("text", pointer(const_char)), arg("text_end", pointer(const_char), `, "default_value": "NULL"`)),
		function("ImGui_Text", builtin("void"), arg("fmt", pointer(const_char)), `{"name": "...", "is_varargs": true}`),
		function("ImGui_TreeNodeStr", builtin("bool"), arg("str_id", pointer(const_char)), arg("fmt", pointer(const_char)), `{"name": "...", "is_varargs": true}`),
		function("ImGui_TreeNodeStrUnformatted", builtin("bool"), arg("str_id", pointer(const_char)), arg("text", pointer(const_char))),
		function("ImGui_TextV", builtin("void"), arg("fmt", pointer(const_char)), arg("args", user("va_list"))),
	)),
		"@(link_name = \"ImGui_TextUnformatted\")\n\tRawTextUnformatted :: proc(text: cstring, text_end: cstring = nil) ---",
		"TextUnformatted :: proc(text: string) {\n\t_begin, _end := string_range(text)\n\tRawTextUnformatted(_begin, _end)\n}",
		"RawText :: proc(fmt_: cstring, #c_vararg args: ..any) ---",
		"Text :: proc(format: string, args: ..any) {\n\tTextUnformatted(fmt.tprintf(format, ..args))\n}",
		"TreeNodeStr :: proc(str_id: cstring, format: string, args: ..any) -> bool {\n\treturn TreeNodeStrUnformatted(str_id, fmt.ctprintf(format, ..args))\n}",
	)
	expect_missing(t, doc(functions = function("ImGui_TextV", builtin("void"), arg("fmt", pointer(const_char)), arg("args", user("va_list")))), "TextV")
}

@(test)
test_struct_layouts :: proc(t: ^testing.T) {
	expect_output(t, doc(
		typedefs = typedef("ImGuiID", builtin("unsigned_int")),
		structs = list(
			struct_("ImFontGlyph",
				field("Colored", builtin("unsigned_int"), `, "width": 1`),
				field("Codepoint", builtin("unsigned_int"), `, "width": 31`),
				field("AdvanceX", builtin("float")),
			),
			fmt.tprintf(`{{"name": "__anonymous_type0", "kind": "union", "is_anonymous": true, "fields": [%s, %s]}}`, field("val_i", builtin("int")), field("val_p", pointer(builtin("void")))),
			struct_("ImGuiStoragePair", field("key", user("ImGuiID")), field("__anonymous_type0", user("__anonymous_type0"), `, "is_anonymous": true`)),
			struct_("ImGuiViewport", field("ID", user("ImGuiID")), field("ParentViewportId", user("ImGuiID"))),
		),
	),
		"\tusing _: bit_field u32 {\n\t\tColored: u32 | 1,\n\t\tCodepoint: u32 | 31,\n\t},\n\tAdvanceX: f32,",
		"\tkey: ID,\n\tusing _: struct #raw_union {\n\t\tval_i: c.int,\n\t\tval_p: rawptr,\n\t},",
		// A field hides the type of the same name: `ID: ID` does not compile.
		"\tID: _ID,\n\tParentViewportId: _ID,",
		"@(private) _ID :: ID",
	)
}

@(test)
test_errors :: proc(t: ^testing.T) {
	expect_error(t, doc(functions = function("ImGui_F", user("ImUnknown"))), "unknown C type 'ImUnknown'")
	expect_error(t, doc(functions = list(function("ImGui_F", builtin("void")), function("ImGui_F", builtin("void")))), "two declarations are named 'F'")
	expect_error(t, "[", "invalid JSON")
}

// The committed bindings and ABI check must be what the generator makes from the committed JSON.
@(test)
test_generated_is_up_to_date :: proc(t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	read :: proc(t: ^testing.T, path: string) -> (string, bool) {
		data, err := os.read_entire_file(path, context.allocator)
		testing.expectf(t, err == nil, "cannot read %s: %v", path, err)
		return string(data), err == nil
	}
	json, json_ok := read(t, JSON_PATH)
	config, config_ok := read(t, CONFIG_PATH)
	if !json_ok || !config_ok {
		return
	}
	out, err := generate(json, config, "upstream/dear_bindings/dcimgui_nodefaultargfunctions.json")
	if !testing.expectf(t, err == "", "generate failed: %s", err) {
		return
	}
	files := [?]struct {
		path, want: string,
	}{{GENERATED_PATH, out.bindings}, {ABI_C_PATH, out.abi_c}, {ABI_ODIN_PATH, out.abi_odin}}
	for f in files {
		committed := read(t, f.path) or_continue
		testing.expectf(t, committed == f.want, "%s is not up to date: run tools/update_imgui.sh", f.path)
	}
}
