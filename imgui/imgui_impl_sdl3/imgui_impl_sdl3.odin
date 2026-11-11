// Dear ImGui platform backend for SDL 3, on the sdl3 collection (github.com/mpalomas/sdl3_odin). An Odin port of
// backends/imgui_impl_sdl3.cpp of Dear ImGui 1.93.0 (docking), to use with a renderer backend such as imgui_impl_wgpu.
//
// Implemented: clipboard, mouse (and touch screens as a mouse source), keyboard, gamepads (all SDL gamepads, or the
// first one, or the ones you pass), mouse cursor shapes, IME (text input area and SDL_StartTextInput), opening URLs.
// Not ported (yet): multi-viewports (ConfigFlags.ViewportsEnable is ignored; docking works inside the main window).
//
// It imports sdl3:sdl3, so build with -collection:sdl3=<a checkout of sdl3_odin>, the same SDL bindings as the program.
//
//	imgui_impl_sdl3.InitForOther(window)  // After im.CreateContext(), before the renderer's Init.
//	// For each SDL event, before im.NewFrame():
//	imgui_impl_sdl3.ProcessEvent(&event)
//	// Each frame, before im.NewFrame():
//	imgui_impl_sdl3.NewFrame()
//	// At exit, after the renderer's Shutdown():
//	imgui_impl_sdl3.Shutdown()
package imgui_impl_sdl3

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import sdl "sdl3:sdl3"
import im ".."

// Gamepad_Mode picks the gamepads Dear ImGui reads, see SetGamepadMode.
Gamepad_Mode :: enum c.int {
	Auto_First, // the first SDL gamepad, the default
	Auto_All,   // every SDL gamepad, merged
	Manual,     // the ones passed to SetGamepadMode, which the caller opens and closes
}

// Mouse_Capture_Mode says when the backend captures the mouse, to follow drags outside the window. On X11 a debugger
// that stops the program during a capture can leave the mouse grabbed, hence Enabled_After_Drag there.
Mouse_Capture_Mode :: enum c.int {
	Enabled,
	Enabled_After_Drag,
	Disabled,
}

// Backend data, in io.BackendPlatformUserData.
@(private)
Data :: struct {
	window:                    ^sdl.Window,
	window_id:                 sdl.WindowID,
	time:                      u64,
	clipboard_text_data:       [^]u8,
	platform_name:             [64]u8,
	is_wayland:                bool,

	// IME
	ime_window:                ^sdl.Window,
	ime_data:                  im.PlatformImeData,
	ime_dirty:                 bool,

	// MOUSE
	mouse_window_id:           sdl.WindowID,
	mouse_buttons_down:        c.int,
	mouse_cursors:             [im.MouseCursor_COUNT]^sdl.Cursor,
	mouse_last_cursor:         ^sdl.Cursor,
	mouse_pending_leave_frame: c.int,
	mouse_can_use_global_state: bool,
	mouse_capture_mode:        Mouse_Capture_Mode,

	// GAMEPADS
	gamepads:                  [dynamic]^sdl.Gamepad,
	gamepad_mode:              Gamepad_Mode,
	want_update_gamepads_list: bool,

	allocator:                 runtime.Allocator,
}

// Data for the current context.
@(private)
get_backend_data :: proc "contextless" () -> ^Data {
	return im.GetCurrentContext() != nil ? (^Data)(im.GetIO().BackendPlatformUserData) : nil
}

// The viewport of an SDL window: the main one for the backend's window, nil for other windows.
@(private)
viewport_for_window_id :: proc "contextless" (window_id: sdl.WindowID) -> ^im.Viewport {
	return im.FindViewportByPlatformHandle(rawptr(uintptr(window_id)))
}

//-----------//
// CLIPBOARD //
//-----------//

