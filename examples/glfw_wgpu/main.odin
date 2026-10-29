// Dear ImGui with the Odin GLFW and WebGPU backends: a port of Dear ImGui's example_glfw_wgpu, with
// docking, the demo window, and a window written in Odin (plots, a custom drawing, a user texture).
//
//	odin run examples/glfw_wgpu
//
// Esc or closing the window quits. `--seconds=N` closes it after N seconds.
package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "vendor:glfw"
import "vendor:wgpu"
import glue "vendor:wgpu/glfwglue"
import im "../../imgui"
import "../../imgui/imgui_impl_glfw"
import "../../imgui/imgui_impl_wgpu"

Gpu :: struct {
	instance: wgpu.Instance,
	surface:  wgpu.Surface,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	format:   wgpu.TextureFormat,
	width:    u32,
	height:   u32,
}

// The state of the windows.
State :: struct {
	show_demo_window:    bool,
	show_another_window: bool,
	clear_color:         [4]f32,
	f:                   f32,
	counter:             int,
	text:                [256]u8,
	frame_times:         [120]f32,
	frame_time_index:    int,
	points:              [dynamic]im.Vec2,
	checker:             im.TextureID,
}

main :: proc() {
	seconds := 0.0
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--seconds=") {
			seconds, _ = strconv.parse_f64(arg[len("--seconds="):])
		}
	}

	glfw.SetErrorCallback(proc "c" (code: i32, description: cstring) {
		context = runtime.default_context()
		fmt.eprintfln("GLFW error %d: %s", code, description)
	})
	if !glfw.Init() {
		fmt.eprintln("glfw.Init failed")
		os.exit(1)
	}
	defer glfw.Terminate()

	// The DPI scale of the monitor (1 on macOS and Wayland, which scale the framebuffer instead).
	main_scale := imgui_impl_glfw.GetContentScaleForMonitor(glfw.GetPrimaryMonitor())
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	window := glfw.CreateWindow(i32(1280 * main_scale), i32(800 * main_scale), "Dear ImGui GLFW+WebGPU example (Odin)", nil, nil)
	if window == nil {
		fmt.eprintln("glfw.CreateWindow failed")
		os.exit(1)
	}
	defer glfw.DestroyWindow(window)

	gpu: Gpu
	if !init_gpu(&gpu, window) {
		os.exit(1)
	}
	defer shutdown_gpu(&gpu)

	// Dear ImGui.
	im.CreateContext()
	defer im.DestroyContext()
	io := im.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .NavEnableGamepad, .DockingEnable}

	style := im.GetStyle()
	im.StyleColorsDark()
	style.FrameRounding = 3
	style.GrabRounding = 3
	// A fixed scale for the sizes, and the initial one for fonts.
	im.Style_ScaleAllSizes(style, main_scale)
	style.FontScaleDpi = main_scale

	imgui_impl_glfw.InitForOther(window)
	defer imgui_impl_glfw.Shutdown()
	imgui_impl_wgpu.Init({device = gpu.device, num_frames_in_flight = 3, render_target_format = gpu.format})
	defer imgui_impl_wgpu.Shutdown()

	state := State {
		show_demo_window = true,
		clear_color      = {0.45, 0.55, 0.60, 1},
	}
	defer delete(state.points)
	checker_texture, checker_view := create_checker_texture(&gpu)
	defer {
		wgpu.TextureViewRelease(checker_view)
		wgpu.TextureRelease(checker_texture)
	}
	state.checker = im.TextureID(uintptr(checker_view))

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()
		wgpu.InstanceProcessEvents(gpu.instance)
		if seconds > 0 && glfw.GetTime() >= seconds {
			break
		}
		if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS && !io.WantCaptureKeyboard {
			break
		}
		if glfw.GetWindowAttrib(window, glfw.ICONIFIED) != 0 {
			imgui_impl_glfw.Sleep(10)
			continue
		}
		w, h := glfw.GetFramebufferSize(window)
		if w <= 0 || h <= 0 {
			imgui_impl_glfw.Sleep(10)
			continue
		}
		if u32(w) != gpu.width || u32(h) != gpu.height {
			configure_surface(&gpu, u32(w), u32(h))
		}
		surface_texture := wgpu.SurfaceGetCurrentTexture(gpu.surface)
		#partial switch surface_texture.status {
		case .SuccessOptimal, .SuccessSuboptimal:
		case .Outdated, .Lost:
			if surface_texture.texture != nil {
				wgpu.TextureRelease(surface_texture.texture)
			}
			configure_surface(&gpu, u32(w), u32(h))
			continue
		case .Error:
			fmt.panicf("wgpu.SurfaceGetCurrentTexture failed: %v", surface_texture.status)
		case:
			// Timeout, or wgpu-native's Occluded.
			continue
		}

		imgui_impl_wgpu.NewFrame()
		imgui_impl_glfw.NewFrame()
		im.NewFrame()
		draw_ui(&state, io)
		im.Render()

		view := wgpu.TextureCreateView(surface_texture.texture, &{
			format          = gpu.format,
			dimension       = ._2D,
			mipLevelCount   = wgpu.MIP_LEVEL_COUNT_UNDEFINED,
			arrayLayerCount = wgpu.ARRAY_LAYER_COUNT_UNDEFINED,
			aspect          = .All,
		})
		c := state.clear_color
		color_attachment := wgpu.RenderPassColorAttachment {
			view       = view,
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			loadOp     = .Clear,
			storeOp    = .Store,
			clearValue = {f64(c.r * c.a), f64(c.g * c.a), f64(c.b * c.a), f64(c.a)},
		}
		encoder := wgpu.DeviceCreateCommandEncoder(gpu.device)
		pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{colorAttachmentCount = 1, colorAttachments = &color_attachment})
		imgui_impl_wgpu.RenderDrawData(im.GetDrawData(), pass)
		wgpu.RenderPassEncoderEnd(pass)
		commands := wgpu.CommandEncoderFinish(encoder)
		wgpu.QueueSubmit(gpu.queue, {commands})
		wgpu.SurfacePresent(gpu.surface)

		wgpu.CommandBufferRelease(commands)
		wgpu.RenderPassEncoderRelease(pass)
		wgpu.CommandEncoderRelease(encoder)
		wgpu.TextureViewRelease(view)
		wgpu.TextureRelease(surface_texture.texture)
		free_all(context.temp_allocator)
	}
	// The GPU may still use the resources released by the deferred calls.
	wgpu.DevicePoll(gpu.device, true)
}

