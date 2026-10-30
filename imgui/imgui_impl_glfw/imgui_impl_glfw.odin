// Dear ImGui platform backend for GLFW, on vendor:glfw (GLFW 3.4). An Odin port of
// backends/imgui_impl_glfw.cpp of Dear ImGui 1.93.0 (docking), to use with a renderer backend such as
// imgui_impl_wgpu.
//
// Implemented: clipboard, mouse, keyboard, gamepad (with ConfigFlags.NavEnableGamepad), mouse cursor
// shapes, several Dear ImGui contexts, on Windows touch screen and pen input (imgui_impl_glfw_windows.odin).
// Not ported (yet): multi-viewports (ConfigFlags.ViewportsEnable is ignored; docking works inside the
// main window), the Emscripten specific code.
//
//	imgui_impl_glfw.InitForOther(window)  // After im.CreateContext(), before the renderer's Init.
//	// Each frame, before im.NewFrame():
//	imgui_impl_glfw.NewFrame()
//	// At exit, after the renderer's Shutdown():
//	imgui_impl_glfw.Shutdown()
package imgui_impl_glfw

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:time"
import "vendor:glfw"
import glfw_raw "vendor:glfw/bindings"
import im ".."

@(private)
Client_Api :: enum {
	OpenGL,
	Vulkan,
	Unknown,
}

// Backend data, in io.BackendPlatformUserData.
@(private)
Data :: struct {
	ctx:                                      ^im.Context,
	io:                                       ^im.IO,
	window:                                   glfw.WindowHandle,
	client_api:                               Client_Api,
	time:                                     f64,
	mouse_window:                             glfw.WindowHandle,
	mouse_cursors:                            [im.MouseCursor_COUNT]glfw.CursorHandle,
	last_mouse_cursor:                        glfw.CursorHandle,
	mouse_ignore_button_up_wait_for_focus_loss: bool,
	mouse_ignore_button_up:                   bool,
	last_valid_mouse_pos:                     im.Vec2,
	key_owner_windows:                        [glfw.KEY_LAST]glfw.WindowHandle,
	is_wayland:                               bool,
	installed_callbacks:                      bool,
	callbacks_chain_for_all_windows:          bool,
	platform_name:                            [48]u8,
	allocator:                                runtime.Allocator,

	// The user's callbacks installed before ours, which ours call.
	prev_window_focus:                        glfw.WindowFocusProc,
	prev_cursor_pos:                          glfw.CursorPosProc,
	prev_cursor_enter:                        glfw.CursorEnterProc,
	prev_mouse_button:                        glfw.MouseButtonProc,
	prev_scroll:                              glfw.ScrollProc,
	prev_key:                                 glfw.KeyProc,
	prev_char:                                glfw.CharProc,
	prev_monitor:                             glfw.MonitorProc,

	// Windows: the window procedure before ours (imgui_impl_glfw_windows.odin).
	prev_wndproc:                             rawptr,
}

// The backend data of each GLFW window, whatever the current context: GLFW sends the events of all
// windows together.
@(private)
Window_Entry :: struct {
	window: glfw.WindowHandle,
	data:   ^Data,
}
@(private)
window_map: [dynamic]Window_Entry

// Data for the current context.
@(private)
get_backend_data :: proc "contextless" () -> ^Data {
	return im.GetCurrentContext() != nil ? (^Data)(im.GetIO().BackendPlatformUserData) : nil
}

// Data for a GLFW window.
@(private)
get_window_data :: proc "contextless" (window: glfw.WindowHandle) -> ^Data {
	for entry in window_map {
		if entry.window == window {
			return entry.data
		}
	}
	return nil
}

@(private)
is_wayland :: proc "contextless" () -> bool {
	when ODIN_OS == .Linux {
		return glfw.GetPlatform() == glfw.PLATFORM_WAYLAND
	} else {
		return false
	}
}