@(private)
get_clipboard_text :: proc "c" (ctx: ^im.Context) -> cstring {
	bd := get_backend_data()
	if bd.clipboard_text_data != nil {
		sdl.free(bd.clipboard_text_data)
	}
	bd.clipboard_text_data = sdl.GetClipboardText() if sdl.HasClipboardText() else nil
	return cstring(bd.clipboard_text_data)
}

@(private)
set_clipboard_text :: proc "c" (ctx: ^im.Context, text: cstring) {
	sdl.SetClipboardText(text)
}

//-----//
// IME //
//-----//

@(private)
platform_set_ime_data :: proc "c" (ctx: ^im.Context, viewport: ^im.Viewport, data: ^im.PlatformImeData) {
	bd := get_backend_data()
	bd.ime_data = data^
	bd.ime_dirty = true
	update_ime()
}

// We discard the viewport of the IME data and always start text input on SDL_GetKeyboardFocus(), as upstream does.
@(private)
update_ime :: proc "contextless" () {
	bd := get_backend_data()
	data := &bd.ime_data
	window := sdl.GetKeyboardFocus()

	// Stop the previous input.
	if (!(data.WantVisible || data.WantTextInput) || bd.ime_window != window) && bd.ime_window != nil {
		sdl.StopTextInput(bd.ime_window)
		bd.ime_window = nil
	}
	if (!bd.ime_dirty && bd.ime_window == window) || window == nil {
		return
	}

	// Start or update the current input.
	bd.ime_dirty = false
	if data.WantVisible {
		viewport_pos: im.Vec2
		if viewport := viewport_for_window_id(sdl.GetWindowID(window)); viewport != nil {
			viewport_pos = viewport.Pos
		}
		r := sdl.Rect{
			x = c.int(data.InputPos.x - viewport_pos.x), y = c.int(data.InputPos.y - viewport_pos.y), w = 1,
			h = c.int(data.InputLineHeight),
		}
		sdl.SetTextInputArea(window, &r, 0)
		bd.ime_window = window
	}
	if !sdl.TextInputActive(window) && (data.WantVisible || data.WantTextInput) {
		sdl.StartTextInput(window)
	}
}

//----------//
// KEYBOARD //
//----------//

