// Dear ImGui renderer backend for WebGPU, on vendor:wgpu (wgpu-native). An Odin port of
// backends/imgui_impl_wgpu.cpp of Dear ImGui 1.93.0 (docking), to use with a platform backend such as
// imgui_impl_glfw.
//
// Implemented: user textures (a wgpu.TextureView as TextureID), large meshes with 16-bit indices
// (BackendFlags.RendererHasVtxOffset), dynamic font atlas updates (BackendFlags.RendererHasTextures), the
// standard draw callbacks of PlatformIO, and the render state for draw callbacks (GetRenderState).
// Not implemented: multi-viewports, as in the C++ backend.
//
// The code only uses the API common to vendor:wgpu and dawn_webgpu_odin, so it builds against either.
//
//	imgui_impl_wgpu.Init({device = device, render_target_format = surface_format})
//	// Each frame, before im.NewFrame():
//	imgui_impl_wgpu.NewFrame()
//	// In a render pass, after im.Render():
//	imgui_impl_wgpu.RenderDrawData(im.GetDrawData(), pass)
//	// At exit:
//	imgui_impl_wgpu.Shutdown()
package imgui_impl_wgpu

import "base:runtime"
import "core:c"
import "core:mem"
import "vendor:wgpu"
import im ".."

InitInfo :: struct {
	device:                     wgpu.Device,
	// Frames that the GPU may render at once, each with its own vertex and index buffers. 0 means 3.
	num_frames_in_flight:       int,
	render_target_format:       wgpu.TextureFormat,
	// .Undefined when the render pass has no depth stencil attachment.
	depth_stencil_format:       wgpu.TextureFormat,
	// A zero count means 1, a zero mask all samples.
	pipeline_multisample_state: wgpu.MultisampleState,
}

// The render state during RenderDrawData, for draw callbacks: GetRenderState(), or
// im.GetPlatformIO().Renderer_RenderState.
RenderState :: struct {
	device:              wgpu.Device,
	render_pass_encoder: wgpu.RenderPassEncoder,
}

@(private)
Texture :: struct {
	texture: wgpu.Texture,
	view:    wgpu.TextureView,
}

@(private)
Frame_Resources :: struct {
	index_buffer:  wgpu.Buffer,
	vertex_buffer: wgpu.Buffer,
	index_host:    []im.DrawIdx,
	vertex_host:   []im.DrawVert,
}

@(private)
Uniforms :: struct {
	mvp:   [4][4]f32,
	gamma: f32,
}

// Backend data, in io.BackendRendererUserData.
@(private)
Data :: struct {
	init_info:                 InitInfo,
	device:                    wgpu.Device,
	queue:                     wgpu.Queue,
	pipeline:                  wgpu.RenderPipeline,
	render_state:              ^RenderState, // == im.GetPlatformIO().Renderer_RenderState while rendering.
	sampler_linear:            wgpu.Sampler,
	sampler_nearest:           wgpu.Sampler,
	uniforms:                  wgpu.Buffer,
	// Group 0: the uniforms and a sampler.
	common_bind_group_linear:  wgpu.BindGroup,
	common_bind_group_nearest: wgpu.BindGroup,
	// Group 1: the texture. One per texture used in the frame, created as needed.
	image_bind_group_layout:   wgpu.BindGroupLayout,
	image_bind_groups:         map[im.TextureID]wgpu.BindGroup,
	frames:                    []Frame_Resources,
	frame_index:               uint,
	allocator:                 runtime.Allocator,
}

@(private)
get_backend_data :: proc "contextless" () -> ^Data {
	return im.GetCurrentContext() != nil ? (^Data)(im.GetIO().BackendRendererUserData) : nil
}

GetRenderState :: proc "contextless" () -> ^RenderState {
	return (^RenderState)(im.GetPlatformIO().Renderer_RenderState)
}