KeyToImGuiKey :: proc "contextless" (keycode, scancode: c.int) -> im.Key {
	switch keycode {
	case glfw.KEY_TAB:           return .Tab
	case glfw.KEY_LEFT:          return .LeftArrow
	case glfw.KEY_RIGHT:         return .RightArrow
	case glfw.KEY_UP:            return .UpArrow
	case glfw.KEY_DOWN:          return .DownArrow
	case glfw.KEY_PAGE_UP:       return .PageUp
	case glfw.KEY_PAGE_DOWN:     return .PageDown
	case glfw.KEY_HOME:          return .Home
	case glfw.KEY_END:           return .End
	case glfw.KEY_INSERT:        return .Insert
	case glfw.KEY_DELETE:        return .Delete
	case glfw.KEY_BACKSPACE:     return .Backspace
	case glfw.KEY_SPACE:         return .Space
	case glfw.KEY_ENTER:         return .Enter
	case glfw.KEY_ESCAPE:        return .Escape
	case glfw.KEY_APOSTROPHE:    return .Apostrophe
	case glfw.KEY_COMMA:         return .Comma
	case glfw.KEY_MINUS:         return .Minus
	case glfw.KEY_PERIOD:        return .Period
	case glfw.KEY_SLASH:         return .Slash
	case glfw.KEY_SEMICOLON:     return .Semicolon
	case glfw.KEY_EQUAL:         return .Equal
	case glfw.KEY_LEFT_BRACKET:  return .LeftBracket
	case glfw.KEY_BACKSLASH:     return .Backslash
	case glfw.KEY_WORLD_1:       return .Oem102
	case glfw.KEY_WORLD_2:       return .Oem102
	case glfw.KEY_RIGHT_BRACKET: return .RightBracket
	case glfw.KEY_GRAVE_ACCENT:  return .GraveAccent
	case glfw.KEY_CAPS_LOCK:     return .CapsLock
	case glfw.KEY_SCROLL_LOCK:   return .ScrollLock
	case glfw.KEY_NUM_LOCK:      return .NumLock
	case glfw.KEY_PRINT_SCREEN:  return .PrintScreen
	case glfw.KEY_PAUSE:         return .Pause
	case glfw.KEY_KP_0:          return .Keypad0
	case glfw.KEY_KP_1:          return .Keypad1
	case glfw.KEY_KP_2:          return .Keypad2
	case glfw.KEY_KP_3:          return .Keypad3
	case glfw.KEY_KP_4:          return .Keypad4
	case glfw.KEY_KP_5:          return .Keypad5
	case glfw.KEY_KP_6:          return .Keypad6
	case glfw.KEY_KP_7:          return .Keypad7
	case glfw.KEY_KP_8:          return .Keypad8
	case glfw.KEY_KP_9:          return .Keypad9
	case glfw.KEY_KP_DECIMAL:    return .KeypadDecimal
	case glfw.KEY_KP_DIVIDE:     return .KeypadDivide
	case glfw.KEY_KP_MULTIPLY:   return .KeypadMultiply
	case glfw.KEY_KP_SUBTRACT:   return .KeypadSubtract
	case glfw.KEY_KP_ADD:        return .KeypadAdd
	case glfw.KEY_KP_ENTER:      return .KeypadEnter
	case glfw.KEY_KP_EQUAL:      return .KeypadEqual
	case glfw.KEY_LEFT_SHIFT:    return .LeftShift
	case glfw.KEY_LEFT_CONTROL:  return .LeftCtrl
	case glfw.KEY_LEFT_ALT:      return .LeftAlt
	case glfw.KEY_LEFT_SUPER:    return .LeftSuper
	case glfw.KEY_RIGHT_SHIFT:   return .RightShift
	case glfw.KEY_RIGHT_CONTROL: return .RightCtrl
	case glfw.KEY_RIGHT_ALT:     return .RightAlt
	case glfw.KEY_RIGHT_SUPER:   return .RightSuper
	case glfw.KEY_MENU:          return .Menu
	case glfw.KEY_0 ..= glfw.KEY_9:
		return im.Key(c.int(im.Key._0) + keycode - glfw.KEY_0)
	case glfw.KEY_A ..= glfw.KEY_Z:
		return im.Key(c.int(im.Key.A) + keycode - glfw.KEY_A)
	case glfw.KEY_F1 ..= glfw.KEY_F24:
		return im.Key(c.int(im.Key.F1) + keycode - glfw.KEY_F1)
	}
	return .None
}

