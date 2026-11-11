// Runs imgui_impl_sdl3 on SDL's dummy video driver: a window that is never shown, with SDL events pushed into SDL's queue.
// Needs the Dear ImGui library and sdl3_odin with its libraries (its tools/fetch_sdl3_libs.sh):
//
//   odin test tests/sdl3 -collection:sdl3=<sdl3_odin>
package imgui_sdl3_tests

import "core:strings"
import "core:sync"
import "core:testing"
import sdl "sdl3:sdl3"
import im "../../imgui"
import "../../imgui/imgui_impl_sdl3"

// SDL and the ImGui context are process-wide, and tests run on several threads.
@(private = "file")
test_mutex: sync.Mutex

// Fixture is a dummy-driver window with an ImGui context and the backend on it.
@(private = "file")
Fixture :: struct {
	window: ^sdl.Window,
	io:     ^im.IO,
}

@(private = "file")
fixture_start :: proc(t: ^testing.T) -> (fixture: Fixture, ok: bool) {
	sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "dummy")
	if !testing.expectf(t, sdl.Init({.VIDEO, .GAMEPAD}), "SDL_Init: %s", sdl.GetError()) {
		return
	}
	fixture.window = sdl.CreateWindow("imgui_impl_sdl3 test", 640, 480, {})
	if !testing.expectf(t, fixture.window != nil, "SDL_CreateWindow: %s", sdl.GetError()) {
		sdl.Quit()
		return
	}
	im.CreateContext()
	fixture.io = im.GetIO()
	fixture.io.IniFilename = nil
	fixture.io.BackendFlags += {.RendererHasTextures}
	if !testing.expect(t, imgui_impl_sdl3.InitForOther(fixture.window)) {
		fixture_stop(fixture)
		return
	}
	return fixture, true
}

@(private = "file")
fixture_stop :: proc(fixture: Fixture) {
	if im.GetIO().BackendPlatformUserData != nil {
		imgui_impl_sdl3.Shutdown()
	}
	im.DestroyContext()
	sdl.DestroyWindow(fixture.window)
	sdl.Quit()
}

// frame gives the queued SDL events to the backend and runs a frame. It returns how many were the backend's.
@(private = "file")
frame :: proc() -> (taken: int) {
	event: sdl.Event
	for sdl.PollEvent(&event) {
		if imgui_impl_sdl3.ProcessEvent(&event) {
			taken += 1
		}
	}
	imgui_impl_sdl3.NewFrame()
	im.NewFrame()
	im.Render()
	return
}

@(private = "file")
push :: proc(event: sdl.Event) {
	pushed := event
	sdl.PushEvent(&pushed)
}

@(test)
test_init_and_frames :: proc(t: ^testing.T) {
	sync.guard(&test_mutex)
	fixture, ok := fixture_start(t)
	if !ok {
		return
	}
	defer fixture_stop(fixture)
	io := fixture.io
	testing.expect(t, strings.has_prefix(string(io.BackendPlatformName), "imgui_impl_sdl3 (odin, 3."))
	testing.expect(t, .HasMouseCursors in io.BackendFlags)
	frame()
	frame()
	testing.expect_value(t, io.DisplaySize, im.Vec2{640, 480})
	testing.expect_value(t, io.DisplayFramebufferScale, im.Vec2{1, 1})
	testing.expect(t, io.DeltaTime > 0)
}

