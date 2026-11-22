// Dear ImGui renderer backend for SDL 3's 2D renderer (SDL_Renderer), on the sdl3 collection. An Odin port of
// backends/imgui_impl_sdlrenderer3.cpp of Dear ImGui 1.93.0 (docking), to use with the platform backend
// imgui_impl_sdl3.
//
// Implemented: user textures (an ^sdl.Texture as TextureID), large meshes with 16-bit indices
// (BackendFlags.RendererHasVtxOffset), dynamic font atlas updates (BackendFlags.RendererHasTextures), the
// standard draw callbacks of PlatformIO (the sampler ones set the textures' scale mode, restored after rendering),
// and the render state for draw callbacks (GetRenderState).
// Not implemented: multi-viewports, as in the C++ backend.
//
// It imports sdl3:sdl3, and needs an SDL with its 2D renderer: -collection:sdl3=$(odin root)/vendor for Odin's
// vendor:sdl3. The lean library of sdl3_odin leaves the renderer out, though its bindings declare it.
//
//	imgui_impl_sdl3.InitForSDLRenderer(window, renderer)
//	imgui_impl_sdlrenderer3.Init(renderer)
//	// Each frame, before im.NewFrame():
//	imgui_impl_sdlrenderer3.NewFrame()
//	imgui_impl_sdl3.NewFrame()
//	// After im.Render(), before sdl.RenderPresent():
//	imgui_impl_sdlrenderer3.RenderDrawData(im.GetDrawData(), renderer)
//	// At exit, before imgui_impl_sdl3.Shutdown():
//	imgui_impl_sdlrenderer3.Shutdown()
package imgui_impl_sdlrenderer3

import "base:runtime"
import "core:c"
import sdl "sdl3:sdl3"
import im ".."

// The render state during RenderDrawData, for draw callbacks: GetRenderState(), or
// im.GetPlatformIO().Renderer_RenderState.
RenderState :: struct {
	renderer:           ^sdl.Renderer,
	// The scale mode the next draws use. .INVALID keeps each texture's own (DrawCallback_SetSamplerFromTex).
	current_scale_mode: sdl.ScaleMode,
}

// A texture whose scale mode RenderDrawData changed, and the mode to restore (.INVALID once restored).
@(private)
Tex_Scale_Mode_Entry :: struct {
	texture:           ^sdl.Texture,
	scale_mode_backup: sdl.ScaleMode,
}

// Backend data, in io.BackendRendererUserData.
@(private)
Data :: struct {
	renderer:                ^sdl.Renderer, // the main viewport's
	color_buffer:            [dynamic]sdl.FColor,
	tex_scale_mode_backups:  [dynamic]Tex_Scale_Mode_Entry,
	allocator:               runtime.Allocator,
}

@(private)
get_backend_data :: proc "contextless" () -> ^Data {
	return im.GetCurrentContext() != nil ? (^Data)(im.GetIO().BackendRendererUserData) : nil
}

GetRenderState :: proc "contextless" () -> ^RenderState {
	return (^RenderState)(im.GetPlatformIO().Renderer_RenderState)
}

@(private)
setup_render_state :: proc "contextless" (renderer: ^sdl.Renderer) {
	render_state := GetRenderState()

	// Clears the viewport and clipping rectangle the program set. (Upstream: there is more that could be saved, set and
	// restored around the rendering.)
	_ = sdl.SetRenderViewport(renderer, nil)
	_ = sdl.SetRenderClipRect(renderer, nil)
	render_state.current_scale_mode = .LINEAR
}

NewFrame :: proc() {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_sdlrenderer3: not initialized, call Init first")
}

// SDL_RenderGeometryRaw takes float colors only (libsdl-org/SDL#9009): the vertices' 8-bit colors are converted into
// bd.color_buffer first.
@(private)
render_geometry_raw_8bit_color :: proc(
	renderer: ^sdl.Renderer, colors_out: ^[dynamic]sdl.FColor, texture: ^sdl.Texture, vertices: []im.DrawVert,
	indices: rawptr, num_indices: c.int, size_indices: c.int,
) -> bool {
	resize(colors_out, len(vertices))
	for vertex, i in vertices {
		color := transmute([4]u8)vertex.col // the bytes as they are in memory, as SDL_Color reads them
		colors_out[i] = {f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255, f32(color.a) / 255}
	}
	if len(vertices) == 0 {
		return true
	}
	return sdl.RenderGeometryRaw(
		renderer,
		texture,
		&vertices[0].pos[0],
		size_of(im.DrawVert),
		raw_data(colors_out^),
		size_of(sdl.FColor),
		&vertices[0].uv[0],
		size_of(im.DrawVert),
		c.int(len(vertices)),
		indices,
		num_indices,
		size_indices,
	)
}