// X11 does not include the modifier key being pressed or released in the `mods` of its event.
@(private)
update_key_modifiers :: proc "contextless" (io: ^im.IO, window: glfw.WindowHandle) {
	down :: proc "contextless" (window: glfw.WindowHandle, left, right: c.int) -> bool {
		return glfw.GetKey(window, left) == glfw.PRESS || glfw.GetKey(window, right) == glfw.PRESS
	}
	im.IO_AddKeyEvent(io, .Mod_Ctrl, down(window, glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL))
	im.IO_AddKeyEvent(io, .Mod_Shift, down(window, glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT))
	im.IO_AddKeyEvent(io, .Mod_Alt, down(window, glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT))
	im.IO_AddKeyEvent(io, .Mod_Super, down(window, glfw.KEY_LEFT_SUPER, glfw.KEY_RIGHT_SUPER))
}

@(private)
should_chain_callback :: proc "contextless" (bd: ^Data, window: glfw.WindowHandle) -> bool {
	return bd.callbacks_chain_for_all_windows || window == bd.window
}

MouseButtonCallback :: proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
	bd := get_window_data(window)
	if bd == nil {
		return
	}
	if bd.prev_mouse_button != nil && should_chain_callback(bd, window) {
		bd.prev_mouse_button(window, button, action, mods)
	}
	// Linux: ignore the mouse up events following a focus loss.
	if bd.mouse_ignore_button_up && action == glfw.RELEASE {
		return
	}
	update_key_modifiers(bd.io, window)
	if button >= 0 && button < im.MouseButton_COUNT {
		im.IO_AddMouseButtonEvent(bd.io, button, action == glfw.PRESS)
	}
}

ScrollCallback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	bd := get_window_data(window)
	if bd == nil {
		return
	}
	if bd.prev_scroll != nil && should_chain_callback(bd, window) {
		bd.prev_scroll(window, xoffset, yoffset)
	}
	im.IO_AddMouseWheelEvent(bd.io, f32(xoffset), f32(yoffset))
}

// GLFW 3.1+ "untranslates" keys (the key of an AZERTY keyboard's A is KEY_Q), which makes lettered
// shortcuts hard to use. This translates them back for the printable keys, through their name.
@(private)
translate_untranslated_key :: proc "contextless" (key, scancode: c.int) -> c.int {
	if key >= glfw.KEY_KP_0 && key <= glfw.KEY_KP_EQUAL {
		return key
	}
	prev_error_callback := glfw.SetErrorCallback(nil)
	key_name := glfw_raw.GetKeyName(key, scancode)
	glfw.SetErrorCallback(prev_error_callback)
	glfw_raw.GetError(nil) // Eat the error.
	if key_name == nil {
		return key
	}
	name := ([^]u8)(key_name)
	if name[0] == 0 || name[1] != 0 {
		return key
	}
	char_names := "`-=[]\\,;'./"
	char_keys := [?]c.int{
		glfw.KEY_GRAVE_ACCENT, glfw.KEY_MINUS, glfw.KEY_EQUAL, glfw.KEY_LEFT_BRACKET, glfw.KEY_RIGHT_BRACKET,
		glfw.KEY_BACKSLASH, glfw.KEY_COMMA, glfw.KEY_SEMICOLON, glfw.KEY_APOSTROPHE, glfw.KEY_PERIOD, glfw.KEY_SLASH,
	}
	#assert(len(char_keys) == 11)
	switch ch := name[0]; {
	case ch >= '0' && ch <= '9':
		return glfw.KEY_0 + c.int(ch - '0')
	case ch >= 'A' && ch <= 'Z':
		return glfw.KEY_A + c.int(ch - 'A')
	case ch >= 'a' && ch <= 'z':
		return glfw.KEY_A + c.int(ch - 'a')
	case:
		for i in 0 ..< len(char_names) {
			if char_names[i] == ch {
				return char_keys[i]
			}
		}
	}
	return key
}