@(private)
VERTEX_SHADER :: `
struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
};

struct Uniforms {
    mvp: mat4x4<f32>,
    gamma: f32,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

@vertex
fn main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.position = uniforms.mvp * vec4<f32>(in.position, 0.0, 1.0);
    out.color = in.color;
    out.uv = in.uv;
    return out;
}
`

@(private)
FRAGMENT_SHADER :: `
struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
};

struct Uniforms {
    mvp: mat4x4<f32>,
    gamma: f32,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var s: sampler;
@group(1) @binding(0) var t: texture_2d<f32>;

@fragment
fn main(in: VertexOutput) -> @location(0) vec4<f32> {
    let color = in.color * textureSample(t, s, in.uv);
    let corrected_color = pow(color.rgb, vec3<f32>(uniforms.gamma));
    return vec4<f32>(corrected_color, color.a);
}
`

@(private)
align_up :: #force_inline proc "contextless" (size, alignment: int) -> int {
	return (size + alignment - 1) & ~(alignment - 1)
}

@(private)
create_shader_module :: proc(device: wgpu.Device, wgsl: string) -> wgpu.ShaderModule {
	source := wgpu.ShaderSourceWGSL {
		chain = {sType = .ShaderSourceWGSL},
		code  = wgsl,
	}
	return wgpu.DeviceCreateShaderModule(device, &{nextInChain = &source, label = "Dear ImGui shader"})
}

@(private)
create_image_bind_group :: proc(bd: ^Data, view: wgpu.TextureView) -> wgpu.BindGroup {
	entry := wgpu.BindGroupEntry {
		binding     = 0,
		textureView = view,
	}
	return wgpu.DeviceCreateBindGroup(bd.device, &{layout = bd.image_bind_group_layout, entryCount = 1, entries = &entry})
}

@(private)
setup_render_state :: proc(bd: ^Data, draw_data: ^im.DrawData, pass: wgpu.RenderPassEncoder, fr: ^Frame_Resources) {
	// An orthographic projection: the visible space spans from draw_data.DisplayPos (top left) to
	// DisplayPos + DisplaySize (bottom right).
	l := draw_data.DisplayPos.x
	r := draw_data.DisplayPos.x + draw_data.DisplaySize.x
	t := draw_data.DisplayPos.y
	b := draw_data.DisplayPos.y + draw_data.DisplaySize.y
	uniforms := Uniforms {
		mvp = {
			{2 / (r - l), 0, 0, 0},
			{0, 2 / (t - b), 0, 0},
			{0, 0, 0.5, 0},
			{(r + l) / (l - r), (t + b) / (b - t), 0.5, 1},
		},
		// The shader converts colors to linear for sRGB targets.
		gamma = 2.2 if bd.init_info.render_target_format == .BGRA8UnormSrgb || bd.init_info.render_target_format == .RGBA8UnormSrgb else 1,
	}
	wgpu.QueueWriteBuffer(bd.queue, bd.uniforms, 0, &uniforms, size_of(Uniforms))

	fb_width := int(draw_data.DisplaySize.x * draw_data.FramebufferScale.x + 0.5)
	fb_height := int(draw_data.DisplaySize.y * draw_data.FramebufferScale.y + 0.5)
	wgpu.RenderPassEncoderSetViewport(pass, 0, 0, f32(fb_width), f32(fb_height), 0, 1)

	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, fr.vertex_buffer, 0, u64(len(fr.vertex_host) * size_of(im.DrawVert)))
	index_format: wgpu.IndexFormat = .Uint16 when size_of(im.DrawIdx) == 2 else .Uint32
	wgpu.RenderPassEncoderSetIndexBuffer(pass, fr.index_buffer, index_format, 0, u64(len(fr.index_host) * size_of(im.DrawIdx)))
	wgpu.RenderPassEncoderSetPipeline(pass, bd.pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, bd.common_bind_group_linear)
	wgpu.RenderPassEncoderSetBlendConstant(pass, &{0, 0, 0, 0})
}

// The standard draw callbacks, set in PlatformIO by Init.

