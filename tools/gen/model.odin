package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// A type from dcimgui.json's `description` trees.
Type_Kind :: enum {
	Builtin, // `name` is the builtin_type: int, unsigned_int, float...
	User, // `name` is a C type name: ImVec2, ImGuiWindowFlags...
	Pointer, // to `inner`
	Array, // of `inner`, `bounds` elements ("" when unbounded)
	Function, // returning `ret`, taking `params`
	Named, // a named `inner`: a function parameter, or the name of a function pointer field
}

Type :: struct {
	kind:     Type_Kind,
	name:     string,
	is_const: bool,
	inner:    ^Type,
	bounds:   string,
	ret:      ^Type,
	params:   []Type,
}

Comments :: struct {
	preceding: []string,
	attached:  string,
}

Define :: struct {
	name:     string,
	content:  string, // "" when the define has no value
	comments: Comments,
}

Enum_Element :: struct {
	name:       string,
	value:      i64,
	expression: string, // The value as written: `1<<2`, `ImGuiWindowFlags_NoNavInputs | ...`
	is_count:   bool,
	comments:   Comments,
}

Enum :: struct {
	name:     string,
	is_flags: bool,
	elements: []Enum_Element,
	comments: Comments,
}

Typedef :: struct {
	name:     string,
	type:     Type,
	comments: Comments,
}

Field :: struct {
	name:         string,
	type:         Type,
	width:        int, // Bitfield width, 0 for ordinary fields.
	is_anonymous: bool, // An anonymous union: `type` names its struct.
	comments:     Comments,
}

Struct :: struct {
	name:         string,
	is_union:     bool,
	is_anonymous: bool,
	is_forward:   bool, // Declared only: an opaque type.
	fields:       []Field,
	comments:     Comments,
}

Param :: struct {
	name:          string,
	type:          Type,
	is_varargs:    bool,
	is_array:      bool,
	default_value: string,
	has_default:   bool,
}

Function :: struct {
	name:     string,
	ret:      Type,
	params:   []Param,
	comments: Comments,
}

IR :: struct {
	defines:   [dynamic]Define,
	enums:     [dynamic]Enum,
	typedefs:  [dynamic]Typedef,
	structs:   [dynamic]Struct,
	functions: [dynamic]Function,
}

// The `#define`s of imconfig_odin.h. Only `#define NAME` and `#define NAME VALUE` lines are read.
Config :: map[string]string

parse_config :: proc(src: string) -> Config {
	config := make(Config)
	for line in strings.split_lines(src) {
		fields := strings.fields(strings.trim_space(line))
		if len(fields) >= 2 && fields[0] == "#define" {
			config[fields[1]] = strings.join(fields[2:], " ") if len(fields) > 2 else ""
		}
	}
	return config
}

// `#if` expressions of dcimgui.json that are not `defined(NAME)`, and their value with Clang or GCC.
KNOWN_CONDITIONS :: [?]struct {
	expression: string,
	value:      bool,
}{
	{"defined(_MSC_VER)&&!defined(__clang__)&&!defined(__INTEL_COMPILER)&&!defined(IMGUI_DEBUG_PARANOID)", false},
	{"(defined(__clang__)&&(__clang_major__ >= 7))||(defined(__GNUC__)&&(__GNUC__>4 ||(__GNUC__ == 4 && __GNUC_MINOR__ >= 8)))", true},
	{"defined(_MSC_VER)&&(_MSC_VER >= 1915)", false},
}

Loader :: struct {
	config: Config,
	err:    string,
}

@(private = "file")
fail :: proc(l: ^Loader, format: string, args: ..any) {
	if l.err == "" {
		l.err = fmt.aprintf(format, ..args)
	}
}

// Parses dcimgui.json, keeping only the declarations whose `#if` conditions hold with `config`.
load :: proc(src: string, config: Config) -> (ir: ^IR, err: string) {
	value, json_err := json.parse_string(src, parse_integers = true)
	if json_err != nil {
		return nil, fmt.aprintf("invalid JSON: %v", json_err)
	}
	root, is_object := value.(json.Object)
	if !is_object {
		return nil, "the JSON root is not an object"
	}
	l := Loader{config = config}
	ir = new(IR)

	for d in array(root, "defines") {
		if !conditions_hold(&l, d) {
			continue
		}
		append(&ir.defines, Define{str(d, "name"), str(d, "content"), comments(d)})
	}
	for e in array(root, "enums") {
		if !conditions_hold(&l, e) {
			continue
		}
		en := Enum{name = str(e, "name"), is_flags = boolean(e, "is_flags_enum"), comments = comments(e)}
		elements := make([dynamic]Enum_Element)
		for el in array(e, "elements") {
			if !conditions_hold(&l, el) {
				continue
			}
			append(&elements, Enum_Element{str(el, "name"), integer(el, "value"), str(el, "value_expression"), boolean(el, "is_count"), comments(el)})
		}
		en.elements = elements[:]
		append(&ir.enums, en)
	}
	for t in array(root, "typedefs") {
		if !conditions_hold(&l, t) {
			continue
		}
		append(&ir.typedefs, Typedef{str(t, "name"), parse_type(&l, object(object(t, "type"), "description")), comments(t)})
	}
	for s in array(root, "structs") {
		if !conditions_hold(&l, s) {
			continue
		}
		st := Struct {
			name         = str(s, "name"),
			is_union     = str(s, "kind") == "union",
			is_anonymous = boolean(s, "is_anonymous"),
			is_forward   = boolean(s, "forward_declaration"),
			comments     = comments(s),
		}
		fields := make([dynamic]Field)
		for f in array(s, "fields") {
			if !conditions_hold(&l, f) {
				continue
			}
			field := Field {
				name         = str(f, "name"),
				type         = parse_type(&l, object(object(f, "type"), "description")),
				width        = int(integer(f, "width")),
				is_anonymous = boolean(f, "is_anonymous"),
				comments     = comments(f),
			}
			append(&fields, field)
		}
		st.fields = fields[:]
		append(&ir.structs, st)
	}
	for f in array(root, "functions") {
		if !conditions_hold(&l, f) {
			continue
		}
		fn := Function {
			name     = str(f, "name"),
			ret      = parse_type(&l, object(object(f, "return_type"), "description")),
			comments = comments(f),
		}
		params := make([dynamic]Param)
		for a in array(f, "arguments") {
			p := Param {
				name       = str(a, "name"),
				is_varargs = boolean(a, "is_varargs"),
				is_array   = boolean(a, "is_array"),
			}
			if !p.is_varargs {
				p.type = parse_type(&l, object(object(a, "type"), "description"))
			}
			if dv, ok := a["default_value"]; ok {
				p.default_value, _ = dv.(json.String)
				p.has_default = true
			}
			append(&params, p)
		}
		fn.params = params[:]
		append(&ir.functions, fn)
	}
	return ir, l.err
}