KeyCallback :: proc "c" (window: glfw.WindowHandle, keycode, scancode, action, mods: c.int) {
	bd := get_window_data(window)
	if bd == nil {
		return
	}
	if bd.prev_key != nil && should_chain_callback(bd, window) {
		bd.prev_key(window, keycode, scancode, action, mods)
	}
	if action != glfw.PRESS && action != glfw.RELEASE {
		return
	}
	update_key_modifiers(bd.io, window)
	if keycode >= 0 && int(keycode) < len(bd.key_owner_windows) {
		bd.key_owner_windows[keycode] = window if action == glfw.PRESS else nil
	}
	keycode := translate_untranslated_key(keycode, scancode)
	imgui_key := KeyToImGuiKey(keycode, scancode)
	im.IO_AddKeyEvent(bd.io, imgui_key, action == glfw.PRESS)
	im.IO_SetKeyEventNativeData(bd.io, imgui_key, keycode, scancode)
}

WindowFocusCallback :: proc "c" (window: glfw.WindowHandle, focused: c.int) {
	bd := get_window_data(window)
	if bd == nil {
		return
	}
	if bd.prev_window_focus != nil && should_chain_callback(bd, window) {
		bd.prev_window_focus(window, focused)
	}
	// Linux: when losing focus with mouse_ignore_button_up_wait_for_focus_loss set, ignore the mouse up
	// events that follow.
	bd.mouse_ignore_button_up = bd.mouse_ignore_button_up_wait_for_focus_loss && focused == 0
	bd.mouse_ignore_button_up_wait_for_focus_loss = false
	im.IO_AddFocusEvent(bd.io, focused != 0)
}

CursorPosCallback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	bd := get_window_data(window)
	if bd == nil {
		return
	}
	if bd.prev_cursor_pos != nil && should_chain_callback(bd, window) {
		bd.prev_cursor_pos(window, x, y)
	}
	im.IO_AddMousePosEvent(bd.io, f32(x), f32(y))
	bd.last_valid_mouse_pos = {f32(x), f32(y)}
}

// X11 sends spurious leave and enter events, which would lose the mouse position: it is saved on leave
// and restored on enter.
CursorEnterCallback :: proc "c" (window: glfw.WindowHandle, entered: c.int) {
	bd := get_window_data(window)
	if bd == nil {
		return
	}
	if bd.prev_cursor_enter != nil && should_chain_callback(bd, window) {
		bd.prev_cursor_enter(window, entered)
	}
	if entered != 0 {
		bd.mouse_window = window
		im.IO_AddMousePosEvent(bd.io, bd.last_valid_mouse_pos.x, bd.last_valid_mouse_pos.y)
	} else if bd.mouse_window == window {
		bd.last_valid_mouse_pos = bd.io.MousePos
		bd.mouse_window = nil
		im.IO_AddMousePosEvent(bd.io, -max(f32), -max(f32))
	}
}

CharCallback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	bd := get_window_data(window)
	if bd == nil {
		return
	}
	if bd.prev_char != nil && should_chain_callback(bd, window) {
		bd.prev_char(window, codepoint)
	}
	im.IO_AddInputCharacter(bd.io, u32(codepoint))
}

// Part of the API, unused: monitors only matter with multi-viewports.
MonitorCallback :: proc "c" (monitor: glfw.MonitorHandle, event: c.int) {}