// KeyEventToImGuiKey maps an SDL key to Dear ImGui's: the keypad by scancode (SDL 3 has no keypad keycodes), the rest by
// keycode, then the OEM keys by scancode, so they follow the key's position rather than the layout's character.
KeyEventToImGuiKey :: proc "contextless" (keycode: sdl.Keycode, scancode: sdl.Scancode) -> im.Key {
	#partial switch scancode {
	case .KP_0: return .Keypad0
	case .KP_1: return .Keypad1
	case .KP_2: return .Keypad2
	case .KP_3: return .Keypad3
	case .KP_4: return .Keypad4
	case .KP_5: return .Keypad5
	case .KP_6: return .Keypad6
	case .KP_7: return .Keypad7
	case .KP_8: return .Keypad8
	case .KP_9: return .Keypad9
	case .KP_PERIOD: return .KeypadDecimal
	case .KP_DIVIDE: return .KeypadDivide
	case .KP_MULTIPLY: return .KeypadMultiply
	case .KP_MINUS: return .KeypadSubtract
	case .KP_PLUS: return .KeypadAdd
	case .KP_ENTER: return .KeypadEnter
	case .KP_EQUALS: return .KeypadEqual
	}
	switch keycode {
	case sdl.K_TAB: return .Tab
	case sdl.K_LEFT: return .LeftArrow
	case sdl.K_RIGHT: return .RightArrow
	case sdl.K_UP: return .UpArrow
	case sdl.K_DOWN: return .DownArrow
	case sdl.K_PAGEUP: return .PageUp
	case sdl.K_PAGEDOWN: return .PageDown
	case sdl.K_HOME: return .Home
	case sdl.K_END: return .End
	case sdl.K_INSERT: return .Insert
	case sdl.K_DELETE: return .Delete
	case sdl.K_BACKSPACE: return .Backspace
	case sdl.K_SPACE: return .Space
	case sdl.K_RETURN: return .Enter
	case sdl.K_ESCAPE: return .Escape
	case sdl.K_COMMA: return .Comma
	case sdl.K_PERIOD: return .Period
	case sdl.K_SEMICOLON: return .Semicolon
	case sdl.K_CAPSLOCK: return .CapsLock
	case sdl.K_SCROLLLOCK: return .ScrollLock
	case sdl.K_NUMLOCKCLEAR: return .NumLock
	case sdl.K_PRINTSCREEN: return .PrintScreen
	case sdl.K_PAUSE: return .Pause
	case sdl.K_LCTRL: return .LeftCtrl
	case sdl.K_LSHIFT: return .LeftShift
	case sdl.K_LALT: return .LeftAlt
	case sdl.K_LGUI: return .LeftSuper
	case sdl.K_RCTRL: return .RightCtrl
	case sdl.K_RSHIFT: return .RightShift
	case sdl.K_RALT: return .RightAlt
	case sdl.K_RGUI: return .RightSuper
	case sdl.K_APPLICATION: return .Menu
	case sdl.K_0 ..= sdl.K_9:
		return im.Key(c.int(im.Key._0) + c.int(keycode - sdl.K_0))
	case sdl.K_A ..= sdl.K_Z:
		return im.Key(c.int(im.Key.A) + c.int(keycode - sdl.K_A))
	case sdl.K_F1 ..= sdl.K_F12:
		return im.Key(c.int(im.Key.F1) + c.int(keycode - sdl.K_F1))
	case sdl.K_F13 ..= sdl.K_F24:
		return im.Key(c.int(im.Key.F13) + c.int(keycode - sdl.K_F13))
	case sdl.K_AC_BACK: return .AppBack
	case sdl.K_AC_FORWARD: return .AppForward
	}
	#partial switch scancode {
	case .GRAVE: return .GraveAccent
	case .MINUS: return .Minus
	case .EQUALS: return .Equal
	case .LEFTBRACKET: return .LeftBracket
	case .RIGHTBRACKET: return .RightBracket
	case .NONUSBACKSLASH: return .Oem102
	case .BACKSLASH: return .Backslash
	case .SEMICOLON: return .Semicolon
	case .APOSTROPHE: return .Apostrophe
	case .COMMA: return .Comma
	case .PERIOD: return .Period
	case .SLASH: return .Slash
	}
	return .None
}

@(private)
update_key_modifiers :: proc "contextless" (io: ^im.IO, mods: sdl.Keymod) {
	im.IO_AddKeyEvent(io, .Mod_Ctrl, mods & sdl.KMOD_CTRL != {})
	im.IO_AddKeyEvent(io, .Mod_Shift, mods & sdl.KMOD_SHIFT != {})
	im.IO_AddKeyEvent(io, .Mod_Alt, mods & sdl.KMOD_ALT != {})
	im.IO_AddKeyEvent(io, .Mod_Super, mods & sdl.KMOD_GUI != {})
}

//--------//
// EVENTS //
//--------//