@(private = "file")
conditions_hold :: proc(l: ^Loader, item: json.Object) -> bool {
	for c in array(item, "conditionals") {
		condition, expression := str(c, "condition"), str(c, "expression")
		value: bool
		switch condition {
		case "ifdef", "ifndef":
			_, value = l.config[expression]
		case "if", "ifnot":
			found := false
			if strings.has_prefix(expression, "defined(") && strings.has_suffix(expression, ")") &&
			   strings.count(expression, "(") == 1 {
				_, value = l.config[expression[len("defined("):len(expression) - 1]]
				found = true
			}
			for known in KNOWN_CONDITIONS {
				if known.expression == expression {
					value = known.value
					found = true
				}
			}
			if !found {
				fail(l, "unknown condition '#if %s' on %s: add it to KNOWN_CONDITIONS", expression, str(item, "name"))
			}
		case:
			fail(l, "unknown condition kind '%s' on %s", condition, str(item, "name"))
		}
		if condition == "ifndef" || condition == "ifnot" {
			value = !value
		}
		if !value {
			return false
		}
	}
	return true
}

@(private = "file")
parse_type :: proc(l: ^Loader, d: json.Object) -> Type {
	t := Type{}
	if classes, ok := d["storage_classes"].(json.Array); ok {
		for c in classes {
			if s, is_str := c.(json.String); is_str && s == "const" {
				t.is_const = true
			}
		}
	}
	inner :: proc(l: ^Loader, d: json.Object, key: string) -> ^Type {
		p := new(Type)
		p^ = parse_type(l, object(d, key))
		return p
	}
	switch kind := str(d, "kind"); kind {
	case "Builtin":
		t.kind = .Builtin
		t.name = str(d, "builtin_type")
	case "User":
		t.kind = .User
		t.name = str(d, "name")
	case "Pointer":
		t.kind = .Pointer
		t.inner = inner(l, d, "inner_type")
	case "Array":
		t.kind = .Array
		t.bounds = str(d, "bounds")
		t.inner = inner(l, d, "inner_type")
	case "Type":
		t.kind = .Named
		t.name = str(d, "name")
		t.inner = inner(l, d, "inner_type")
	case "Function":
		t.kind = .Function
		t.ret = inner(l, d, "return_type")
		params := make([dynamic]Type)
		for p in array(d, "parameters") {
			append(&params, parse_type(l, p))
		}
		t.params = params[:]
	case:
		fail(l, "unknown type kind '%s'", kind)
	}
	return t
}

// JSON accessors. A missing key gives the zero value: dcimgui.json omits false and empty values.

@(private = "file")
object :: proc(o: json.Object, key: string) -> json.Object {
	v, _ := o[key].(json.Object)
	return v
}

@(private = "file")
str :: proc(o: json.Object, key: string) -> string {
	v, _ := o[key].(json.String)
	return v
}

@(private = "file")
boolean :: proc(o: json.Object, key: string) -> bool {
	v, _ := o[key].(json.Boolean)
	return v
}

@(private = "file")
integer :: proc(o: json.Object, key: string) -> i64 {
	#partial switch v in o[key] {
	case json.Integer:
		return v
	case json.Float:
		return i64(v)
	}
	return 0
}

// The objects of an array. Its other values are skipped.
@(private = "file")
array :: proc(o: json.Object, key: string) -> []json.Object {
	values, _ := o[key].(json.Array)
	out := make([dynamic]json.Object, 0, len(values))
	for v in values {
		if obj, ok := v.(json.Object); ok {
			append(&out, obj)
		}
	}
	return out[:]
}

@(private = "file")
comments :: proc(o: json.Object) -> Comments {
	c := object(o, "comments")
	out := Comments{attached = str(c, "attached")}
	if preceding, ok := c["preceding"].(json.Array); ok {
		lines := make([dynamic]string, 0, len(preceding))
		for p in preceding {
			if s, is_str := p.(json.String); is_str {
				append(&lines, s)
			}
		}
		out.preceding = lines[:]
	}
	return out
}