InstallCallbacks :: proc(window: glfw.WindowHandle) {
	bd := get_window_data(window)
	assert(bd != nil && bd.window == window, "imgui_impl_glfw: not the window of the backend")
	assert(!bd.installed_callbacks, "imgui_impl_glfw: callbacks already installed")
	bd.prev_window_focus = glfw.SetWindowFocusCallback(window, WindowFocusCallback)
	bd.prev_cursor_enter = glfw.SetCursorEnterCallback(window, CursorEnterCallback)
	bd.prev_cursor_pos = glfw.SetCursorPosCallback(window, CursorPosCallback)
	bd.prev_mouse_button = glfw.SetMouseButtonCallback(window, MouseButtonCallback)
	bd.prev_scroll = glfw.SetScrollCallback(window, ScrollCallback)
	bd.prev_key = glfw.SetKeyCallback(window, KeyCallback)
	bd.prev_char = glfw.SetCharCallback(window, CharCallback)
	bd.prev_monitor = glfw.SetMonitorCallback(MonitorCallback)
	bd.installed_callbacks = true
}

RestoreCallbacks :: proc(window: glfw.WindowHandle) {
	bd := get_window_data(window)
	assert(bd != nil && bd.window == window, "imgui_impl_glfw: not the window of the backend")
	assert(bd.installed_callbacks, "imgui_impl_glfw: callbacks not installed")
	glfw.SetWindowFocusCallback(window, bd.prev_window_focus)
	glfw.SetCursorEnterCallback(window, bd.prev_cursor_enter)
	glfw.SetCursorPosCallback(window, bd.prev_cursor_pos)
	glfw.SetMouseButtonCallback(window, bd.prev_mouse_button)
	glfw.SetScrollCallback(window, bd.prev_scroll)
	glfw.SetKeyCallback(window, bd.prev_key)
	glfw.SetCharCallback(window, bd.prev_char)
	glfw.SetMonitorCallback(bd.prev_monitor)
	bd.installed_callbacks = false
	bd.prev_window_focus = nil
	bd.prev_cursor_enter = nil
	bd.prev_cursor_pos = nil
	bd.prev_mouse_button = nil
	bd.prev_scroll = nil
	bd.prev_key = nil
	bd.prev_char = nil
	bd.prev_monitor = nil
}

// By default, our callbacks only call the user's previous ones for the main window. With true, they call
// them for every window: the user's callbacks must then check their `window` parameter.
SetCallbacksChainForAllWindows :: proc(chain_for_all_windows: bool) {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_glfw: not initialized")
	bd.callbacks_chain_for_all_windows = chain_for_all_windows
}

@(private)
init :: proc(window: glfw.WindowHandle, install_callbacks: bool, client_api: Client_Api) -> bool {
	io := im.GetIO()
	if !im.CHECKVERSION() {
		return false
	}
	assert(io.BackendPlatformUserData == nil, "imgui_impl_glfw: a platform backend is already initialized")

	bd := new(Data)
	bd.ctx = im.GetCurrentContext()
	bd.io = io
	bd.window = window
	bd.is_wayland = is_wayland()
	bd.client_api = client_api
	bd.allocator = context.allocator
	if window_map.allocator.procedure == nil {
		window_map.allocator = runtime.heap_allocator()
	}
	append(&window_map, Window_Entry{window, bd})

	fmt.bprintf(bd.platform_name[:len(bd.platform_name) - 1], "imgui_impl_glfw (odin, %d%d%d)%s",
		glfw.VERSION_MAJOR, glfw.VERSION_MINOR, glfw.VERSION_REVISION, " (Wayland)" if bd.is_wayland else "")
	io.BackendPlatformUserData = bd
	io.BackendPlatformName = cstring(&bd.platform_name[0])
	io.BackendFlags += {.HasMouseCursors, .HasSetMousePos}

	platform_io := im.GetPlatformIO()
	platform_io.Platform_SetClipboardTextFn = proc "c" (ctx: ^im.Context, text: cstring) {
		glfw.SetClipboardString(nil, text)
	}
	platform_io.Platform_GetClipboardTextFn = proc "c" (ctx: ^im.Context) -> cstring {
		return glfw_raw.GetClipboardString(nil)
	}

	// On X11, cursors are user configurable and some may be missing: GLFW then reports an error, which
	// is silenced here, and update_mouse_cursor uses the arrow instead.
	prev_error_callback := glfw.SetErrorCallback(nil)
	shapes := [im.MouseCursor_COUNT]c.int {
		im.MouseCursor.Arrow      = glfw.ARROW_CURSOR,
		im.MouseCursor.TextInput  = glfw.IBEAM_CURSOR,
		im.MouseCursor.ResizeAll  = glfw.RESIZE_ALL_CURSOR,
		im.MouseCursor.ResizeNS   = glfw.VRESIZE_CURSOR,
		im.MouseCursor.ResizeEW   = glfw.HRESIZE_CURSOR,
		im.MouseCursor.ResizeNESW = glfw.RESIZE_NESW_CURSOR,
		im.MouseCursor.ResizeNWSE = glfw.RESIZE_NWSE_CURSOR,
		im.MouseCursor.Hand       = glfw.HAND_CURSOR,
		im.MouseCursor.Wait       = 0,
		im.MouseCursor.Progress   = 0,
		im.MouseCursor.NotAllowed = glfw.NOT_ALLOWED_CURSOR,
	}
	for shape, i in shapes {
		if shape != 0 {
			bd.mouse_cursors[i] = glfw.CreateStandardCursor(shape)
		}
	}
	glfw.SetErrorCallback(prev_error_callback)
	glfw_raw.GetError(nil) // Eat the errors.

	if install_callbacks {
		InstallCallbacks(window)
	}

	main_viewport := im.GetMainViewport()
	main_viewport.PlatformHandle = rawptr(window)
	when ODIN_OS == .Windows {
		main_viewport.PlatformHandleRaw = rawptr(glfw.GetWin32Window(window))
		install_wndproc(bd, window)
	} else when ODIN_OS == .Darwin {
		main_viewport.PlatformHandleRaw = rawptr(glfw.GetCocoaWindow(window))
	}
	return true
}