// Empty: RenderDrawData recognizes it and resets the render state.
@(private)
draw_callback_reset_render_state :: proc "c" (parent_list: ^im.DrawList, cmd: ^im.DrawCmd) {}

@(private)
draw_callback_set_sampler_linear :: proc "c" (parent_list: ^im.DrawList, cmd: ^im.DrawCmd) {
	bd := get_backend_data()
	wgpu.RenderPassEncoderSetBindGroup(bd.render_state.render_pass_encoder, 0, bd.common_bind_group_linear)
}

@(private)
draw_callback_set_sampler_nearest :: proc "c" (parent_list: ^im.DrawList, cmd: ^im.DrawCmd) {
	bd := get_backend_data()
	wgpu.RenderPassEncoderSetBindGroup(bd.render_state.render_pass_encoder, 0, bd.common_bind_group_nearest)
}

// Grows a frame's vertex or index buffer to hold `count` elements, plus `extra`.
@(private)
reserve_buffer :: proc(bd: ^Data, buffer: ^wgpu.Buffer, host: ^[]$T, count, extra: int, usage: wgpu.BufferUsageFlags, label: string) -> bool {
	if buffer^ != nil && len(host^) >= count {
		return true
	}
	if buffer^ != nil {
		wgpu.BufferDestroy(buffer^)
		wgpu.BufferRelease(buffer^)
	}
	delete(host^, bd.allocator)
	size := count + extra
	buffer^ = wgpu.DeviceCreateBuffer(bd.device, &{label = label, usage = usage, size = u64(align_up(size * size_of(T), 4))})
	if buffer^ == nil {
		host^ = nil
		return false
	}
	host^ = make([]T, size, bd.allocator)
	return true
}