// ProcessEvent gives an SDL event to Dear ImGui, and returns whether it was one for Dear ImGui (of the backend's window).
// Read io.WantCaptureMouse and io.WantCaptureKeyboard to know whether to hide the input from the rest of the program.
ProcessEvent :: proc(event: ^sdl.Event) -> bool {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_sdl3: not initialized, call InitForOther first")
	io := im.GetIO()
	source :: proc "contextless" (which: sdl.MouseID) -> im.MouseSource {
		return .TouchScreen if which == sdl.MouseID(sdl.TOUCH_MOUSEID) else .Mouse
	}

	#partial switch event.type {
	case .MOUSE_MOTION:
		if viewport_for_window_id(event.motion.windowID) == nil {
			return false
		}
		im.IO_AddMouseSourceEvent(io, source(event.motion.which))
		im.IO_AddMousePosEvent(io, event.motion.x, event.motion.y)
		return true
	case .MOUSE_WHEEL:
		if viewport_for_window_id(event.wheel.windowID) == nil {
			return false
		}
		im.IO_AddMouseSourceEvent(io, source(event.wheel.which))
		im.IO_AddMouseWheelEvent(io, -event.wheel.x, event.wheel.y)
		return true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		if viewport_for_window_id(event.button.windowID) == nil {
			return false
		}
		mouse_button: c.int
		switch c.int(event.button.button) {
		case sdl.BUTTON_LEFT: mouse_button = 0
		case sdl.BUTTON_RIGHT: mouse_button = 1
		case sdl.BUTTON_MIDDLE: mouse_button = 2
		case sdl.BUTTON_X1: mouse_button = 3
		case sdl.BUTTON_X2: mouse_button = 4
		case: return false
		}
		down := event.type == .MOUSE_BUTTON_DOWN
		im.IO_AddMouseSourceEvent(io, source(event.button.which))
		im.IO_AddMouseButtonEvent(io, mouse_button, down)
		if down {
			bd.mouse_buttons_down |= 1 << u32(mouse_button)
		} else {
			bd.mouse_buttons_down &~= 1 << u32(mouse_button)
		}
		return true
	case .TEXT_INPUT:
		if viewport_for_window_id(event.text.windowID) == nil {
			return false
		}
		im.IO_AddInputCharactersUTF8(io, event.text.text)
		return true
	case .KEY_DOWN, .KEY_UP:
		if viewport_for_window_id(event.key.windowID) == nil {
			return false
		}
		update_key_modifiers(io, event.key.mod)
		key := KeyEventToImGuiKey(event.key.key, event.key.scancode)
		im.IO_AddKeyEvent(io, key, event.type == .KEY_DOWN)
		// For the legacy <1.87 indexing with SDLK_* values.
		im.IO_SetKeyEventNativeData(io, key, c.int(event.key.key), c.int(event.key.scancode), c.int(event.key.scancode))
		return true
	case .WINDOW_MOUSE_ENTER:
		if viewport_for_window_id(event.window.windowID) == nil {
			return false
		}
		bd.mouse_window_id = event.window.windowID
		bd.mouse_pending_leave_frame = 0
		return true
	case .WINDOW_MOUSE_LEAVE:
		// Handled a frame late: SDL can send the enter of another window after the leave (ocornut/imgui#5012).
		if viewport_for_window_id(event.window.windowID) == nil {
			return false
		}
		bd.mouse_pending_leave_frame = im.GetFrameCount() + 1
		return true
	case .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST:
		if viewport_for_window_id(event.window.windowID) == nil {
			return false
		}
		im.IO_AddFocusEvent(io, event.type == .WINDOW_FOCUS_GAINED)
		return true
	case .WINDOW_CLOSE_REQUESTED, .WINDOW_MOVED, .WINDOW_RESIZED:
		viewport := viewport_for_window_id(event.window.windowID)
		if viewport == nil {
			return false
		}
		#partial switch event.type {
		case .WINDOW_CLOSE_REQUESTED: viewport.PlatformRequestClose = true
		case .WINDOW_MOVED: viewport.PlatformRequestMove = true
		case .WINDOW_RESIZED: viewport.PlatformRequestResize = true
		}
		return true
	case .GAMEPAD_ADDED, .GAMEPAD_REMOVED:
		bd.want_update_gamepads_list = true
		return true
	}
	return false
}

//----------------//
// INIT, SHUTDOWN //
//----------------//