InitForOpenGL :: proc(window: glfw.WindowHandle, install_callbacks := true) -> bool {
	return init(window, install_callbacks, .OpenGL)
}

InitForVulkan :: proc(window: glfw.WindowHandle, install_callbacks := true) -> bool {
	return init(window, install_callbacks, .Vulkan)
}

// For WebGPU and other APIs.
InitForOther :: proc(window: glfw.WindowHandle, install_callbacks := true) -> bool {
	return init(window, install_callbacks, .Unknown)
}

Shutdown :: proc() {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_glfw: no platform backend to shut down, or already shut down")
	io := im.GetIO()

	// Clears the main viewport's platform handles, which Init set.
	im.DestroyPlatformWindows()
	if bd.installed_callbacks {
		RestoreCallbacks(bd.window)
	}
	when ODIN_OS == .Windows {
		uninstall_wndproc(bd)
	}
	for cursor in bd.mouse_cursors {
		if cursor != nil {
			glfw.DestroyCursor(cursor)
		}
	}

	io.BackendPlatformName = nil
	io.BackendPlatformUserData = nil
	io.BackendFlags -= {.HasMouseCursors, .HasSetMousePos, .HasGamepad, .PlatformHasViewports, .HasMouseHoveredViewport}
	im.PlatformIO_ClearPlatformHandlers(im.GetPlatformIO())
	for entry, i in window_map {
		if entry.data == bd {
			unordered_remove(&window_map, i)
			break
		}
	}
	if len(window_map) == 0 {
		delete(window_map)
		window_map = nil
	}
	free(bd, bd.allocator)
}

@(private)
update_mouse_data :: proc(bd: ^Data) {
	io := bd.io
	window := bd.window
	if glfw.GetWindowAttrib(window, glfw.FOCUSED) != 0 {
		// Set the OS mouse position if requested (rarely used, only with io.ConfigNavMoveSetMousePos).
		if io.WantSetMousePos {
			glfw.SetCursorPos(window, f64(io.MousePos.x), f64(io.MousePos.y))
		}
		// The mouse position when focused but not hovered (CursorPosCallback gives it otherwise).
		if bd.mouse_window == nil {
			x, y := glfw.GetCursorPos(window)
			bd.last_valid_mouse_pos = {f32(x), f32(y)}
			im.IO_AddMousePosEvent(io, f32(x), f32(y))
		}
	}
}

