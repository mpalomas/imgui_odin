// Generates the Odin bindings of Dear ImGui from dear_bindings' dcimgui.json, and the ABI check that
// compares them with the C API.
//
// Usage: odin run tools/gen -- <dcimgui.json> <imconfig.h> <output.odin> <abi dir>
//   Writes <abi dir>/abi_check.c and <abi dir>/odin/main.odin.
package main

import vmem "core:mem/virtual"
import "core:fmt"
import "core:os"

main :: proc() {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)

	if len(os.args) != 5 {
		fmt.eprintln("usage: gen <dcimgui.json> <imconfig.h> <output.odin> <abi dir>")
		os.exit(2)
	}
	json_path, config_path, out_path, abi_dir := os.args[1], os.args[2], os.args[3], os.args[4]

	read :: proc(path: string) -> string {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("gen: cannot read %s: %v", path, err)
			os.exit(1)
		}
		return string(data)
	}
	write :: proc(path, data: string) {
		if err := os.write_entire_file(path, transmute([]u8)data); err != nil {
			fmt.eprintfln("gen: cannot write %s: %v", path, err)
			os.exit(1)
		}
	}

	out, err := generate(read(json_path), read(config_path), json_path)
	if err != "" {
		fmt.eprintfln("gen: %s: %s", json_path, err)
		os.exit(1)
	}
	write(out_path, out.bindings)
	if mkdir_err := os.make_directory_all(fmt.tprintf("%s/odin", abi_dir)); mkdir_err != nil && mkdir_err != .Exist {
		fmt.eprintfln("gen: cannot create %s/odin: %v", abi_dir, mkdir_err)
		os.exit(1)
	}
	write(fmt.tprintf("%s/abi_check.c", abi_dir), out.abi_c)
	write(fmt.tprintf("%s/odin/main.odin", abi_dir), out.abi_odin)
}