@(test)
test_events :: proc(t: ^testing.T) {
	sync.guard(&test_mutex)
	fixture, ok := fixture_start(t)
	if !ok {
		return
	}
	defer fixture_stop(fixture)
	io := fixture.io
	id := sdl.GetWindowID(fixture.window)
	frame()

	// MOUSE
	push({motion = {type = .MOUSE_MOTION, windowID = id, x = 100, y = 50}})
	push({button = {type = .MOUSE_BUTTON_DOWN, windowID = id, button = u8(sdl.BUTTON_RIGHT), down = true}})
	push({wheel = {type = .MOUSE_WHEEL, windowID = id, x = 1, y = 2}})
	testing.expect_value(t, frame(), 3)
	testing.expect_value(t, io.MousePos, im.Vec2{100, 50})
	testing.expect(t, im.IsMouseDown(.Right) && !im.IsMouseDown(.Left))

	// KEYS: the keypad by scancode, letters by keycode, OEM keys by scancode.
	push({key = {type = .KEY_DOWN, windowID = id, scancode = .KP_7, key = sdl.K_HOME, down = true}})
	push({key = {type = .KEY_DOWN, windowID = id, scancode = .Q, key = sdl.K_A, mod = sdl.KMOD_CTRL, down = true}})
	frame()
	testing.expect(t, im.IsKeyDown(.Keypad7) && !im.IsKeyDown(.Home))
	testing.expect(t, im.IsKeyDown(.A))
	// Dear ImGui swaps Ctrl and Cmd itself on macOS (io.ConfigMacOSXBehaviors).
	testing.expect(t, io.KeySuper if ODIN_OS == .Darwin else io.KeyCtrl)
	testing.expect_value(t, imgui_impl_sdl3.KeyEventToImGuiKey(sdl.K_SEMICOLON, .COMMA), im.Key.Semicolon)
	testing.expect_value(t, imgui_impl_sdl3.KeyEventToImGuiKey(sdl.Keycode(0x3c), .NONUSBACKSLASH), im.Key.Oem102)
	testing.expect_value(t, imgui_impl_sdl3.KeyEventToImGuiKey(sdl.K_F17, .F17), im.Key.F17)

	// TEXT goes to the input queue, which a text field reads.
	text := "héllo"
	push({text = {type = .TEXT_INPUT, windowID = id, text = strings.clone_to_cstring(text, context.temp_allocator)}})
	event: sdl.Event
	for sdl.PollEvent(&event) {
		imgui_impl_sdl3.ProcessEvent(&event)
	}
	imgui_impl_sdl3.NewFrame()
	im.NewFrame()
	testing.expect_value(t, len(im.vector_slice(io.InputQueueCharacters)), len("hello"))
	im.Render()

	// Another window's events aren't the backend's.
	push({motion = {type = .MOUSE_MOTION, windowID = id + 1000, x = 1, y = 1}})
	testing.expect_value(t, frame(), 0)
	testing.expect_value(t, io.MousePos, im.Vec2{100, 50})

	// FOCUS
	push({window = {type = .WINDOW_FOCUS_LOST, windowID = id}})
	testing.expect_value(t, frame(), 1)
	testing.expect(t, !im.IsKeyDown(.A)) // focus loss releases the keys
}

@(test)
test_gamepad :: proc(t: ^testing.T) {
	sync.guard(&test_mutex)
	fixture, ok := fixture_start(t)
	if !ok {
		return
	}
	defer fixture_stop(fixture)
	io := fixture.io
	io.ConfigFlags += {.NavEnableGamepad}

	// A virtual gamepad, the only one the backend reads (it reads every gamepad, real ones too).
	desc: sdl.VirtualJoystickDesc
	sdl.INIT_INTERFACE(&desc)
	desc.type = u16(sdl.JoystickType.GAMEPAD)
	desc.naxes, desc.nbuttons = 6, 15
	id := sdl.AttachVirtualJoystick(desc)
	if !testing.expect(t, id != 0) {
		return
	}
	defer sdl.DetachVirtualJoystick(id)
	pad := sdl.OpenGamepad(id)
	defer sdl.CloseGamepad(pad)
	gamepads := [1]^sdl.Gamepad{pad}
	imgui_impl_sdl3.SetGamepadMode(.Manual, gamepads[:])

	sdl.SetJoystickVirtualButton(sdl.GetGamepadJoystick(pad), i32(sdl.GamepadButton.SOUTH), true)
	sdl.SetJoystickVirtualAxis(sdl.GetGamepadJoystick(pad), i32(sdl.GamepadAxis.LEFTX), 32767)
	sdl.UpdateJoysticks()
	frame()
	testing.expect(t, .HasGamepad in io.BackendFlags)
	testing.expect(t, im.IsKeyDown(.GamepadFaceDown))
	testing.expect(t, im.IsKeyDown(.GamepadLStickRight) && !im.IsKeyDown(.GamepadLStickLeft))
	imgui_impl_sdl3.SetGamepadMode(.Auto_First)
}
