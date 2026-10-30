#+build windows
package imgui_impl_glfw

import win32 "core:sys/windows"
import "vendor:glfw"
import im ".."

// The window property holding the backend data, for the window procedure.
@(private = "file")
PROP_BACKEND_DATA :: "IMGUI_BACKEND_DATA"

// GLFW does not tell mouse, touch screen and pen apart: a window procedure hook reads it from the Win32
// messages, as imgui_impl_win32 does. Dear ImGui handles touch screen input differently (it trickles it).
@(private)
install_wndproc :: proc(bd: ^Data, window: glfw.WindowHandle) {
	hwnd := glfw.GetWin32Window(window)
	win32.SetPropW(hwnd, win32.L(PROP_BACKEND_DATA), win32.HANDLE(bd))
	bd.prev_wndproc = rawptr(uintptr(win32.GetWindowLongPtrW(hwnd, win32.GWLP_WNDPROC)))
	assert(bd.prev_wndproc != nil)
	win32.SetWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, win32.LONG_PTR(uintptr(rawptr(wndproc))))
}

@(private)
uninstall_wndproc :: proc(bd: ^Data) {
	hwnd := glfw.GetWin32Window(bd.window)
	win32.RemovePropW(hwnd, win32.L(PROP_BACKEND_DATA))
	win32.SetWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, win32.LONG_PTR(uintptr(bd.prev_wndproc)))
	bd.prev_wndproc = nil
}

@(private = "file")
mouse_source_from_message_extra_info :: proc "contextless" () -> im.MouseSource {
	extra_info := u32(uintptr(win32.GetMessageExtraInfo()))
	switch extra_info & 0xFFFFFF80 {
	case 0xFF515700: return .Pen
	case 0xFF515780: return .TouchScreen
	}
	return .Mouse
}

@(private = "file")
wndproc :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	bd := (^Data)(win32.GetPropW(hwnd, win32.L(PROP_BACKEND_DATA)))
	switch msg {
	case win32.WM_MOUSEMOVE, win32.WM_NCMOUSEMOVE,
	     win32.WM_LBUTTONDOWN, win32.WM_LBUTTONDBLCLK, win32.WM_LBUTTONUP,
	     win32.WM_RBUTTONDOWN, win32.WM_RBUTTONDBLCLK, win32.WM_RBUTTONUP,
	     win32.WM_MBUTTONDOWN, win32.WM_MBUTTONDBLCLK, win32.WM_MBUTTONUP,
	     win32.WM_XBUTTONDOWN, win32.WM_XBUTTONDBLCLK, win32.WM_XBUTTONUP:
		im.IO_AddMouseSourceEvent(bd.io, mouse_source_from_message_extra_info())
	}
	return win32.CallWindowProcW(win32.WNDPROC(bd.prev_wndproc), hwnd, msg, wparam, lparam)
}