@(private)
init :: proc(window: ^sdl.Window) -> bool {
	io := im.GetIO()
	if !im.CHECKVERSION() {
		return false
	}
	assert(io.BackendPlatformUserData == nil, "imgui_impl_sdl3: a platform backend is already initialized")
	video_driver := string(sdl.GetCurrentVideoDriver())

	bd := new(Data)
	bd.allocator = context.allocator
	bd.gamepads.allocator = context.allocator
	linked := sdl.GetVersion()
	fmt.bprintf(bd.platform_name[:len(bd.platform_name) - 1], "imgui_impl_sdl3 (odin, %d.%d.%d) (%s)",
		sdl.VERSIONNUM_MAJOR(linked), sdl.VERSIONNUM_MINOR(linked), sdl.VERSIONNUM_MICRO(linked), video_driver)
	io.BackendPlatformUserData = bd
	io.BackendPlatformName = cstring(&bd.platform_name[0])
	io.BackendFlags += {.HasMouseCursors, .HasSetMousePos}

	bd.window = window
	bd.window_id = sdl.GetWindowID(window)
	bd.is_wayland = video_driver == "wayland"

	// SDL_GetGlobalMouseState() and SDL_CaptureMouse() work on these drivers only (not Wayland).
	bd.mouse_capture_mode = .Disabled
	when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .Windows {
		for item in ([?]string{"windows", "cocoa", "x11"}) {
			if strings.has_prefix(video_driver, item) {
				bd.mouse_can_use_global_state = true
				bd.mouse_capture_mode = .Enabled_After_Drag if item == "x11" else .Enabled
			}
		}
	}

	platform_io := im.GetPlatformIO()
	platform_io.Platform_SetClipboardTextFn = set_clipboard_text
	platform_io.Platform_GetClipboardTextFn = get_clipboard_text
	platform_io.Platform_SetImeDataFn = platform_set_ime_data
	platform_io.Platform_OpenInShellFn = proc "c" (ctx: ^im.Context, url: cstring) -> bool {
		return sdl.OpenURL(url)
	}

	bd.gamepad_mode = .Auto_First
	bd.want_update_gamepads_list = true

	cursors := [im.MouseCursor_COUNT]sdl.SystemCursor{
		im.MouseCursor.Arrow      = .DEFAULT,
		im.MouseCursor.TextInput  = .TEXT,
		im.MouseCursor.ResizeAll  = .MOVE,
		im.MouseCursor.ResizeNS   = .NS_RESIZE,
		im.MouseCursor.ResizeEW   = .EW_RESIZE,
		im.MouseCursor.ResizeNESW = .NESW_RESIZE,
		im.MouseCursor.ResizeNWSE = .NWSE_RESIZE,
		im.MouseCursor.Hand       = .POINTER,
		im.MouseCursor.Wait       = .WAIT,
		im.MouseCursor.Progress   = .PROGRESS,
		im.MouseCursor.NotAllowed = .NOT_ALLOWED,
	}
	for cursor, i in cursors {
		bd.mouse_cursors[i] = sdl.CreateSystemCursor(cursor)
	}

	// The mouse functions find the main viewport by its PlatformHandle: the window's ID.
	main_viewport := im.GetMainViewport()
	main_viewport.PlatformHandle = rawptr(uintptr(bd.window_id))
	when ODIN_OS == .Windows {
		main_viewport.PlatformHandleRaw =
			sdl.GetPointerProperty(sdl.GetWindowProperties(window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
	} else when ODIN_OS == .Darwin {
		main_viewport.PlatformHandleRaw =
			sdl.GetPointerProperty(sdl.GetWindowProperties(window), sdl.PROP_WINDOW_COCOA_WINDOW_POINTER, nil)
	}

	// A click that focuses the window is a click too: otherwise widgets would show as hovered and not activate.
	// (SDL's hints are process-wide.)
	sdl.SetHint(sdl.HINT_MOUSE_FOCUS_CLICKTHROUGH, "1")
	// No automatic capture, which would prevent drag and drop across windows (ocornut/imgui#5710).
	sdl.SetHint(sdl.HINT_MOUSE_AUTO_CAPTURE, "0")
	// libsdl-org/SDL#6659
	sdl.SetHint("SDL_BORDERLESS_WINDOWED_STYLE", "0")
	return true
}

InitForOpenGL :: proc(window: ^sdl.Window, sdl_gl_context: sdl.GLContext) -> bool {
	return init(window)
}

InitForVulkan :: proc(window: ^sdl.Window) -> bool {
	return init(window)
}

InitForD3D :: proc(window: ^sdl.Window) -> bool {
	return init(window)
}

InitForMetal :: proc(window: ^sdl.Window) -> bool {
	return init(window)
}

// For WebGPU and other APIs.
InitForOther :: proc(window: ^sdl.Window) -> bool {
	return init(window)
}

Shutdown :: proc() {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_sdl3: no platform backend to shut down, or already shut down")
	io := im.GetIO()

	// Clears the main viewport's platform handles, which init set.
	im.DestroyPlatformWindows()
	if bd.clipboard_text_data != nil {
		sdl.free(bd.clipboard_text_data)
	}
	for cursor in bd.mouse_cursors {
		sdl.DestroyCursor(cursor)
	}
	close_gamepads(bd)
	delete(bd.gamepads)

	io.BackendPlatformName = nil
	io.BackendPlatformUserData = nil
	io.BackendFlags -= {.HasMouseCursors, .HasSetMousePos, .HasGamepad, .PlatformHasViewports, .HasMouseHoveredViewport}
	im.PlatformIO_ClearPlatformHandlers(im.GetPlatformIO())
	free(bd, bd.allocator)
}

// SetMouseCaptureMode overrides when the mouse is captured (X11 users with a debugger may want Disabled).
SetMouseCaptureMode :: proc(mode: Mouse_Capture_Mode) {
	bd := get_backend_data()
	if mode == .Disabled && bd.mouse_capture_mode != .Disabled {
		sdl.CaptureMouse(false)
	}
	bd.mouse_capture_mode = mode
}

//-------//
// MOUSE //
//-------//

@(private)
update_mouse_data :: proc(bd: ^Data) {
	io := im.GetIO()

	// We give the mouse position when it hovers the window or is captured (MOUSE_MOTION), or when the window is focused
	// (below). Capture tells the OS that our drags may leave the window.
	if bd.mouse_can_use_global_state {
		switch bd.mouse_capture_mode {
		case .Enabled:
			sdl.CaptureMouse(bd.mouse_buttons_down != 0)
		case .Enabled_After_Drag:
			want_capture := false
			for button in 0 ..< im.MouseButton_COUNT {
				want_capture ||= im.IsMouseDragging(im.MouseButton(button), 1)
			}
			sdl.CaptureMouse(want_capture)
		case .Disabled:
		}
	}

	focused_window := sdl.GetKeyboardFocus()
	is_app_focused := focused_window != nil &&
		(focused_window == bd.window || viewport_for_window_id(sdl.GetWindowID(focused_window)) != nil)
	if !is_app_focused {
		return
	}
	// Set the OS mouse position if requested (rarely used, only with io.ConfigNavMoveSetMousePos).
	if io.WantSetMousePos {
		sdl.WarpMouseInWindow(bd.window, io.MousePos.x, io.MousePos.y)
	}
	// The unclamped mouse position when focused but not hovered (MOUSE_MOTION gives it when hovered or captured).
	hovered_window := sdl.GetMouseFocus()
	relative := sdl.GetWindowRelativeMouseMode(bd.window)
	if hovered_window == nil && bd.mouse_can_use_global_state && bd.mouse_buttons_down == 0 && !relative {
		mouse_x, mouse_y: f32
		window_x, window_y: c.int
		sdl.GetGlobalMouseState(&mouse_x, &mouse_y)
		sdl.GetWindowPosition(focused_window, &window_x, &window_y)
		im.IO_AddMousePosEvent(io, mouse_x - f32(window_x), mouse_y - f32(window_y))
	}
}

@(private)
update_mouse_cursor :: proc(bd: ^Data) {
	io := im.GetIO()
	if .NoMouseCursorChange in io.ConfigFlags {
		return
	}
	imgui_cursor := im.GetMouseCursor()
	if io.MouseDrawCursor || imgui_cursor == .None {
		// Hide the OS mouse cursor if imgui is drawing it or wants no cursor.
		sdl.HideCursor()
		return
	}
	expected := bd.mouse_cursors[imgui_cursor] if bd.mouse_cursors[imgui_cursor] != nil else bd.mouse_cursors[im.MouseCursor.Arrow]
	if bd.mouse_last_cursor != expected {
		sdl.SetCursor(expected) // SDL_SetCursor has no early out (ocornut/imgui#6113)
		bd.mouse_last_cursor = expected
	}
	sdl.ShowCursor()
}

//----------//
// GAMEPADS //
//----------//

@(private)
close_gamepads :: proc(bd: ^Data) {
	if bd.gamepad_mode != .Manual {
		for gamepad in bd.gamepads {
			sdl.CloseGamepad(gamepad)
		}
	}
	clear(&bd.gamepads)
}

// SetGamepadMode picks the gamepads Dear ImGui reads. With .Manual, it reads the ones passed, which the caller opens and
// closes; the other modes take none.
SetGamepadMode :: proc(mode: Gamepad_Mode, manual_gamepads: []^sdl.Gamepad = nil) {
	bd := get_backend_data()
	close_gamepads(bd)
	if mode == .Manual {
		append(&bd.gamepads, ..manual_gamepads)
	} else {
		assert(len(manual_gamepads) == 0, "imgui_impl_sdl3: gamepads are only passed with .Manual")
		bd.want_update_gamepads_list = true
	}
	bd.gamepad_mode = mode
}

@(private)
update_gamepads :: proc(bd: ^Data) {
	io := im.GetIO()

	// The list of gamepads to read.
	if bd.want_update_gamepads_list && bd.gamepad_mode != .Manual {
		close_gamepads(bd)
		count: c.int
		ids := sdl.GetGamepads(&count)
		for n in 0 ..< int(count) {
			if gamepad := sdl.OpenGamepad(ids[n]); gamepad != nil {
				append(&bd.gamepads, gamepad)
				if bd.gamepad_mode == .Auto_First {
					break
				}
			}
		}
		bd.want_update_gamepads_list = false
		sdl.free(ids)
	}

	io.BackendFlags -= {.HasGamepad}
	if len(bd.gamepads) == 0 {
		return
	}
	io.BackendFlags += {.HasGamepad}

	button :: proc(bd: ^Data, io: ^im.IO, key: im.Key, button: sdl.GamepadButton) {
		merged := false
		for gamepad in bd.gamepads {
			merged ||= sdl.GetGamepadButton(gamepad, button)
		}
		im.IO_AddKeyEvent(io, key, merged)
	}
	analog :: proc(bd: ^Data, io: ^im.IO, key: im.Key, axis: sdl.GamepadAxis, v0, v1: f32) {
		merged: f32
		for gamepad in bd.gamepads {
			merged = max(merged, clamp((f32(sdl.GetGamepadAxis(gamepad, axis)) - v0) / (v1 - v0), 0, 1))
		}
		im.IO_AddKeyAnalogEvent(io, key, merged > 0.1, merged)
	}
	THUMB_DEAD_ZONE :: 8000 // what SDL_gamepad.h suggests
	button(bd, io, .GamepadStart, .START)
	button(bd, io, .GamepadBack, .BACK)
	button(bd, io, .GamepadFaceLeft, .WEST) // Xbox X, PS Square
	button(bd, io, .GamepadFaceRight, .EAST) // Xbox B, PS Circle
	button(bd, io, .GamepadFaceUp, .NORTH) // Xbox Y, PS Triangle
	button(bd, io, .GamepadFaceDown, .SOUTH) // Xbox A, PS Cross
	button(bd, io, .GamepadDpadLeft, .DPAD_LEFT)
	button(bd, io, .GamepadDpadRight, .DPAD_RIGHT)
	button(bd, io, .GamepadDpadUp, .DPAD_UP)
	button(bd, io, .GamepadDpadDown, .DPAD_DOWN)
	button(bd, io, .GamepadL1, .LEFT_SHOULDER)
	button(bd, io, .GamepadR1, .RIGHT_SHOULDER)
	analog(bd, io, .GamepadL2, .LEFT_TRIGGER, 0, 32767)
	analog(bd, io, .GamepadR2, .RIGHT_TRIGGER, 0, 32767)
	button(bd, io, .GamepadL3, .LEFT_STICK)
	button(bd, io, .GamepadR3, .RIGHT_STICK)
	analog(bd, io, .GamepadLStickLeft, .LEFTX, -THUMB_DEAD_ZONE, -32768)
	analog(bd, io, .GamepadLStickRight, .LEFTX, THUMB_DEAD_ZONE, 32767)
	analog(bd, io, .GamepadLStickUp, .LEFTY, -THUMB_DEAD_ZONE, -32768)
	analog(bd, io, .GamepadLStickDown, .LEFTY, THUMB_DEAD_ZONE, 32767)
	analog(bd, io, .GamepadRStickLeft, .RIGHTX, -THUMB_DEAD_ZONE, -32768)
	analog(bd, io, .GamepadRStickRight, .RIGHTX, THUMB_DEAD_ZONE, 32767)
	analog(bd, io, .GamepadRStickUp, .RIGHTY, -THUMB_DEAD_ZONE, -32768)
	analog(bd, io, .GamepadRStickDown, .RIGHTY, THUMB_DEAD_ZONE, 32767)
}

//-------//
// FRAME //
//-------//

@(private)
window_size_and_framebuffer_scale :: proc(window: ^sdl.Window) -> (size, framebuffer_scale: im.Vec2) {
	w, h: c.int
	sdl.GetWindowSize(window, &w, &h)
	if .MINIMIZED in sdl.GetWindowFlags(window) {
		w, h = 0, 0
	}
	when ODIN_OS == .Darwin {
		scale := sdl.GetWindowDisplayScale(window) // more reliable during resolution changes (ocornut/imgui#8703)
		framebuffer_scale = {scale, scale}
	} else {
		display_w, display_h: c.int
		sdl.GetWindowSizeInPixels(window, &display_w, &display_h)
		framebuffer_scale = {f32(display_w) / f32(w) if w > 0 else 1, f32(display_h) / f32(h) if h > 0 else 1}
	}
	return {f32(w), f32(h)}, framebuffer_scale
}

NewFrame :: proc() {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_sdl3: not initialized, call InitForOther first")
	io := im.GetIO()

	// The window size, every frame since it can change.
	io.DisplaySize, io.DisplayFramebufferScale = window_size_and_framebuffer_scale(bd.window)

	// The performance counter can stand still or go back in VMs (ocornut/imgui#6189).
	frequency := sdl.GetPerformanceFrequency()
	current_time := sdl.GetPerformanceCounter()
	if current_time <= bd.time {
		current_time = bd.time + 1
	}
	io.DeltaTime = f32(f64(current_time - bd.time) / f64(frequency)) if bd.time > 0 else 1.0 / 60
	bd.time = current_time

	if bd.mouse_pending_leave_frame != 0 && bd.mouse_pending_leave_frame >= im.GetFrameCount() && bd.mouse_buttons_down == 0 {
		bd.mouse_window_id = 0
		bd.mouse_pending_leave_frame = 0
		im.IO_AddMousePosEvent(io, -max(f32), -max(f32))
	}

	update_mouse_data(bd)
	update_mouse_cursor(bd)
	update_ime()
	update_gamepads(bd)
}
