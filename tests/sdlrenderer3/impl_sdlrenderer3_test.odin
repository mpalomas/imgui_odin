// Runs imgui_impl_sdlrenderer3 with imgui_impl_sdl3 on SDL's dummy video driver and software renderer, and reads
// back what they drew. Needs the Dear ImGui library and an SDL with its 2D renderer, e.g. Odin's vendor:sdl3 (the SDL3
// development files on Linux, which vendor:sdl3 links):
//
//   odin test tests/sdlrenderer3 -collection:sdl3="$(odin root)/vendor"
package imgui_sdlrenderer3_tests

import "core:strings"
import "core:sync"
import "core:testing"
import sdl "sdl3:sdl3"
import im "../../imgui"
import "../../imgui/imgui_impl_sdl3"
import "../../imgui/imgui_impl_sdlrenderer3"

// SDL and the ImGui context are process-wide, and tests run on several threads.
@(private = "file")
test_mutex: sync.Mutex

@(private = "file")
WIDTH :: 640
@(private = "file")
HEIGHT :: 480

// Fixture is a dummy-driver window with a software renderer, an ImGui context and both backends on them.
@(private = "file")
Fixture :: struct {
	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	io:       ^im.IO,
}

@(private = "file")
fixture_start :: proc(t: ^testing.T) -> (fixture: Fixture, ok: bool) {
	sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "dummy") // not offscreen: it loads EGL, which macOS does not have
	if !testing.expectf(t, sdl.Init({.VIDEO}), "SDL_Init: %s", sdl.GetError()) {
		return
	}
	fixture.window = sdl.CreateWindow("imgui_impl_sdlrenderer3 test", WIDTH, HEIGHT, {})
	if !testing.expectf(t, fixture.window != nil, "SDL_CreateWindow: %s", sdl.GetError()) {
		sdl.Quit()
		return
	}
	fixture.renderer = sdl.CreateRenderer(fixture.window, "software")
	if !testing.expectf(t, fixture.renderer != nil, "SDL_CreateRenderer: %s", sdl.GetError()) {
		sdl.DestroyWindow(fixture.window)
		sdl.Quit()
		return
	}
	im.CreateContext()
	fixture.io = im.GetIO()
	fixture.io.IniFilename = nil
	if !testing.expect(t, imgui_impl_sdl3.InitForSDLRenderer(fixture.window, fixture.renderer)) ||
	   !testing.expect(t, imgui_impl_sdlrenderer3.Init(fixture.renderer)) {
		fixture_stop(fixture)
		return
	}
	return fixture, true
}

@(private = "file")
fixture_stop :: proc(fixture: Fixture) {
	io := im.GetIO()
	if io.BackendRendererUserData != nil {
		imgui_impl_sdlrenderer3.Shutdown()
	}
	if io.BackendPlatformUserData != nil {
		imgui_impl_sdl3.Shutdown()
	}
	im.DestroyContext()
	sdl.DestroyRenderer(fixture.renderer)
	sdl.DestroyWindow(fixture.window)
	sdl.Quit()
}