draw_ui :: proc(state: ^State, io: ^im.IO) {
	// A dock space over the whole window, which shows the clear color where nothing is docked.
	im.DockSpaceOverViewport(0, nil, {.PassthruCentralNode})

	if state.show_demo_window {
		im.ShowDemoWindow(&state.show_demo_window)
	}

	if im.Begin("Hello, world!") {
		im.Text("This is some useful text.")
		im.Checkbox("Demo Window", &state.show_demo_window)
		im.Checkbox("Another Window", &state.show_another_window)
		im.SliderFloat("float", &state.f, 0, 1)
		im.ColorEdit3("clear color", (^[3]f32)(&state.clear_color))
		if im.Button("Button") {
			state.counter += 1
		}
		im.SameLine()
		im.Text("counter = %d", state.counter)
		im.Text("Application average %.3f ms/frame (%.1f FPS)", 1000 / io.Framerate, io.Framerate)
	}
	im.End()

	if state.show_another_window {
		if im.Begin("Another Window", &state.show_another_window) {
			im.Text("Hello from another window!")
			if im.Button("Close Me") {
				state.show_another_window = false
			}
		}
		im.End()
	}

	draw_odin_window(state, io)
}

// Widgets that exercise the bindings from Odin.
draw_odin_window :: proc(state: ^State, io: ^im.IO) {
	state.frame_times[state.frame_time_index] = 1000 * io.DeltaTime
	state.frame_time_index = (state.frame_time_index + 1) % len(state.frame_times)

	im.SetNextWindowSize({460, 640}, .FirstUseEver)
	defer im.End()
	if !im.Begin("Odin") {
		return
	}

	im.SeparatorText("Text")
	im.TextColored({1, 0.8, 0.2, 1}, "Formatted with core:fmt: %v, %.2f, %s", [3]int{1, 2, 3}, math.PI, "ok")
	im.InputTextWithHint("##text", "Type here", &state.text[0], len(state.text))
	typed := string(cstring(&state.text[0]))
	im.Text("%d bytes, %d runes", len(typed), strings.rune_count(typed))

	im.SeparatorText("Plots")
	overlay := fmt.ctprintf("%.2f ms", state.frame_times[(state.frame_time_index + len(state.frame_times) - 1) % len(state.frame_times)])
	im.PlotLines("Frame time", &state.frame_times[0], i32(len(state.frame_times)), i32(state.frame_time_index), overlay, 0, 40, {0, 60})
	sines: [64]f32
	for &v, i in sines {
		v = f32(math.sin(f64(i) * 0.2 + glfw.GetTime() * 2))
	}
	im.PlotHistogram("Sine", &sines[0], len(sines), 0, nil, -1, 1, {0, 60})

	im.SeparatorText("Table")
	if im.BeginTable("keys", 3, im.TableFlags_Borders + im.TableFlags_SizingFixedFit + {.RowBg}) {
		im.TableSetupColumn("Key")
		im.TableSetupColumn("Down")
		im.TableSetupColumn("Name", {.WidthStretch})
		im.TableHeadersRow()
		for key in ([?]im.Key{.Space, .LeftCtrl, .LeftShift, .A, .MouseLeft}) {
			im.TableNextRow()
			im.TableNextColumn()
			im.Text("%v", key)
			im.TableNextColumn()
			im.Text("%v", im.IsKeyDown(key))
			im.TableNextColumn()
			im.TextUnformatted(string(im.GetKeyName(key)))
		}
		im.EndTable()
	}

	im.SeparatorText("Canvas (click to add points, right-click to clear)")
	canvas_pos := im.GetCursorScreenPos()
	canvas_size := im.Vec2{im.GetContentRegionAvail().x, 140}
	draw_list := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(draw_list, canvas_pos, canvas_pos + canvas_size, im.col32(40, 40, 48, 255))
	im.DrawList_AddRect(draw_list, canvas_pos, canvas_pos + canvas_size, im.col32(255, 255, 255, 120))
	im.InvisibleButton("canvas", canvas_size, {.MouseButtonLeft, .MouseButtonRight})
	if im.IsItemHovered() && im.IsMouseClicked(.Left) {
		append(&state.points, io.MousePos - canvas_pos)
	}
	if im.IsItemHovered() && im.IsMouseClicked(.Right) {
		clear(&state.points)
	}
	im.DrawList_PushClipRect(draw_list, canvas_pos, canvas_pos + canvas_size, true)
	if len(state.points) > 1 {
		points := make([]im.Vec2, len(state.points), context.temp_allocator)
		for p, i in state.points {
			points[i] = canvas_pos + p
		}
		im.DrawList_AddPolyline(draw_list, &points[0], i32(len(points)), im.col32(255, 200, 60, 255), 2)
	}
	for p in state.points {
		im.DrawList_AddCircleFilled(draw_list, canvas_pos + p, 4, im.col32(255, 100, 100, 255))
	}
	im.DrawList_AddText(draw_list, canvas_pos + {8, 6}, im.COL32_WHITE, fmt.tprintf("%d points", len(state.points)))
	im.DrawList_PopClipRect(draw_list)

	im.SeparatorText("User texture")
	im.Image({_TexID = state.checker}, {128, 128})
	im.SameLine()
	// A zoomed, tinted quarter of it. (The sampler clamps UVs outside 0-1 to the edges.)
	im.ImageWithBg({_TexID = state.checker}, {128, 128}, {0, 0}, {0.5, 0.5}, {0, 0, 0, 1}, {0.4, 1, 0.6, 1})
}