@(private)
update_mouse_cursor :: proc(bd: ^Data) {
	io := bd.io
	window := bd.window
	if .NoMouseCursorChange in io.ConfigFlags || glfw.GetInputMode(window, glfw.CURSOR) == glfw.CURSOR_DISABLED {
		// So that if the user changes the cursor, it is updated the next time we can.
		bd.last_mouse_cursor = nil
		return
	}
	imgui_cursor := im.GetMouseCursor()
	if imgui_cursor == .None || io.MouseDrawCursor {
		// Hide the OS mouse cursor if imgui is drawing it or wants no cursor.
		if bd.last_mouse_cursor != nil {
			glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_HIDDEN)
			bd.last_mouse_cursor = nil
		}
		return
	}
	cursor := bd.mouse_cursors[imgui_cursor] if bd.mouse_cursors[imgui_cursor] != nil else bd.mouse_cursors[im.MouseCursor.Arrow]
	if bd.last_mouse_cursor != cursor {
		glfw.SetCursor(window, cursor)
		bd.last_mouse_cursor = cursor
	}
	glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_NORMAL)
}

@(private)
update_gamepads :: proc(bd: ^Data) {
	io := bd.io
	// Feeding the gamepad should not depend on this, but see ocornut/imgui#8075.
	if .NavEnableGamepad not_in io.ConfigFlags {
		return
	}
	io.BackendFlags -= {.HasGamepad}
	gamepad: glfw.GamepadState
	if !glfw.GetGamepadState(glfw.JOYSTICK_1, &gamepad) {
		return
	}
	io.BackendFlags += {.HasGamepad}
	button :: proc(io: ^im.IO, gamepad: ^glfw.GamepadState, key: im.Key, b: c.int) {
		im.IO_AddKeyEvent(io, key, gamepad.buttons[b] != 0)
	}
	analog :: proc(io: ^im.IO, gamepad: ^glfw.GamepadState, key: im.Key, axis: c.int, v0, v1: f32) {
		v := (gamepad.axes[axis] - v0) / (v1 - v0)
		im.IO_AddKeyAnalogEvent(io, key, v > 0.10, clamp(v, 0, 1))
	}
	button(io, &gamepad, .GamepadStart, glfw.GAMEPAD_BUTTON_START)
	button(io, &gamepad, .GamepadBack, glfw.GAMEPAD_BUTTON_BACK)
	button(io, &gamepad, .GamepadFaceLeft, glfw.GAMEPAD_BUTTON_X) // Xbox X, PS Square
	button(io, &gamepad, .GamepadFaceRight, glfw.GAMEPAD_BUTTON_B) // Xbox B, PS Circle
	button(io, &gamepad, .GamepadFaceUp, glfw.GAMEPAD_BUTTON_Y) // Xbox Y, PS Triangle
	button(io, &gamepad, .GamepadFaceDown, glfw.GAMEPAD_BUTTON_A) // Xbox A, PS Cross
	button(io, &gamepad, .GamepadDpadLeft, glfw.GAMEPAD_BUTTON_DPAD_LEFT)
	button(io, &gamepad, .GamepadDpadRight, glfw.GAMEPAD_BUTTON_DPAD_RIGHT)
	button(io, &gamepad, .GamepadDpadUp, glfw.GAMEPAD_BUTTON_DPAD_UP)
	button(io, &gamepad, .GamepadDpadDown, glfw.GAMEPAD_BUTTON_DPAD_DOWN)
	button(io, &gamepad, .GamepadL1, glfw.GAMEPAD_BUTTON_LEFT_BUMPER)
	button(io, &gamepad, .GamepadR1, glfw.GAMEPAD_BUTTON_RIGHT_BUMPER)
	analog(io, &gamepad, .GamepadL2, glfw.GAMEPAD_AXIS_LEFT_TRIGGER, -0.75, 1.0)
	analog(io, &gamepad, .GamepadR2, glfw.GAMEPAD_AXIS_RIGHT_TRIGGER, -0.75, 1.0)
	button(io, &gamepad, .GamepadL3, glfw.GAMEPAD_BUTTON_LEFT_THUMB)
	button(io, &gamepad, .GamepadR3, glfw.GAMEPAD_BUTTON_RIGHT_THUMB)
	analog(io, &gamepad, .GamepadLStickLeft, glfw.GAMEPAD_AXIS_LEFT_X, -0.25, -1.0)
	analog(io, &gamepad, .GamepadLStickRight, glfw.GAMEPAD_AXIS_LEFT_X, 0.25, 1.0)
	analog(io, &gamepad, .GamepadLStickUp, glfw.GAMEPAD_AXIS_LEFT_Y, -0.25, -1.0)
	analog(io, &gamepad, .GamepadLStickDown, glfw.GAMEPAD_AXIS_LEFT_Y, 0.25, 1.0)
	analog(io, &gamepad, .GamepadRStickLeft, glfw.GAMEPAD_AXIS_RIGHT_X, -0.25, -1.0)
	analog(io, &gamepad, .GamepadRStickRight, glfw.GAMEPAD_AXIS_RIGHT_X, 0.25, 1.0)
	analog(io, &gamepad, .GamepadRStickUp, glfw.GAMEPAD_AXIS_RIGHT_Y, -0.25, -1.0)
	analog(io, &gamepad, .GamepadRStickDown, glfw.GAMEPAD_AXIS_RIGHT_Y, 0.25, 1.0)
}

