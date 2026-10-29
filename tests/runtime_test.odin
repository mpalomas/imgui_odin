// Runs Dear ImGui through the bindings, headless: no window and no GPU, so it runs on CI runners. Needs
// the library (tools/build_imgui.sh or tools/fetch_imgui_libs.sh).
//
//   odin test tests
package imgui_tests

import "core:c"
import "core:strings"
import "core:sync"
import "core:testing"
import im "../imgui"

// The ImGui context is a global of the library, and tests run on several threads.
@(private = "file")
context_mutex: sync.Mutex

// Creates a context for a headless frame loop, as a backend would set it up.
@(private = "file")
create_context :: proc() -> ^im.IO {
	im.CreateContext()
	io := im.GetIO()
	io.DisplaySize = {1280, 720}
	io.DeltaTime = 1.0 / 60
	io.IniFilename = nil
	io.ConfigFlags += {.DockingEnable, .NavEnableKeyboard}
	// Required with IMGUI_DISABLE_OBSOLETE_FUNCTIONS: the font atlas grows as glyphs are used.
	io.BackendFlags += {.RendererHasTextures}
	return io
}

// Plays the renderer backend: marks the requested textures as created, updated or destroyed.
@(private = "file")
update_textures :: proc() {
	for tex in im.vector_slice(im.GetPlatformIO().Textures) {
		#partial switch tex.Status {
		case .WantCreate, .WantUpdates:
			im.TextureData_SetTexID(tex, im.TextureID(uintptr(tex.UniqueID) + 1))
			im.TextureData_SetStatus(tex, .OK)
		case .WantDestroy:
			im.TextureData_SetTexID(tex, im.TextureID_Invalid)
			im.TextureData_SetStatus(tex, .Destroyed)
		}
	}
}

@(test)
test_version :: proc(t: ^testing.T) {
	sync.guard(&context_mutex)
	im.CreateContext()
	defer im.DestroyContext()

	testing.expect(t, im.CHECKVERSION())
	testing.expect_value(t, string(im.GetVersion()), im.VERSION)
	testing.expect(t, im.DearBindings_GetVersionNumber() > 0)
}

@(test)
test_frames :: proc(t: ^testing.T) {
	sync.guard(&context_mutex)
	io := create_context()
	defer im.DestroyContext()

	checked, value, color := true, f32(0.5), im.Vec4{1, 0.5, 0, 1}
	item := c.int(1)
	for frame in 0 ..< 3 {
		im.NewFrame()
		im.DockSpaceOverViewport()
		im.SetNextWindowPos({20, 20}, .Once)
		if im.Begin("Test", nil, {.NoSavedSettings}) {
			im.Text("Frame %d, %.1f fps", frame, io.Framerate)
			im.TextColored({1, 1, 0, 1}, "Colored %s", "text")
			im.TextUnformatted("Not null-terminated: HelloWorld"[:25])
			im.Button("Button")
			im.Button("Sized", {100, 0})
			im.Checkbox("Checkbox", &checked)
			im.SliderFloat("Slider", &value, 0, 1)
			im.ColorEdit4("Color", &color, {.NoInputs})
			im.Combo("Combo", &item, "One\x00Two\x00Three\x00\x00")
			if im.TreeNodeStr("node", "Tree node %d", 1) {
				im.BulletText("Bullet %v", true)
				im.TreePop()
			}
			if im.BeginTable("Table", 2, im.TableFlags_SizingFixedFit + im.TableFlags_Borders + {.RowBg}) {
				im.TableSetupColumn("Name")
				im.TableSetupColumn("Value")
				im.TableHeadersRow()
				for row in 0 ..< 4 {
					im.TableNextRow()
					im.TableNextColumn()
					im.Text("Row %d", row)
					im.TableNextColumn()
					im.ProgressBar(f32(row) / 4, {-1, 0})
				}
				im.EndTable()
			}
			draw_list := im.GetWindowDrawList()
			p := im.GetCursorScreenPos()
			im.DrawList_AddRectFilled(draw_list, p, p + {50, 20}, im.col32(255, 0, 0, 255), 4, im.DrawFlags_RoundTop)
			im.DrawList_AddText(draw_list, p, im.COL32_WHITE, "Drawn")
			im.Dummy({50, 20})
		}
		im.End()
		im.ShowDemoWindow()
		im.Render()
		update_textures()
	}

	dd := im.GetDrawData()
	testing.expect(t, dd.Valid)
	testing.expect(t, dd.CmdLists.Size > 0)
	testing.expect(t, dd.TotalVtxCount > 0 && dd.TotalIdxCount > 0)
	testing.expect_value(t, dd.DisplaySize, io.DisplaySize)
	vtx := 0
	for list in im.vector_slice(dd.CmdLists) {
		vtx += int(list.VtxBuffer.Size)
		for cmd in im.vector_slice(list.CmdBuffer) {
			testing.expect(t, cmd.ElemCount > 0 || cmd.UserCallback != nil)
		}
	}
	testing.expect_value(t, vtx, int(dd.TotalVtxCount))
	for tex in im.vector_slice(im.GetPlatformIO().Textures) {
		testing.expect_value(t, tex.Status, im.TextureStatus.OK)
		testing.expect_value(t, tex.Format, im.TextureFormat.RGBA32)
		testing.expect(t, tex.Width > 0 && tex.Height > 0)
	}
}