// A checkerboard, shown with im.Image: a user texture's TextureID is its wgpu.TextureView.
create_checker_texture :: proc(gpu: ^Gpu) -> (wgpu.Texture, wgpu.TextureView) {
	SIZE :: 64
	pixels: [SIZE * SIZE][4]u8
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			on := (x / 8 + y / 8) % 2 == 0
			pixels[y * SIZE + x] = {255, 255, 255, 255} if on else {u8(x * 4), u8(y * 4), 160, 255}
		}
	}
	texture := wgpu.DeviceCreateTexture(gpu.device, &{
		label         = "checker",
		usage         = {.TextureBinding, .CopyDst},
		dimension     = ._2D,
		size          = {SIZE, SIZE, 1},
		format        = .RGBA8Unorm,
		mipLevelCount = 1,
		sampleCount   = 1,
	})
	wgpu.QueueWriteTexture(gpu.queue, &{texture = texture, aspect = .All}, &pixels, size_of(pixels), &{bytesPerRow = SIZE * 4, rowsPerImage = SIZE}, &{SIZE, SIZE, 1})
	return texture, wgpu.TextureCreateView(texture)
}

init_gpu :: proc(gpu: ^Gpu, window: glfw.WindowHandle) -> bool {
	gpu.instance = wgpu.CreateInstance()
	if gpu.instance == nil {
		fmt.eprintln("wgpu.CreateInstance failed")
		return false
	}
	gpu.surface = glue.GetSurface(gpu.instance, window)

	// The callbacks run in InstanceProcessEvents (vendor:wgpu has no InstanceWaitAny).
	done := false
	wgpu.InstanceRequestAdapter(gpu.instance, &{compatibleSurface = gpu.surface, powerPreference = .HighPerformance}, {
		mode      = .AllowProcessEvents,
		userdata1 = gpu,
		userdata2 = &done,
		callback  = proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: wgpu.StringView, userdata1, userdata2: rawptr) {
			context = runtime.default_context()
			(^bool)(userdata2)^ = true
			if status != .Success {
				fmt.eprintfln("wgpu.InstanceRequestAdapter failed: %v: %s", status, message)
				return
			}
			(^Gpu)(userdata1).adapter = adapter
		},
	})
	for !done {
		wgpu.InstanceProcessEvents(gpu.instance)
	}
	if gpu.adapter == nil {
		return false
	}

	done = false
	wgpu.AdapterRequestDevice(gpu.adapter, &{
		label = "Dear ImGui example device",
		uncapturedErrorCallbackInfo = {
			callback = proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: wgpu.StringView, userdata1, userdata2: rawptr) {
				context = runtime.default_context()
				fmt.eprintfln("WebGPU error: %v: %s", type, message)
			},
		},
	}, {
		mode      = .AllowProcessEvents,
		userdata1 = gpu,
		userdata2 = &done,
		callback  = proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: wgpu.StringView, userdata1, userdata2: rawptr) {
			context = runtime.default_context()
			(^bool)(userdata2)^ = true
			if status != .Success {
				fmt.eprintfln("wgpu.AdapterRequestDevice failed: %v: %s", status, message)
				return
			}
			(^Gpu)(userdata1).device = device
		},
	})
	for !done {
		wgpu.InstanceProcessEvents(gpu.instance)
	}
	if gpu.device == nil {
		return false
	}
	gpu.queue = wgpu.DeviceGetQueue(gpu.device)

	caps, status := wgpu.SurfaceGetCapabilities(gpu.surface, gpu.adapter)
	if status != .Success || caps.formatCount == 0 {
		fmt.eprintln("wgpu.SurfaceGetCapabilities failed")
		return false
	}
	gpu.format = caps.formats[0]
	wgpu.SurfaceCapabilitiesFreeMembers(caps)

	w, h := glfw.GetFramebufferSize(window)
	configure_surface(gpu, u32(max(w, 1)), u32(max(h, 1)))
	return true
}

configure_surface :: proc(gpu: ^Gpu, width, height: u32) {
	gpu.width, gpu.height = width, height
	wgpu.SurfaceConfigure(gpu.surface, &{
		device      = gpu.device,
		format      = gpu.format,
		usage       = {.RenderAttachment},
		width       = width,
		height      = height,
		presentMode = .Fifo,
		alphaMode   = .Auto,
	})
}

shutdown_gpu :: proc(gpu: ^Gpu) {
	wgpu.QueueRelease(gpu.queue)
	wgpu.DeviceRelease(gpu.device)
	wgpu.AdapterRelease(gpu.adapter)
	wgpu.SurfaceRelease(gpu.surface)
	wgpu.InstanceRelease(gpu.instance)
}