RenderDrawData :: proc(draw_data: ^im.DrawData, pass: wgpu.RenderPassEncoder) {
	// Nothing to render when minimized.
	fb_width := int(draw_data.DisplaySize.x * draw_data.FramebufferScale.x + 0.5)
	fb_height := int(draw_data.DisplaySize.y * draw_data.FramebufferScale.y + 0.5)
	if fb_width <= 0 || fb_height <= 0 || draw_data.CmdLists.Size == 0 {
		return
	}

	// Texture updates: most of the time, one texture with nothing to do. (draw_data.Textures almost always
	// points to im.GetPlatformIO().Textures.)
	if draw_data.Textures != nil {
		for tex in im.vector_slice(draw_data.Textures^) {
			if tex.Status != .OK {
				UpdateTexture(tex)
			}
		}
	}

	// Assumes one call per frame: the buffers of a frame in flight are not reused before it is rendered.
	bd := get_backend_data()
	bd.frame_index += 1
	fr := &bd.frames[bd.frame_index % len(bd.frames)]
	if !reserve_buffer(bd, &fr.vertex_buffer, &fr.vertex_host, int(draw_data.TotalVtxCount), 5000, {.CopyDst, .Vertex}, "Dear ImGui vertex buffer") ||
	   !reserve_buffer(bd, &fr.index_buffer, &fr.index_host, int(draw_data.TotalIdxCount), 10000, {.CopyDst, .Index}, "Dear ImGui index buffer") {
		return
	}

	// All the lists in one vertex buffer and one index buffer.
	vtx_count, idx_count := 0, 0
	for list in im.vector_slice(draw_data.CmdLists) {
		copy(fr.vertex_host[vtx_count:], im.vector_slice(list.VtxBuffer))
		copy(fr.index_host[idx_count:], im.vector_slice(list.IdxBuffer))
		vtx_count += int(list.VtxBuffer.Size)
		idx_count += int(list.IdxBuffer.Size)
	}
	// Buffer writes are multiples of 4 bytes: the host buffers are larger than the data.
	wgpu.QueueWriteBuffer(bd.queue, fr.vertex_buffer, 0, raw_data(fr.vertex_host), uint(align_up(vtx_count * size_of(im.DrawVert), 4)))
	wgpu.QueueWriteBuffer(bd.queue, fr.index_buffer, 0, raw_data(fr.index_host), uint(align_up(idx_count * size_of(im.DrawIdx), 4)))

	setup_render_state(bd, draw_data, pass, fr)

	platform_io := im.GetPlatformIO()
	render_state := RenderState{bd.device, pass}
	bd.render_state = &render_state
	platform_io.Renderer_RenderState = &render_state

	// The commands' offsets are relative to their list, the buffers hold all the lists.
	global_vtx_offset, global_idx_offset := 0, 0
	clip_scale := draw_data.FramebufferScale
	clip_off := draw_data.DisplayPos
	for list in im.vector_slice(draw_data.CmdLists) {
		for &cmd in im.vector_slice(list.CmdBuffer) {
			if cmd.UserCallback != nil {
				if cmd.UserCallback == draw_callback_reset_render_state {
					setup_render_state(bd, draw_data, pass, fr)
				} else {
					cmd.UserCallback(list, &cmd)
				}
				continue
			}
			// The texture: its view is its TextureID.
			tex_id := im.DrawCmd_GetTexID(&cmd)
			bind_group, found := bd.image_bind_groups[tex_id]
			if !found && tex_id != im.TextureID_Invalid {
				bind_group = create_image_bind_group(bd, wgpu.TextureView(uintptr(tex_id)))
				if bind_group != nil {
					bd.image_bind_groups[tex_id] = bind_group
				}
			}
			if bind_group != nil {
				wgpu.RenderPassEncoderSetBindGroup(pass, 1, bind_group)
			}

			// The clipping rectangle in framebuffer space, within the viewport as SetScissorRect requires.
			clip_min := im.Vec2{(cmd.ClipRect.x - clip_off.x) * clip_scale.x, (cmd.ClipRect.y - clip_off.y) * clip_scale.y}
			clip_max := im.Vec2{(cmd.ClipRect.z - clip_off.x) * clip_scale.x, (cmd.ClipRect.w - clip_off.y) * clip_scale.y}
			clip_min = {max(clip_min.x, 0), max(clip_min.y, 0)}
			clip_max = {min(clip_max.x, f32(fb_width)), min(clip_max.y, f32(fb_height))}
			if clip_max.x <= clip_min.x || clip_max.y <= clip_min.y {
				continue
			}
			wgpu.RenderPassEncoderSetScissorRect(pass, u32(clip_min.x), u32(clip_min.y), u32(clip_max.x - clip_min.x), u32(clip_max.y - clip_min.y))
			wgpu.RenderPassEncoderDrawIndexed(pass, cmd.ElemCount, 1, cmd.IdxOffset + u32(global_idx_offset), i32(cmd.VtxOffset) + i32(global_vtx_offset), 0)
		}
		global_idx_offset += int(list.IdxBuffer.Size)
		global_vtx_offset += int(list.VtxBuffer.Size)
	}

	// The render pass keeps what it uses alive.
	for _, bind_group in bd.image_bind_groups {
		wgpu.BindGroupRelease(bind_group)
	}
	clear(&bd.image_bind_groups)
	bd.render_state = nil
	platform_io.Renderer_RenderState = nil
}

@(private)
destroy_texture :: proc(bd: ^Data, tex: ^im.TextureData) {
	if backend_tex := (^Texture)(tex.BackendUserData); backend_tex != nil {
		assert(backend_tex.view == wgpu.TextureView(uintptr(tex.TexID)))
		wgpu.TextureViewRelease(backend_tex.view)
		wgpu.TextureRelease(backend_tex.texture)
		free(backend_tex, bd.allocator)
		// Cleared, so that InvalidateDeviceObjects can be called while running.
		im.TextureData_SetTexID(tex, im.TextureID_Invalid)
		tex.BackendUserData = nil
	}
	im.TextureData_SetStatus(tex, .Destroyed)
}