@(test)
test_strings :: proc(t: ^testing.T) {
	sync.guard(&context_mutex)
	create_context()
	defer im.DestroyContext()
	im.NewFrame()
	defer im.EndFrame()

	hello := im.CalcTextSize("Hello")
	testing.expect(t, hello.x > 0 && hello.y > 0)
	// The wrappers pass the string's end: a slice of a longer string measures as the slice.
	testing.expect_value(t, im.CalcTextSize("HelloWorld"[:5]), hello)
	testing.expect_value(t, im.CalcTextSize("").x, 0)
	// `##` hides the rest of a label.
	testing.expect_value(t, im.CalcTextSize("Hello##id", true), hello)
	// Emoji: IMGUI_USE_WCHAR32 makes Wchar 32-bit.
	testing.expect_value(t, size_of(im.Wchar), 4)

	buf: im.TextBuffer
	defer im.Vector_Destruct(&buf.Buf)
	im.TextBuffer_appendf(&buf, "%d-%s", 42, "ok")
	im.TextBuffer_append(&buf, "|tail")
	testing.expect_value(t, string(im.TextBuffer_c_str(&buf)), "42-ok|tail")
	im.TextBuffer_clear(&buf)
	testing.expect_value(t, string(im.TextBuffer_c_str(&buf)), "")

	testing.expect_value(t, im.GetIDStr("abc"), im.GetID("abc"))
	testing.expect(t, im.GetIDStr("abc") != im.GetIDStr("abcd"))
}

@(test)
test_storage :: proc(t: ^testing.T) {
	sync.guard(&context_mutex)
	storage: im.Storage
	defer im.Vector_Destruct(&storage.Data)

	im.Storage_SetInt(&storage, 1, 10)
	im.Storage_SetFloat(&storage, 2, 2.5)
	im.Storage_SetBool(&storage, 3, true)
	testing.expect_value(t, im.Storage_GetInt(&storage, 1), 10)
	testing.expect_value(t, im.Storage_GetFloat(&storage, 2), 2.5)
	testing.expect_value(t, im.Storage_GetBool(&storage, 3), true)
	testing.expect_value(t, im.Storage_GetInt(&storage, 99, -1), -1)
	// The pairs' anonymous union.
	pairs := im.vector_slice(storage.Data)
	testing.expect_value(t, len(pairs), 3)
	testing.expect_value(t, pairs[0].val_i, 10)
	testing.expect_value(t, pairs[1].val_f, 2.5)
}

@(test)
test_style :: proc(t: ^testing.T) {
	sync.guard(&context_mutex)
	create_context()
	defer im.DestroyContext()

	style := im.GetStyle()
	im.StyleColorsLight(style)
	light := style.Colors[.WindowBg]
	im.StyleColorsDark(style)
	testing.expect(t, style.Colors[.WindowBg] != light)
	style.Colors[.Text] = {1, 0, 0, 1}
	testing.expect_value(t, im.GetStyleColorVec4(.Text)^, im.Vec4{1, 0, 0, 1})
	testing.expect_value(t, string(im.GetStyleColorName(.WindowBg)), "WindowBg")
	testing.expect_value(t, len(style.Colors), im.Col_COUNT)
}

@(test)
test_input :: proc(t: ^testing.T) {
	sync.guard(&context_mutex)
	io := create_context()
	defer im.DestroyContext()
	// Apply all the events of a frame in that frame, instead of one change of each input per frame.
	io.ConfigInputTrickleEventQueue = false
	// On by default on macOS, where it swaps Ctrl and Cmd.
	io.ConfigMacOSXBehaviors = false

	for frame in 0 ..< 2 {
		im.IO_AddKeyEvent(io, .Mod_Ctrl, frame == 1)
		im.IO_AddKeyEvent(io, .S, frame == 1)
		im.IO_AddMousePosEvent(io, 10, 20)
		im.IO_AddInputCharactersUTF8(io, "é😀")
		im.NewFrame()
		if frame == 1 {
			testing.expect(t, im.IsKeyDown(.S))
			testing.expect(t, im.IsKeyChordPressed(im.key_chord(.S, .Mod_Ctrl)))
			testing.expect_value(t, im.GetMousePos(), im.Vec2{10, 20})
			testing.expect(t, io.KeyCtrl)
		}
		im.EndFrame()
	}
	name := string(im.GetKeyName(.Escape))
	testing.expect(t, strings.contains(name, "Esc"))
}