// The DPI scale of a window or monitor, to scale fonts and sizes with (style.FontScaleDpi,
// Style_ScaleAllSizes). 1 on macOS and Wayland, which scale through the framebuffer instead. May be 0 for
// virtual monitors.
GetContentScaleForWindow :: proc(window: glfw.WindowHandle) -> f32 {
	when ODIN_OS == .Darwin {
		return 1
	} else {
		if bd := get_window_data(window); (bd != nil && bd.is_wayland) || is_wayland() {
			return 1
		}
		x_scale, _ := glfw.GetWindowContentScale(window)
		return x_scale
	}
}

GetContentScaleForMonitor :: proc(monitor: glfw.MonitorHandle) -> f32 {
	when ODIN_OS == .Darwin {
		return 1
	} else {
		if is_wayland() {
			return 1
		}
		x_scale, _ := glfw.GetMonitorContentScale(monitor)
		return x_scale
	}
}

@(private)
window_size_and_framebuffer_scale :: proc(bd: ^Data) -> (size, framebuffer_scale: im.Vec2) {
	w, h := glfw.GetWindowSize(bd.window)
	display_w, display_h := glfw.GetFramebufferSize(bd.window)
	framebuffer_scale = {f32(display_w) / f32(w) if w > 0 else 1, f32(display_h) / f32(h) if h > 0 else 1}
	// X11 scales through the content scale, not the framebuffer.
	when ODIN_OS == .Linux {
		if !bd.is_wayland {
			framebuffer_scale = {1, 1}
		}
	}
	return {f32(w), f32(h)}, framebuffer_scale
}

NewFrame :: proc() {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_glfw: not initialized, call InitForOther first")
	io := bd.io

	// The window size, every frame since it can change.
	io.DisplaySize, io.DisplayFramebufferScale = window_size_and_framebuffer_scale(bd)

	// glfw.GetTime() can go backwards, e.g. when disconnecting peripherals, or in VMs.
	current_time := glfw.GetTime()
	if current_time <= bd.time {
		current_time = bd.time + 0.00001
	}
	io.DeltaTime = f32(current_time - bd.time) if bd.time > 0 else 1.0 / 60
	bd.time = current_time

	bd.mouse_ignore_button_up = false
	update_mouse_data(bd)
	update_mouse_cursor(bd)
	update_gamepads(bd)
}

// GLFW has no portable sleep function.
Sleep :: proc(milliseconds: int) {
	time.sleep(time.Duration(milliseconds) * time.Millisecond)
}