// Creates, updates or destroys a texture as ImGui requests. Called by RenderDrawData for the textures of
// the frame.
UpdateTexture :: proc(tex: ^im.TextureData) {
	bd := get_backend_data()
	if tex.Status == .WantCreate {
		assert(tex.TexID == im.TextureID_Invalid && tex.BackendUserData == nil)
		assert(tex.Format == .RGBA32)
		backend_tex := new(Texture, bd.allocator)
		backend_tex.texture = wgpu.DeviceCreateTexture(bd.device, &{
			label         = "Dear ImGui texture",
			usage         = {.CopyDst, .TextureBinding},
			dimension     = ._2D,
			size          = {u32(tex.Width), u32(tex.Height), 1},
			format        = .RGBA8Unorm,
			mipLevelCount = 1,
			sampleCount   = 1,
		})
		backend_tex.view = wgpu.TextureCreateView(backend_tex.texture, &{
			format          = .RGBA8Unorm,
			dimension       = ._2D,
			mipLevelCount   = 1,
			arrayLayerCount = 1,
			aspect          = .All,
		})
		im.TextureData_SetTexID(tex, im.TextureID(uintptr(backend_tex.view)))
		tex.BackendUserData = backend_tex
		// The status stays WantCreate, for the upload below.
	}
	if tex.Status == .WantCreate || tex.Status == .WantUpdates {
		backend_tex := (^Texture)(tex.BackendUserData)
		assert(tex.Format == .RGBA32)
		// The whole texture on creation, which also clears it. Updates only write to regions that were
		// never used. UpdateRect bounds them all; tex.Updates has each of them.
		x, y, w, h := c.int(0), c.int(0), tex.Width, tex.Height
		if tex.Status == .WantUpdates {
			x, y, w, h = c.int(tex.UpdateRect.x), c.int(tex.UpdateRect.y), c.int(tex.UpdateRect.w), c.int(tex.UpdateRect.h)
		}
		pixels := mem.ptr_offset(tex.Pixels, int((x + y * tex.Width) * tex.BytesPerPixel))
		wgpu.QueueWriteTexture(
			bd.queue,
			&{texture = backend_tex.texture, origin = {u32(x), u32(y), 0}, aspect = .All},
			pixels,
			uint(tex.Width * h * tex.BytesPerPixel),
			&{bytesPerRow = u32(tex.Width * tex.BytesPerPixel), rowsPerImage = u32(h)},
			&{u32(w), u32(h), 1},
		)
		im.TextureData_SetStatus(tex, .OK)
	}
	if tex.Status == .WantDestroy && tex.UnusedFrames > 0 {
		destroy_texture(bd, tex)
	}
}

