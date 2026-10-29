# imgui_odin

Odin bindings for [Dear ImGui](https://github.com/ocornut/imgui) (docking branch), through the C API of
[dear_bindings](https://github.com/dearimgui/dear_bindings), with the GLFW and WebGPU backends written in
Odin. Supported: Linux x86_64 and macOS arm64.

Currently Dear ImGui 1.93.0 (docking), dear_bindings 0.26 (`upstream/version.env`).

The bindings are generated from dear_bindings' `dcimgui.json` by an Odin program, and checked against
the C headers by an ABI check. The library, Dear ImGui and its C API, builds in seconds with a C++
compiler, or comes prebuilt from this repository's releases. It has no C++ runtime dependency.

## Layout

| Path | |
|---|---|
| `imgui/` | Package `imgui`: `imgui_generated.odin` (generated), `imgui.odin` (library selection, helpers). |
| `imgui/imgui_impl_glfw/` | The GLFW platform backend, on `vendor:glfw`. |
| `imgui/imgui_impl_wgpu/` | The WebGPU renderer backend, on `vendor:wgpu`. |
| `upstream/imgui/` | The Dear ImGui sources the library is built from (no backends). |
| `upstream/dear_bindings/` | The dear_bindings files: the C API (`.h`, `.cpp`) and its description (`.json`). |
| `upstream/imconfig_odin.h` | The Dear ImGui configuration of the library and the bindings. |
| `upstream/version.env` | The dear_bindings release and Dear ImGui commit in `upstream/`. |
| `upstream/release.env` | The release whose libraries match the bindings. |
| `lib/<os>-<arch>/` | `libdcimgui.a` and `.dylib`/`.so`, from `fetch_imgui_libs.sh` or `build_imgui.sh`. Not committed. |
| `tools/gen/` | The generator, `dcimgui.json` → Odin, with its tests. |
| `tools/abi/` | The ABI check (generated programs, and `check.sh`). |
| `tools/update_imgui.sh` | Imports a dear_bindings release and its Dear ImGui sources, regenerates the bindings. |
| `tools/build_imgui.sh` | Builds the library from `upstream/`. |
| `tools/fetch_imgui_libs.sh` | Downloads the prebuilt libraries matching the bindings. |
| `tools/latest_dear_bindings.sh` | Prints the latest docking release of dear_bindings. |
| `tools/fetch_wgpu_native.sh` | Downloads the wgpu-native libraries `vendor:wgpu` links, for the example. |
| `tests/` | Runtime tests, headless. |
| `examples/glfw_wgpu/` | GLFW + WebGPU, with docking and the demo window. |
| `.github/` | CI, and the workflows that build and publish the library ([GitHub Actions](#github-actions)). |

## Setup

Build the library (about 5 seconds, needs only `c++` and `ar`):

```sh
tools/build_imgui.sh                 # static and shared; or: static, shared
```

Or download the prebuilt one of the release pinned in `upstream/release.env`, built by
[GitHub Actions](#github-actions) for Linux x86_64 (glibc 2.35+) and macOS arm64 (13+):

```sh
tools/fetch_imgui_libs.sh            # this machine's platform, or e.g. linux-x86_64 macos-arm64
```

## Example

```sh
odin run examples/glfw_wgpu                                              # macOS
tools/fetch_wgpu_native.sh && odin run examples/glfw_wgpu               # Linux, needs libglfw3
```

`vendor:wgpu` needs wgpu-native in `$(odin root)/vendor/wgpu/lib/`: Odin ships it for macOS arm64,
`fetch_wgpu_native.sh` downloads it for other platforms. Esc quits, `--seconds=N` closes the window after
N seconds.

## Using the bindings

```sh
odin build . -collection:imgui=/path/to/imgui_odin
```

```odin
import im "imgui:imgui"
import "imgui:imgui/imgui_impl_glfw"
import "imgui:imgui/imgui_impl_wgpu"

im.CreateContext()
io := im.GetIO()
io.ConfigFlags += {.NavEnableKeyboard, .DockingEnable}
imgui_impl_glfw.InitForOther(window)
imgui_impl_wgpu.Init({device = device, render_target_format = surface_format})

// Each frame:
imgui_impl_wgpu.NewFrame()
imgui_impl_glfw.NewFrame()
im.NewFrame()
if im.Begin("Hello") {
	im.Text("%d fps", int(io.Framerate))
	if im.Button("Click") { clicks += 1 }
}
im.End()
im.Render()
imgui_impl_wgpu.RenderDrawData(im.GetDrawData(), render_pass)
```

Build options:

- `-define:IMGUI_SHARED=true` links the shared library. The program finds it through the rpath, which
  Odin sets to the executable's directory: copy the library there, or add one with e.g.
  `-extra-linker-flags:"-Wl,-rpath,@loader_path/../lib/macos-arm64"` (`$ORIGIN` on Linux).
- `-define:IMGUI_LIB=<path>` links another build of the library, relative to `imgui/`. It must be built
  with `upstream/imconfig_odin.h`. Set `IMGUI_SHARED` to match.

### Conventions

- Prefixes are dropped: `ImGui_Begin` is `im.Begin`, `ImGuiIO` is `im.IO`. Methods keep their type:
  `ImDrawList_AddLine(draw_list, ...)` is `im.DrawList_AddLine(draw_list, ...)`.
- `ImVec2` and `ImVec4` are `[2]f32` and `[4]f32` (`Vec2`, `Vec4`): `pos + {10, 0}`, `.x`, `.xy`.
- Default arguments are Odin default parameters: `im.Button("OK")`, `im.Button("OK", {80, 0})`. There are
  no `Ex` variants.
- Flags are bit sets: `{.NoTitleBar, .NoResize}`, `io.ConfigFlags += {.DockingEnable}`. Combinations and
  numbers inside flags are constants: `im.WindowFlags_NoDecoration`,
  `im.TableFlags_SizingFixedFit + {.RowBg}`, `im.PopupFlags_MouseButtonLeft`.
- Enums are Odin enums (`.Text`, `im.Key.Escape`), their `_COUNT` a constant (`im.Col_COUNT`). Arrays
  indexed by an enum are enumerated arrays: `style.Colors[.WindowBg] = {0, 0, 0, 1}`.
- Strings are `cstring`s, and string literals convert to them. Use `fmt.ctprintf` for formatted labels.
  Functions taking a text and its end take an Odin `string`: `im.TextUnformatted(s)`,
  `im.CalcTextSize(s)`, `im.DrawList_AddText(dl, pos, col, s)`.
- Printf-style functions take Odin format arguments: `im.Text("%v at %.1f", name, value)`. The C
  functions they wrap are `Raw<Name>`. The `va_list` variants (`TextV`...) are not bound.
- `ImVector<T>` is `im.Vector(T)`; `im.vector_slice(v)` gives its elements as a slice.
- `ImTextureID` is a `u64`. With `imgui_impl_wgpu`, a user texture's ID is its `wgpu.TextureView`:
  `im.Image({_TexID = im.TextureID(uintptr(view))}, {64, 64})`.
- Helpers: `im.CHECKVERSION()`, `im.col32(r, g, b, a)`, `im.key_chord(.S, .Mod_Ctrl)`.
- When a struct field has the name of a type, as `ConfigFlags: ConfigFlags` in `IO`, the generated file
  spells the type through a private alias (`_ConfigFlags`), since Odin does not allow it otherwise. It is
  the same type.

### Configuration

`upstream/imconfig_odin.h` configures both the library and the bindings:

- `IMGUI_DISABLE_OBSOLETE_FUNCTIONS`: no legacy API. Backends must then support
  `BackendFlags.RendererHasTextures`, as `imgui_impl_wgpu` does.
- `IMGUI_USE_WCHAR32`: `Wchar` is 32-bit, for codepoints above U+FFFF (emoji). Fonts are rendered with
  stb_truetype, so colour emoji fonts are not supported yet (that needs FreeType).

Changing it changes the ABI: rebuild the library and regenerate the bindings (`tools/update_imgui.sh`),
and publish a new release revision (see `build-imgui.yml`).

## Backends

The backends are ports of Dear ImGui's `imgui_impl_glfw.cpp` and `imgui_impl_wgpu.cpp`, with the same
procedures (`InitForOther`, `NewFrame`, `RenderDrawData`, `UpdateTexture`, `GetRenderState`...).

- `imgui_impl_glfw`: keyboard (with the translation of GLFW's untranslated keys), mouse, gamepad
  (`ConfigFlags.NavEnableGamepad`), cursors, clipboard, content scale, several contexts, chained user
  callbacks. Not yet: multi-viewports (`ConfigFlags.ViewportsEnable`), which the C++ WebGPU backend does
  not support either; docking works inside the main window.
- `imgui_impl_wgpu`: dynamic font atlas and user textures, large meshes, the standard draw callbacks
  (`PlatformIO.DrawCallback_*`). Uses only the API common to `vendor:wgpu` and `dawn_webgpu_odin`.

## Updating Dear ImGui

```sh
tools/update_imgui.sh DearBindings_v0.26_ImGui_v1.93.0-docking
```

downloads the dear_bindings release (checked against GitHub's SHA-256 digests), clones Dear ImGui at the
tag the release names, checks that they are the same Dear ImGui version, replaces `upstream/`,
regenerates the bindings, builds the library and runs the ABI check. Commit `upstream/`,
`imgui/imgui_generated.odin` and `tools/abi/`; `upstream/release.env` no longer matches until a release
is built for them. The `build-imgui.yml` workflow does all of this and the release.

## GitHub Actions

| Workflow | Runs | Does |
|---|---|---|
| `ci.yml` | On pushes to `master` and pull requests | Tests the generator and checks that the generated files are up to date, type-checks everything for Linux and macOS, lints the scripts. On Linux and macOS: builds the library, runs the ABI check and the tests, builds the example. |
| `build-imgui.yml` | By hand (Actions > Build Dear ImGui > Run workflow), with a dear_bindings release tag (empty for the latest) | Builds the library static and shared on Linux (Ubuntu 22.04) and macOS, regenerates the bindings, runs the ABI check and the tests against the libraries, builds the example. With `publish`: creates the release `imgui-<imgui tag>-db<dear_bindings version>`, and opens a pull request that commits the sources, the bindings and `upstream/release.env`. |
| `update-imgui.yml` | Mondays, or by hand | Runs `build-imgui.yml` when dear_bindings has a newer docking release than the pinned one, unless its release exists already. |

The release holds the libraries; the pull request commits the matching bindings, so merging it is what
updates the repo. One-time setup: enable Settings > Actions > General > "Allow GitHub Actions to create and
approve pull requests". Pull requests opened by Actions don't trigger CI: close and reopen them to run it.

## Tests

```sh
odin test tools/gen      # the generator, and that the generated files match upstream/
tools/abi/check.sh       # the bindings' layout against the C headers (needs the library)
odin test tests          # Dear ImGui through the bindings, headless (needs the library)
```

## License

MIT, see `LICENSE`. Dear ImGui and dear_bindings, in `upstream/`, are MIT licensed too:
`upstream/imgui/LICENSE.txt` and `upstream/dear_bindings/LICENSE.txt`.