// The standard draw callbacks, set in PlatformIO by Init.

// Empty: RenderDrawData recognizes it and resets the render state.
@(private)
draw_callback_reset_render_state :: proc "c" (parent_list: ^im.DrawList, cmd: ^im.DrawCmd) {}

@(private)
draw_callback_set_sampler_linear :: proc "c" (parent_list: ^im.DrawList, cmd: ^im.DrawCmd) {
	GetRenderState().current_scale_mode = .LINEAR
}

@(private)
draw_callback_set_sampler_nearest :: proc "c" (parent_list: ^im.DrawList, cmd: ^im.DrawCmd) {
	GetRenderState().current_scale_mode = .NEAREST
}

// .INVALID: use (or keep) the texture's own scale mode.
@(private)
draw_callback_set_sampler_from_tex :: proc "c" (parent_list: ^im.DrawList, cmd: ^im.DrawCmd) {
	GetRenderState().current_scale_mode = .INVALID
}

// SDL_Renderer ties the filtering to a texture, and does not queue a change of it with the draws, so a change needs a
// flush. The texture's mode is saved the first time it changes, and restored at the end of RenderDrawData.
@(private)
tex_scale_mode_update :: proc(renderer: ^sdl.Renderer, tex: ^sdl.Texture, desired_scale_mode: sdl.ScaleMode) {
	bd := get_backend_data()
	if desired_scale_mode != .INVALID {
		// Enforce a scale mode.
		tex_scale_mode := desired_scale_mode
		if !sdl.GetTextureScaleMode(tex, &tex_scale_mode) || tex_scale_mode == desired_scale_mode {
			return
		}
		_ = sdl.FlushRenderer(renderer)
		_ = sdl.SetTextureScaleMode(tex, desired_scale_mode)

		// Save the old scale mode (upstream: FIXME-OPT).
		for &entry in bd.tex_scale_mode_backups {
			if entry.texture == tex {
				if entry.scale_mode_backup == .INVALID {
					entry.scale_mode_backup = tex_scale_mode
				}
				return
			}
		}
		append(&bd.tex_scale_mode_backups, Tex_Scale_Mode_Entry{tex, tex_scale_mode})
	} else {
		// The texture's own scale mode, as the program set it: restore it if it was changed, and clear the entry.
		for &entry in bd.tex_scale_mode_backups {
			if entry.texture == tex && entry.scale_mode_backup != .INVALID {
				_ = sdl.FlushRenderer(renderer)
				_ = sdl.SetTextureScaleMode(tex, entry.scale_mode_backup)
				entry.scale_mode_backup = .INVALID
				return
			}
		}
	}
}

@(private)
tex_scale_mode_restore_backups :: proc(renderer: ^sdl.Renderer) {
	bd := get_backend_data()
	if len(bd.tex_scale_mode_backups) == 0 {
		return
	}
	_ = sdl.FlushRenderer(renderer)
	for entry in bd.tex_scale_mode_backups {
		if entry.scale_mode_backup != .INVALID {
			_ = sdl.SetTextureScaleMode(entry.texture, entry.scale_mode_backup)
		}
	}
	clear(&bd.tex_scale_mode_backups)
}