CreateDeviceObjects :: proc() -> bool {
	bd := get_backend_data()
	if bd.device == nil {
		return false
	}
	if bd.pipeline != nil {
		InvalidateDeviceObjects()
	}

	common_layout_entries := [2]wgpu.BindGroupLayoutEntry {
		{binding = 0, visibility = {.Vertex, .Fragment}, buffer = {type = .Uniform}},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	image_layout_entry := wgpu.BindGroupLayoutEntry {
		binding    = 0,
		visibility = {.Fragment},
		texture    = {sampleType = .Float, viewDimension = ._2D},
	}
	bind_group_layouts := [2]wgpu.BindGroupLayout {
		wgpu.DeviceCreateBindGroupLayout(bd.device, &{entryCount = len(common_layout_entries), entries = &common_layout_entries[0]}),
		wgpu.DeviceCreateBindGroupLayout(bd.device, &{entryCount = 1, entries = &image_layout_entry}),
	}
	pipeline_layout := wgpu.DeviceCreatePipelineLayout(bd.device, &{bindGroupLayoutCount = len(bind_group_layouts), bindGroupLayouts = &bind_group_layouts[0]})

	vertex_module := create_shader_module(bd.device, VERTEX_SHADER)
	fragment_module := create_shader_module(bd.device, FRAGMENT_SHADER)

	attributes := [3]wgpu.VertexAttribute {
		{format = .Float32x2, offset = u64(offset_of(im.DrawVert, pos)), shaderLocation = 0},
		{format = .Float32x2, offset = u64(offset_of(im.DrawVert, uv)), shaderLocation = 1},
		{format = .Unorm8x4, offset = u64(offset_of(im.DrawVert, col)), shaderLocation = 2},
	}
	vertex_layout := wgpu.VertexBufferLayout {
		stepMode       = .Vertex,
		arrayStride    = size_of(im.DrawVert),
		attributeCount = len(attributes),
		attributes     = &attributes[0],
	}
	blend := wgpu.BlendState {
		color = {operation = .Add, srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha},
		alpha = {operation = .Add, srcFactor = .One, dstFactor = .OneMinusSrcAlpha},
	}
	color_target := wgpu.ColorTargetState {
		format    = bd.init_info.render_target_format,
		blend     = &blend,
		writeMask = wgpu.ColorWriteMaskFlags_All,
	}
	keep := wgpu.StencilFaceState{compare = .Always, failOp = .Keep, depthFailOp = .Keep, passOp = .Keep}
	depth_stencil := wgpu.DepthStencilState {
		format            = bd.init_info.depth_stencil_format,
		depthWriteEnabled = .False,
		depthCompare      = .Always,
		stencilFront      = keep,
		stencilBack       = keep,
		stencilReadMask   = 0xFFFFFFFF,
		stencilWriteMask  = 0xFFFFFFFF,
	}
	multisample := bd.init_info.pipeline_multisample_state
	if multisample.count == 0 {
		multisample.count = 1
	}
	if multisample.mask == 0 {
		multisample.mask = 0xFFFFFFFF
	}
	bd.pipeline = wgpu.DeviceCreateRenderPipeline(bd.device, &{
		label = "Dear ImGui pipeline",
		layout = pipeline_layout,
		vertex = {module = vertex_module, entryPoint = "main", bufferCount = 1, buffers = &vertex_layout},
		primitive = {topology = .TriangleList, frontFace = .CW, cullMode = .None},
		depthStencil = nil if bd.init_info.depth_stencil_format == .Undefined else &depth_stencil,
		multisample = multisample,
		fragment = &{module = fragment_module, entryPoint = "main", targetCount = 1, targets = &color_target},
	})

	uniforms_size := u64(align_up(size_of(Uniforms), 16))
	bd.uniforms = wgpu.DeviceCreateBuffer(bd.device, &{label = "Dear ImGui uniform buffer", usage = {.CopyDst, .Uniform}, size = uniforms_size})

	sampler := wgpu.SamplerDescriptor {
		addressModeU  = .ClampToEdge,
		addressModeV  = .ClampToEdge,
		addressModeW  = .ClampToEdge,
		magFilter     = .Linear,
		minFilter     = .Linear,
		mipmapFilter  = .Linear,
		lodMaxClamp   = 32,
		maxAnisotropy = 1,
	}
	bd.sampler_linear = wgpu.DeviceCreateSampler(bd.device, &sampler)
	sampler.magFilter, sampler.minFilter, sampler.mipmapFilter = .Nearest, .Nearest, .Nearest
	bd.sampler_nearest = wgpu.DeviceCreateSampler(bd.device, &sampler)

	// One common bind group per sampler.
	common_entries := [2]wgpu.BindGroupEntry {
		{binding = 0, buffer = bd.uniforms, size = uniforms_size},
		{binding = 1, sampler = bd.sampler_linear},
	}
	common_desc := wgpu.BindGroupDescriptor {
		layout     = bind_group_layouts[0],
		entryCount = len(common_entries),
		entries    = &common_entries[0],
	}
	bd.common_bind_group_linear = wgpu.DeviceCreateBindGroup(bd.device, &common_desc)
	common_entries[1].sampler = bd.sampler_nearest
	bd.common_bind_group_nearest = wgpu.DeviceCreateBindGroup(bd.device, &common_desc)
	bd.image_bind_group_layout = bind_group_layouts[1]

	wgpu.ShaderModuleRelease(vertex_module)
	wgpu.ShaderModuleRelease(fragment_module)
	wgpu.PipelineLayoutRelease(pipeline_layout)
	wgpu.BindGroupLayoutRelease(bind_group_layouts[0])
	return bd.pipeline != nil
}

InvalidateDeviceObjects :: proc() {
	bd := get_backend_data()
	if bd.device == nil {
		return
	}
	release :: proc(handle: ^$T, release_proc: proc "c" (T)) {
		if handle^ != nil {
			release_proc(handle^)
			handle^ = nil
		}
	}
	release(&bd.pipeline, wgpu.RenderPipelineRelease)
	release(&bd.sampler_linear, wgpu.SamplerRelease)
	release(&bd.sampler_nearest, wgpu.SamplerRelease)
	release(&bd.uniforms, wgpu.BufferRelease)
	release(&bd.common_bind_group_linear, wgpu.BindGroupRelease)
	release(&bd.common_bind_group_nearest, wgpu.BindGroupRelease)
	release(&bd.image_bind_group_layout, wgpu.BindGroupLayoutRelease)

	// The textures of this context only: shared ones belong to the other contexts too.
	for tex in im.vector_slice(im.GetPlatformIO().Textures) {
		if tex.RefCount == 1 {
			destroy_texture(bd, tex)
		}
	}
	for &fr in bd.frames {
		release(&fr.index_buffer, wgpu.BufferRelease)
		release(&fr.vertex_buffer, wgpu.BufferRelease)
		delete(fr.index_host, bd.allocator)
		delete(fr.vertex_host, bd.allocator)
		fr.index_host, fr.vertex_host = nil, nil
	}
}

Init :: proc(init_info: InitInfo) -> bool {
	io := im.GetIO()
	if !im.CHECKVERSION() {
		return false
	}
	assert(io.BackendRendererUserData == nil, "imgui_impl_wgpu: a renderer backend is already initialized")

	bd := new(Data)
	bd.allocator = context.allocator
	bd.init_info = init_info
	bd.device = init_info.device
	bd.queue = wgpu.DeviceGetQueue(bd.device)
	bd.frames = make([]Frame_Resources, init_info.num_frames_in_flight if init_info.num_frames_in_flight > 0 else 3)
	bd.frame_index = max(uint)
	bd.image_bind_groups = make(map[im.TextureID]wgpu.BindGroup)

	io.BackendRendererUserData = bd
	io.BackendRendererName = "imgui_impl_wgpu (odin, vendor:wgpu)"
	// Large meshes with 16-bit indices, and dynamic font atlas.
	io.BackendFlags += {.RendererHasVtxOffset, .RendererHasTextures}

	platform_io := im.GetPlatformIO()
	platform_io.DrawCallback_ResetRenderState = draw_callback_reset_render_state
	platform_io.DrawCallback_SetSamplerLinear = draw_callback_set_sampler_linear
	platform_io.DrawCallback_SetSamplerNearest = draw_callback_set_sampler_nearest
	return true
}

Shutdown :: proc() {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_wgpu: no renderer backend to shut down, or already shut down")
	io := im.GetIO()

	InvalidateDeviceObjects()
	delete(bd.frames, bd.allocator)
	delete(bd.image_bind_groups)
	wgpu.QueueRelease(bd.queue)

	io.BackendRendererName = nil
	io.BackendRendererUserData = nil
	io.BackendFlags -= {.RendererHasVtxOffset, .RendererHasTextures}
	im.PlatformIO_ClearRendererHandlers(im.GetPlatformIO())
	free(bd, bd.allocator)
}

NewFrame :: proc() {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_wgpu: not initialized, call Init first")
	if bd.pipeline == nil {
		ok := CreateDeviceObjects()
		assert(ok, "imgui_impl_wgpu: CreateDeviceObjects failed")
	}
}