// frame runs a frame of the UI that `ui` builds, and renders it over a black window.
@(private = "file")
frame :: proc(fixture: Fixture, ui: proc()) {
	event: sdl.Event
	for sdl.PollEvent(&event) {
		imgui_impl_sdl3.ProcessEvent(&event)
	}
	imgui_impl_sdlrenderer3.NewFrame()
	imgui_impl_sdl3.NewFrame()
	im.NewFrame()
	ui()
	im.Render()
	_ = sdl.SetRenderDrawColor(fixture.renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(fixture.renderer)
	imgui_impl_sdlrenderer3.RenderDrawData(im.GetDrawData(), fixture.renderer)
}

// Pixel_Count counts the pixels of a rectangle of the rendered picture that are not black, and those that are bright
// (text, in Dear ImGui's default style).
@(private = "file")
Pixel_Count :: struct {
	lit, bright: int,
}

@(private = "file")
count_pixels :: proc(t: ^testing.T, renderer: ^sdl.Renderer, rect: sdl.Rect) -> (count: Pixel_Count) {
	surface := sdl.RenderReadPixels(renderer, nil)
	if !testing.expectf(t, surface != nil, "SDL_RenderReadPixels: %s", sdl.GetError()) {
		return
	}
	defer sdl.DestroySurface(surface)
	for y in rect.y ..< rect.y + rect.h {
		for x in rect.x ..< rect.x + rect.w {
			r, g, b, a: u8
			_ = sdl.ReadSurfacePixel(surface, x, y, &r, &g, &b, &a)
			if r != 0 || g != 0 || b != 0 {
				count.lit += 1
			}
			if r > 200 && g > 200 && b > 200 {
				count.bright += 1
			}
		}
	}
	return
}

@(private = "file")
read_pixel :: proc(renderer: ^sdl.Renderer, x, y: i32) -> (rgba: [4]u8) {
	surface := sdl.RenderReadPixels(renderer, nil)
	if surface == nil {
		return
	}
	defer sdl.DestroySurface(surface)
	_ = sdl.ReadSurfacePixel(surface, x, y, &rgba.r, &rgba.g, &rgba.b, &rgba.a)
	return
}

@(test)
test_window_and_text :: proc(t: ^testing.T) {
	sync.guard(&test_mutex)
	fixture, ok := fixture_start(t)
	if !ok {
		return
	}
	defer fixture_stop(fixture)
	io := fixture.io
	testing.expect_value(t, string(io.BackendRendererName), "imgui_impl_sdlrenderer3 (odin)")
	testing.expect(t, io.BackendFlags >= {.RendererHasVtxOffset, .RendererHasTextures})
	testing.expect(t, strings.contains(string(io.BackendPlatformName), "(dummy)"))

	hello :: proc() {
		im.SetNextWindowPos({20, 20})
		im.SetNextWindowSize({300, 200})
		if im.Begin("Hello") {
			im.Text("Hello, world! %d", 123)
			im.Button("A button")
		}
		im.End()
	}
	frame(fixture, hello)
	frame(fixture, hello)

	// The font atlas was created and uploaded: a texture of ours, up to date.
	textures := im.vector_slice(im.GetPlatformIO().Textures)
	testing.expect(t, len(textures) >= 1)
	for tex in textures {
		testing.expect_value(t, tex.Status, im.TextureStatus.OK)
		testing.expect(t, tex.TexID != im.TextureID_Invalid)
	}

	// The window is drawn where it was put, with its text, and nothing outside it.
	inside := count_pixels(t, fixture.renderer, {20, 20, 300, 200})
	testing.expectf(t, inside.lit > 300 * 200 * 9 / 10, "the window covers %d pixels", inside.lit)
	testing.expectf(t, inside.bright > 50, "the text covers %d pixels", inside.bright)
	outside := count_pixels(t, fixture.renderer, {400, 300, 200, 150})
	testing.expect_value(t, outside.lit, 0)

	// Shutting down destroys the font atlas' texture. (Dear ImGui then marks it WantCreate, for a next backend, since
	// the atlas still has its pixels.)
	imgui_impl_sdlrenderer3.Shutdown()
	for tex in textures {
		testing.expect_value(t, tex.TexID, im.TextureID_Invalid)
		testing.expect_value(t, tex.Status, im.TextureStatus.WantCreate)
	}
	testing.expect(t, io.BackendRendererUserData == nil)
	testing.expect(t, .RendererHasTextures not_in io.BackendFlags)
}

// A user texture: an ^sdl.Texture as TextureID. Its scale mode, changed to the backend's default sampler while
// rendering, is restored afterwards, as are the renderer's viewport and clipping rectangle.
@(test)
test_user_texture :: proc(t: ^testing.T) {
	sync.guard(&test_mutex)
	fixture, ok := fixture_start(t)
	if !ok {
		return
	}
	defer fixture_stop(fixture)

	red := sdl.CreateTexture(fixture.renderer, .RGBA32, .STATIC, 4, 4)
	if !testing.expect(t, red != nil) {
		return
	}
	defer sdl.DestroyTexture(red)
	pixels: [4 * 4][4]u8
	for &p in pixels {
		p = {255, 0, 0, 255}
	}
	_ = sdl.UpdateTexture(red, nil, &pixels, 4 * 4)
	_ = sdl.SetTextureScaleMode(red, .NEAREST)

	@(static) red_id: im.TextureID
	red_id = im.TextureID(uintptr(red))
	image :: proc() {
		im.SetNextWindowPos({100, 100})
		if im.Begin("Image", nil, im.WindowFlags_NoDecoration) {
			im.Image({_TexID = red_id}, {64, 64})
		}
		im.End()
	}

	clip := sdl.Rect{0, 0, 600, 400}
	_ = sdl.SetRenderClipRect(fixture.renderer, &clip)
	frame(fixture, image)
	frame(fixture, image)

	// The window's padding is 8 pixels: the image is at (108, 108).
	testing.expect_value(t, read_pixel(fixture.renderer, 108 + 32, 108 + 32), [4]u8{255, 0, 0, 255})
	mode: sdl.ScaleMode
	testing.expect(t, sdl.GetTextureScaleMode(red, &mode))
	testing.expect_value(t, mode, sdl.ScaleMode.NEAREST)
	clip_after: sdl.Rect
	testing.expect(t, sdl.RenderClipEnabled(fixture.renderer))
	testing.expect(t, sdl.GetRenderClipRect(fixture.renderer, &clip_after))
	testing.expect_value(t, clip_after, clip)
	testing.expect(t, !sdl.RenderViewportSet(fixture.renderer))
}

// The standard draw callbacks: SetSamplerNearest switches the next draws to nearest filtering, ResetRenderState back
// to linear.
@(test)
test_draw_callbacks :: proc(t: ^testing.T) {
	sync.guard(&test_mutex)
	fixture, ok := fixture_start(t)
	if !ok {
		return
	}
	defer fixture_stop(fixture)
	platform_io := im.GetPlatformIO()
	testing.expect(t, platform_io.DrawCallback_ResetRenderState != nil)
	testing.expect(t, platform_io.DrawCallback_SetSamplerLinear != nil)
	testing.expect(t, platform_io.DrawCallback_SetSamplerNearest != nil)
	testing.expect(t, platform_io.DrawCallback_SetSamplerFromTex != nil)

	@(static) seen: [3]sdl.ScaleMode
	callbacks :: proc() {
		record :: proc "c" (parent_list: ^im.DrawList, cmd: ^im.DrawCmd) {
			seen[int(uintptr(cmd.UserCallbackData))] = imgui_impl_sdlrenderer3.GetRenderState().current_scale_mode
		}
		draw_list := im.GetForegroundDrawList()
		platform_io := im.GetPlatformIO()
		im.DrawList_AddCallback(draw_list, record, rawptr(uintptr(0)))
		im.DrawList_AddCallback(draw_list, platform_io.DrawCallback_SetSamplerNearest)
		im.DrawList_AddCallback(draw_list, record, rawptr(uintptr(1)))
		im.DrawList_AddCallback(draw_list, platform_io.DrawCallback_ResetRenderState)
		im.DrawList_AddCallback(draw_list, record, rawptr(uintptr(2)))
		im.DrawList_AddRectFilled(draw_list, {10, 10}, {20, 20}, im.COL32_WHITE)
	}
	frame(fixture, callbacks)
	testing.expect_value(t, seen, [3]sdl.ScaleMode{.LINEAR, .NEAREST, .LINEAR})
	testing.expect_value(t, read_pixel(fixture.renderer, 15, 15), [4]u8{255, 255, 255, 255})
	testing.expect(t, imgui_impl_sdlrenderer3.GetRenderState() == nil) // only while rendering
}