RenderDrawData :: proc(draw_data: ^im.DrawData, renderer: ^sdl.Renderer) {
	bd := get_backend_data()

	// With a scale set on the renderer (SDL_SetRenderScale), SDL scales what RenderGeometryRaw gets: we don't scale it
	// again here.
	rsx, rsy: f32 = 1, 1
	_ = sdl.GetRenderScale(renderer, &rsx, &rsy)
	render_scale := im.Vec2{draw_data.FramebufferScale.x if rsx == 1 else 1, draw_data.FramebufferScale.y if rsy == 1 else 1}

	// Nothing to render when minimized. The coordinates are scaled for high-density displays (screen coordinates !=
	// framebuffer coordinates).
	fb_width := c.int(draw_data.DisplaySize.x * render_scale.x)
	fb_height := c.int(draw_data.DisplaySize.y * render_scale.y)
	if fb_width == 0 || fb_height == 0 {
		return
	}

	// Texture updates: most of the time, one texture with nothing to do. (draw_data.Textures almost always points to
	// im.GetPlatformIO().Textures.)
	if draw_data.Textures != nil {
		for tex in im.vector_slice(draw_data.Textures^) {
			if tex.Status != .OK {
				UpdateTexture(tex)
			}
		}
	}

	// The renderer state changed below, restored at the end.
	old_viewport, old_clip_rect: sdl.Rect
	old_viewport_enabled := sdl.RenderViewportSet(renderer)
	old_clip_enabled := sdl.RenderClipEnabled(renderer)
	_ = sdl.GetRenderViewport(renderer, &old_viewport)
	_ = sdl.GetRenderClipRect(renderer, &old_clip_rect)

	// The render state, for callbacks and custom texture bindings.
	platform_io := im.GetPlatformIO()
	render_state := RenderState{renderer = renderer}
	platform_io.Renderer_RenderState = &render_state

	setup_render_state(renderer)
	assert(len(bd.tex_scale_mode_backups) == 0)

	// The clipping rectangles are projected into framebuffer space.
	clip_off := draw_data.DisplayPos // (0, 0) unless using multi-viewports
	clip_scale := render_scale

	for list in im.vector_slice(draw_data.CmdLists) {
		vertices := im.vector_slice(list.VtxBuffer)
		indices := list.IdxBuffer.Data
		for &cmd in im.vector_slice(list.CmdBuffer) {
			if cmd.UserCallback != nil {
				// A user callback, from DrawList_AddCallback.
				if cmd.UserCallback == draw_callback_reset_render_state {
					setup_render_state(renderer)
				} else {
					cmd.UserCallback(list, &cmd)
				}
				continue
			}

			// The clipping rectangle in framebuffer space.
			clip_min := im.Vec2{(cmd.ClipRect.x - clip_off.x) * clip_scale.x, (cmd.ClipRect.y - clip_off.y) * clip_scale.y}
			clip_max := im.Vec2{(cmd.ClipRect.z - clip_off.x) * clip_scale.x, (cmd.ClipRect.w - clip_off.y) * clip_scale.y}
			clip_min = {max(clip_min.x, 0), max(clip_min.y, 0)}
			clip_max = {min(clip_max.x, f32(fb_width)), min(clip_max.y, f32(fb_height))}
			if clip_max.x <= clip_min.x || clip_max.y <= clip_min.y {
				continue
			}
			r := sdl.Rect{c.int(clip_min.x), c.int(clip_min.y), c.int(clip_max.x - clip_min.x), c.int(clip_max.y - clip_min.y)}
			_ = sdl.SetRenderClipRect(renderer, &r)

			// The texture's scale (filtering) mode.
			tex := (^sdl.Texture)(uintptr(im.DrawCmd_GetTexID(&cmd)))
			tex_scale_mode_update(renderer, tex, render_state.current_scale_mode)

			_ = render_geometry_raw_8bit_color(
				renderer,
				&bd.color_buffer,
				tex,
				vertices[cmd.VtxOffset:],
				&indices[cmd.IdxOffset],
				c.int(cmd.ElemCount),
				size_of(im.DrawIdx),
			)
		}
	}
	platform_io.Renderer_RenderState = nil

	// Restore the renderer state.
	_ = sdl.SetRenderViewport(renderer, &old_viewport if old_viewport_enabled else nil)
	_ = sdl.SetRenderClipRect(renderer, &old_clip_rect if old_clip_enabled else nil)
	tex_scale_mode_restore_backups(renderer)
}

// Creates, updates or destroys a texture as ImGui requests. Called by RenderDrawData for the textures of the frame.
UpdateTexture :: proc(tex: ^im.TextureData) {
	bd := get_backend_data()
	if tex.Status == .WantCreate {
		// Create the texture and upload it.
		assert(tex.TexID == im.TextureID_Invalid && tex.BackendUserData == nil)
		assert(tex.Format == .RGBA32)

		// Bilinear sampling is required.
		sdl_texture := sdl.CreateTexture(bd.renderer, .RGBA32, .STATIC, tex.Width, tex.Height)
		assert(sdl_texture != nil, "imgui_impl_sdlrenderer3: failed to create a texture")
		_ = sdl.UpdateTexture(sdl_texture, nil, im.TextureData_GetPixels(tex), im.TextureData_GetPitch(tex))
		_ = sdl.SetTextureBlendMode(sdl_texture, sdl.BLENDMODE_BLEND)
		_ = sdl.SetTextureScaleMode(sdl_texture, .LINEAR)

		im.TextureData_SetTexID(tex, im.TextureID(uintptr(sdl_texture)))
		im.TextureData_SetStatus(tex, .OK)
	} else if tex.Status == .WantUpdates {
		// Update the regions given. Only regions that were never used before are written to. (This backend uses
		// tex.Updates; tex.UpdateRect bounds them all.)
		sdl_texture := (^sdl.Texture)(uintptr(tex.TexID))
		for r in im.vector_slice(tex.Updates) {
			sdl_r := sdl.Rect{c.int(r.x), c.int(r.y), c.int(r.w), c.int(r.h)}
			pixels := im.TextureData_GetPixelsAt(tex, c.int(r.x), c.int(r.y))
			_ = sdl.UpdateTexture(sdl_texture, &sdl_r, pixels, im.TextureData_GetPitch(tex))
		}
		im.TextureData_SetStatus(tex, .OK)
	} else if tex.Status == .WantDestroy {
		if tex.TexID != im.TextureID_Invalid {
			if sdl_texture := (^sdl.Texture)(uintptr(tex.TexID)); sdl_texture != nil {
				sdl.DestroyTexture(sdl_texture)
			}
		}
		// Cleared, so that DestroyDeviceObjects can be called while running.
		im.TextureData_SetTexID(tex, im.TextureID_Invalid)
		im.TextureData_SetStatus(tex, .Destroyed)
	}
}

CreateDeviceObjects :: proc() {
}

DestroyDeviceObjects :: proc() {
	// The textures of this context only: shared ones belong to the other contexts too.
	for tex in im.vector_slice(im.GetPlatformIO().Textures) {
		if tex.RefCount == 1 {
			im.TextureData_SetStatus(tex, .WantDestroy)
			UpdateTexture(tex)
		}
	}
}

Init :: proc(renderer: ^sdl.Renderer) -> bool {
	io := im.GetIO()
	if !im.CHECKVERSION() {
		return false
	}
	assert(io.BackendRendererUserData == nil, "imgui_impl_sdlrenderer3: a renderer backend is already initialized")
	assert(renderer != nil, "imgui_impl_sdlrenderer3: no SDL_Renderer")

	bd := new(Data)
	bd.allocator = context.allocator
	bd.color_buffer.allocator = context.allocator
	bd.tex_scale_mode_backups.allocator = context.allocator
	io.BackendRendererUserData = bd
	io.BackendRendererName = "imgui_impl_sdlrenderer3 (odin)"
	// Large meshes with 16-bit indices, and dynamic font atlas.
	io.BackendFlags += {.RendererHasVtxOffset, .RendererHasTextures}

	platform_io := im.GetPlatformIO()
	platform_io.DrawCallback_ResetRenderState = draw_callback_reset_render_state
	platform_io.DrawCallback_SetSamplerLinear = draw_callback_set_sampler_linear
	platform_io.DrawCallback_SetSamplerNearest = draw_callback_set_sampler_nearest
	platform_io.DrawCallback_SetSamplerFromTex = draw_callback_set_sampler_from_tex

	bd.renderer = renderer
	return true
}

Shutdown :: proc() {
	bd := get_backend_data()
	assert(bd != nil, "imgui_impl_sdlrenderer3: no renderer backend to shut down, or already shut down")
	io := im.GetIO()

	DestroyDeviceObjects()
	delete(bd.color_buffer)
	delete(bd.tex_scale_mode_backups)

	io.BackendRendererName = nil
	io.BackendRendererUserData = nil
	io.BackendFlags -= {.RendererHasVtxOffset, .RendererHasTextures}
	im.PlatformIO_ClearRendererHandlers(im.GetPlatformIO())
	free(bd, bd.allocator)
}
