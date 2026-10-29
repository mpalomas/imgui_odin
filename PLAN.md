# imgui_odin — plan

Odin bindings for Dear ImGui (docking branch), generated from the C API of
[dear_bindings](https://github.com/dearimgui/dear_bindings), with the GLFW and WebGPU backends rewritten
in Odin. Modelled on `dawn_webgpu_odin`: same kind of generator, scripts, release pinning and GitHub
Actions.

Starting point: dear_bindings release
[`DearBindings_v0.26_ImGui_v1.93.0-docking`](https://github.com/dearimgui/dear_bindings/releases/tag/DearBindings_v0.26_ImGui_v1.93.0-docking)
(2026-10-18), Dear ImGui tag `v1.93.0-docking` (`IMGUI_VERSION_NUM 19300`).

## Status (2026-10-29)

Phases 0–7 are implemented; Phase 8 is open. Verified on macOS arm64: library build (no C++ runtime
dependency), generator tests (10), ABI check (1,421 sizes, offsets and enum values), runtime tests (6,
static and shared), example run and visually checked. Linux was type-checked only: its first build and
test run will be CI's.

Deviations from the plan below:

- The repository layout keeps the backends under `imgui/` (`imgui/imgui_impl_glfw`,
  `imgui/imgui_impl_wgpu`), so one collection serves all three packages.
- The generator also emits the ABI check programs (`tools/abi/`), instead of a separate tool.
- Struct fields named like a type (`ConfigFlags: ConfigFlags`) do not compile in Odin: the generator
  spells those types through private aliases (`_ConfigFlags`).
- Flags that hold numbers (`PopupFlags_MouseButton*`, `TableFlags_Sizing*`, `DrawFlags_Stroke*`) are
  detected from their `k<<S` value expressions, not from a hand-written table.
- Dear ImGui 1.93 with `IMGUI_DISABLE_OBSOLETE_FUNCTIONS` has no pre-1.92 texture path
  (`GetTexDataAsRGBA32`): renderers must support `RendererHasTextures`.
- `imgui_impl_glfw` does not keep `PlatformIO.Monitors` up to date, which only multi-viewports use.
- `imgui_impl_wgpu` has no SPIR-V fallback (only for the WGVK backend) and caches image bind groups in an
  Odin map, per frame, as the C++ does with an ImGuiStorage.
- `tools/fetch_wgpu_native.sh` was added, for `vendor:wgpu` on Linux and CI.

## Scope

In:

- The core ImGui C++ sources (`imgui.cpp`, `imgui_draw.cpp`, `imgui_tables.cpp`, `imgui_widgets.cpp`,
  `imgui_demo.cpp`) + dear_bindings' `dcimgui.cpp`, compiled into one library, static and shared, for
  Linux x86_64 and macOS arm64.
- An Odin generator, written in Odin, producing the `imgui` package from dear_bindings' output.
- `imgui_impl_glfw` and `imgui_impl_wgpu` ported to Odin, on `vendor:glfw` and `vendor:wgpu`.
- One example, `examples/glfw_wgpu`.
- Scripts to import a dear_bindings release, build the library, fetch prebuilt libraries; GitHub Actions
  for CI, building and publishing releases, opening pull requests.

Out, for now: the C++ backends (none are compiled), `imgui_internal.h` (the `dcimgui_internal.*` files),
Windows, multi-viewports (see [Phase 8](#phase-8--later)), the Dawn bindings (the wgpu backend is written
so that switching is easy), an Odin port of `imgui_demo.cpp`.

No Python anywhere: the release files are enough. dear_bindings' Python generator is never run; the
generator, the ABI check and all tooling are Odin + bash + curl (+ `gh` when available, as in
`dawn_webgpu_odin`).

## What the dear_bindings release gives us (verified)

- `dcimgui.h` (C API, 504 KB), `dcimgui.cpp` (C → C++ glue), `dcimgui.json` (3.2 MB, the same API as
  structured metadata). Also `_nodefaultargfunctions` variants, `_internal` variants, and `dcimgui_impl_*`
  for every C++ backend (not used).
- **Not** the ImGui sources: `dcimgui.cpp` includes `imgui.h` and `imgui_internal.h`, so we fetch
  `ocornut/imgui` at the tag named in the release (`v1.93.0-docking`).
- `dcimgui.json`: 36 defines, 44 enums, 66 typedefs, 77 structs (2 unions, 26 `ImVector_*`), 802
  functions. Every type comes as a parsed tree (`Builtin` / `User` / `Pointer` / `Array` / `Function`),
  with `default_value`s, comments, `is_flags_enum`, bitfield `width`s, `is_instance_pointer`, and the
  `#if` `conditionals` each item sits under.
- The `_nodefaultargfunctions` variant has 693 functions instead of 802: no `FooEx` + reduced `Foo` pairs,
  each function keeps its C++ name and all its arguments, with their `default_value`s (227 functions).

## Key decisions (with recommendations)

1. **Generate from `dcimgui_nodefaultargfunctions.json`, not by parsing the header.** The JSON is the
   input dear_bindings documents for binding generators, and already has the types parsed, default
   values, comments and conditionals. A header parser like Dawn's would have to handle unions,
   bitfields, function pointers, arrays sized by enums and `#if` nesting, for no gain. The generator
   stays an Odin program in `tools/gen/` with tests, on `core:encoding/json`. Compile the matching
   `dcimgui_nodefaultargfunctions.cpp`, so the C symbols are the original names (`ImGui_Button(label,
   size)`) and Odin default parameters replace the `Ex` variants: `im.Button("OK")`, `im.Button("OK",
   {80, 0})`.
   - We still commit `dcimgui*.h` (readable reference, and checked for consistency with the JSON).
2. **Commit the ImGui core sources** (`upstream/imgui/`, ~2.4 MB) instead of fetching them at build
   time. ImGui is small and builds in seconds with only a C++ compiler, so anyone can build the library
   without network or prebuilt binaries; and CI can build it on every push (Dawn's CI could only
   type-check). Prebuilt releases remain, for users without a C++ toolchain and for the pinned,
   checksummed setup `dawn_webgpu_odin` has.
3. **One ImGui configuration, in one file:** `upstream/imconfig_odin.h`, passed to every compile with
   `-DIMGUI_USER_CONFIG`, and read by the generator to evaluate the JSON's `conditionals`. The build and
   the bindings cannot disagree on the ABI. Content:
   - `IMGUI_DISABLE_OBSOLETE_FUNCTIONS` (drops 87 legacy items; new project, no legacy users).
   - `IMGUI_USE_WCHAR32`: `ImWchar` is 32-bit, for codepoints above U+FFFF (emoji). Colour emoji also
     need the FreeType font loader (see [Phase 8](#phase-8--later)); stb_truetype renders them in
     monochrome at best.
   - Defaults kept: `ImDrawIdx` 16-bit, `ImTextureID` = `ImU64`.
   - Changing this file changes the ABI: it is part of the release's identity (see release naming).
4. **Odin API style, as in `vendor:wgpu` and `dawn_webgpu_odin`:** prefixes dropped, bit sets for flags,
   `[2]f32` for `ImVec2`. Details in [Phase 3](#phase-3--the-generator-toolsgen). The generated layer is 1:1 with
   C; a small hand-written `imgui.odin` adds Odin-friendly wrappers (strings, format functions), with the
   wrapped C functions kept as `Raw<Name>` (Dawn's `RAW_FUNCTIONS` pattern).
5. **Backends import `vendor:glfw` and `vendor:wgpu` directly**, written against the API subset shared
   with `dawn_webgpu_odin` (the one `compare_vendor_wgpu.py` checks), so switching to Dawn later is an
   import change (or the `gpu:` collection trick). No `_INIT` constants, no `InstanceWaitAny`.
6. **Example uses the C++ demo** (`ImGui_ShowDemoWindow`, compiled in from `imgui_demo.cpp`) plus Odin
   windows. Porting the 11,900-line demo to Odin is a large, mechanical job that mostly tests the
   bindings; worth it later as a test bed, not as a first deliverable.

## Repository layout

| Path | |
|---|---|
| `imgui/` | Package `imgui`: `imgui_generated.odin` (generated), `imgui.odin` (library selection, wrappers, helpers). |
| `imgui/imgui_impl_glfw/` | Package `imgui_impl_glfw`, Odin port of `backends/imgui_impl_glfw.cpp`. |
| `imgui/imgui_impl_wgpu/` | Package `imgui_impl_wgpu`, Odin port of `backends/imgui_impl_wgpu.cpp`. |
| `upstream/imgui/` | ImGui core sources at the pinned tag: `imgui*.{h,cpp}`, `imstb_*.h`, `imconfig.h`, `LICENSE.txt`. Committed. |
| `upstream/dear_bindings/` | `dcimgui_nodefaultargfunctions.{h,cpp,json}`, `dcimgui.h` (reference), `LICENSE.txt`. Committed. |
| `upstream/imconfig_odin.h` | The ImGui build configuration (decision 3). |
| `upstream/version.env` | `DEAR_BINDINGS_TAG`, `DEAR_BINDINGS_VERSION`, `IMGUI_TAG`, `IMGUI_COMMIT`, `IMGUI_VERSION_NUM`. Written by `update_imgui.sh`. |
| `upstream/release.env` | The release whose libraries match the bindings. Written by `build-imgui.yml`. |
| `lib/<os>-<arch>/` | `libdcimgui.a`, `libdcimgui.{dylib,so}`. Not committed. |
| `tools/gen/` | The generator, with tests. |
| `tools/abi/` | ABI check: a generated C file and Odin file printing `sizeof`/`offsetof`. |
| `tools/update_imgui.sh` | Imports a dear_bindings release + the matching ImGui sources, regenerates, checks. |
| `tools/build_imgui.sh` | Builds the library (static, shared or both) from `upstream/`. |
| `tools/fetch_imgui_libs.sh` | Downloads the prebuilt libraries pinned in `upstream/release.env`. |
| `tools/latest_dear_bindings.sh` | Prints the latest docking release of dear_bindings (`--env` for CI). |
| `examples/glfw_wgpu/` | The example. |
| `tests/` | Headless runtime tests against the real library. |
| `.github/` | `ci.yml`, `build-imgui.yml`, `update-imgui.yml`, `actions/setup-odin` (copied from Dawn). |

Usage, as in Dawn: `odin build . -collection:imgui=/path/to/imgui_odin`, then
`import im "imgui:imgui"`, `import "imgui:imgui/imgui_impl_glfw"`, `import "imgui:imgui/imgui_impl_wgpu"`.
The examples import with relative paths, so they build without flags.

## Phase 0 — Repository bootstrap

- `git init`, `master` branch, `.gitignore` (`lib/**/*.{a,so,dylib}`, `*.bin`, build dirs), MIT
  `LICENSE` (ImGui and dear_bindings are MIT too; keep their licence files next to their sources).
- Copy `.github/actions/setup-odin` from `dawn_webgpu_odin` unchanged.
- README skeleton (filled as phases land), in the style of Dawn's: Layout, Setup, Using, Conventions,
  Backends, GitHub Actions, Tests.

## Phase 1 — Import the sources: `tools/update_imgui.sh`

`tools/update_imgui.sh [DEAR_BINDINGS_TAG]` (default: the tag in `upstream/version.env`):

1. Download the release's files (`gh release download` if logged in, else curl from
   `github.com/dearimgui/dear_bindings/releases/download/<tag>/`), and check them against the SHA-256
   digests the GitHub API returns for release assets.
2. Derive the ImGui tag from the release tag (`DearBindings_v0.26_ImGui_v1.93.0-docking` →
   `v1.93.0-docking`) and download `ocornut/imgui` at that tag (tarball, resolved to its commit).
3. Check consistency: `IMGUI_VERSION_NUM` in `imgui.h` equals the one in `dcimgui.h`; the JSON's
   `IMGUI_VERSION` define matches. Refuse otherwise.
4. Replace `upstream/imgui/` and `upstream/dear_bindings/`, write `upstream/version.env`.
5. Run the generator, `odin check imgui -no-entry-point`, and, if a C++ compiler is present,
   `tools/build_imgui.sh` + the ABI check.

Acceptance: running it twice is a no-op in `git status`; a wrong or unknown tag fails with a clear error.

## Phase 2 — Build the library: `tools/build_imgui.sh`

`tools/build_imgui.sh [static|shared|all]` (default `all`), output to `lib/<os>-<arch>/`:

- Sources: `upstream/imgui/imgui{,_draw,_tables,_widgets,_demo}.cpp`,
  `upstream/dear_bindings/dcimgui_nodefaultargfunctions.cpp`. Unity build or one object each (parallel
  `c++` jobs); no CMake, no Ninja: plain `c++` + `ar`.
- Flags: `-std=c++11 -O2 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fvisibility=hidden -fPIC`,
  `-DIMGUI_USER_CONFIG='"imconfig_odin.h"'`, `-DCIMGUI_API='extern "C" __attribute__((visibility("default")))'`
  for the shared library. `CC`/`CXX`, `CXXFLAGS`, `MACOSX_DEPLOYMENT_TARGET` from the environment.
- Shared: `libdcimgui.dylib` with `-install_name @rpath/libdcimgui.dylib`; `libdcimgui.so` with
  `-Wl,-soname,libdcimgui.so`.
- Goal: no C++ runtime dependency. With no exceptions, RTTI or thread-safe statics, ImGui should only
  need libc (it allocates through `IM_ALLOC`/`malloc`). The script checks with `nm -u` and reports C++
  runtime symbols; if none remain, the Odin side links no `libc++`/`libstdc++` at all (simpler
  distribution than Dawn, no `STATIC_CXX` option needed). If some remain, link `system:c++` /
  `system:stdc++` as Dawn does.
- Takes ~10–20 s. Library size budget: measure; `-ffunction-sections -fdata-sections` so
  `-dead_strip` / `--gc-sections` can drop the unused API.

## Phase 3 — The generator: `tools/gen/`

`odin run tools/gen -- <dcimgui.json> <imconfig_odin.h> <imgui_generated.odin>`. Same structure as
Dawn's: `main.odin`, `model.odin` (JSON → IR, replacing `lexer.odin`/`parser.odin`), `emit.odin`,
`gen_test.odin`. Strict: an unknown type kind, default value expression or conditional is an error,
never silently skipped.

### Conditionals

Each item's `conditionals` are evaluated against the defines of `imconfig_odin.h` plus a fixed table:
`DEAR_BINDINGS_INTERNAL_GLUE_CODE` undefined, `_MSC_VER` undefined, the clang/GCC version test true,
`IMGUI_HAS_IMSTR` false. Unknown expressions fail.

### Type mapping

| C | Odin |
|---|---|
| `ImVec2`, `ImVec4` | `Vec2 :: [2]f32`, `Vec4 :: [4]f32` (same layout; arithmetic and swizzles for free) |
| `ImVec2i`, `ImTextureRect`... | structs, prefix dropped |
| `ImU32`, `ImS16`, `ImWchar`, `ImGuiID`... | `u32`, `i16`, `Wchar :: u16`, `ID :: u32`... (typedefs kept as aliases) |
| `int`, `unsigned int`, `bool`, `char`, `float`, `double`, `long long` | `c.int`, `c.uint`, `bool`, `u8`, `f32`, `f64`, `c.longlong` |
| `const char*` | `cstring` |
| `T*` | `^T`; `[^]T` when the field/param is a pointer + count/size pair, or a known array (`const float* values` + `values_count`) |
| `void*` | `rawptr` |
| `T name[N]`, `T name[ImGuiCol_COUNT]` | `[N]T`, `[Col.COUNT]Vec4` |
| `ImVector_T` | one generic `Vector :: struct($T: typeid) {Size, Capacity: c.int, Data: [^]T}` + `Vector(DrawCmd)` |
| bitfields (`ImFontGlyph`, `ImFontBaked`) | `bit_field u32 {...}` |
| unions | `struct #raw_union` |
| function pointer typedefs/fields | `proc "c" (...)` |
| `va_list` functions (`TextV`...) | skipped (unusable from Odin) |
| C varargs (`Text(fmt, ...)`) | `#c_vararg` raw procs, wrapped (see below) |

### Names

- `ImGui_Begin` → `Begin`; struct methods keep their type: `ImDrawList_AddLine` → `DrawList_AddLine`,
  `ImGuiIO_AddKeyEvent` → `IO_AddKeyEvent`, with `self: ^DrawList` first.
- Types: `ImGuiIO` → `IO`, `ImDrawList` → `DrawList`, `ImFontAtlas` → `FontAtlas`... Collisions
  (`ImGuiStyle`/`Style`...) are checked by the generator; a collision is an error with a rename table.
- Keyword escapes and digit-leading members (`._1`) as in Dawn.
- Each item's comments (`preceding`, `attached`) are copied, so the ImGui documentation is in the Odin file.

### Enums and flags

- Plain enums (`ImGuiCol_`, `ImGuiKey`, `ImGuiDir`, `ImGuiDataType_`, ...) → `Col :: enum c.int {...}`;
  `_COUNT` kept as a member, for arrays and loops. `ImGuiKey` keeps its `ImGuiMod_*` values (key chords).
- Flags enums (`is_flags_enum`, 30 of them) → `WindowFlag :: enum c.int` with the single-bit members,
  and `WindowFlags :: bit_set[WindowFlag; c.int]`, so `{.NoTitleBar, .NoResize}`. Members of value 0 are
  dropped (`{}`). Multi-bit values (`NoDecoration`, `Borders`, `RoundCornersAll`, the `*Mask_`s...) →
  constants of the bit set: `WindowFlags_NoDecoration :: WindowFlags{...}`.
- Exceptions table for flag enums that aren't really bit sets, e.g. `ImGuiPopupFlags_MouseButton*`
  (the low bits are a mouse button number) and the 2-bit enumerations inside `ImGuiTableFlags_Sizing*`:
  they become constants too, since a `bit_set` cannot hold a number. To review once on the real data.

### Default arguments

The 227 functions with defaults get Odin default values, translated from the 30 distinct expressions in
the JSON: `NULL` → `nil`, `0` → `0` or `{}` (flags), `ImVec2(0, 0)` → `{0, 0}`, `FLT_MAX` → `max(f32)`,
`-FLT_MIN` → a literal, `sizeof(float)` → `size_of(f32)`, `"%.3f"` → `"%.3f"`, `IM_COL32_WHITE` → the
constant. Unknown expressions fail.

### Defines

`IMGUI_VERSION`, `IMGUI_VERSION_NUM`, `IM_COL32_*`, `IM_DRAWLIST_TEX_LINES_WIDTH_MAX`,
`ImDrawCallback_ResetRenderState` (`(ImDrawCallback)(-8)`)... become constants; the generator also emits
`DEAR_BINDINGS_VERSION` and checks the library's at startup (`DearBindings_GetVersionNumber` +
`ImGui_DebugCheckVersionAndDataLayout`, wrapped as `im.CheckVersion()`).

### Hand-written layer (`imgui/imgui.odin`)

- Library selection, copied from Dawn's `wgpu.odin`: `IMGUI_SHARED`, `IMGUI_LIB` (`#config`), the
  `#exists` check with a message pointing to `fetch_imgui_libs.sh` / `build_imgui.sh`.
- String wrappers, generated by rule, not by hand: every `(const char* text, const char* text_end)` pair
  becomes one `string` param (`TextUnformatted(text: string)`, `DrawList_AddText`, `CalcTextSize`).
- Format functions take Odin formatting: `Text :: proc(format: string, args: ..any)` formats with
  `fmt.tprintf` and calls `TextUnformatted`. Same for `TextColored`, `TextDisabled`, `TextWrapped`,
  `LabelText`, `BulletText`, `SetTooltip`, `SetItemTooltip`, `TreeNode*` with format, `LogText`. The C
  ones are `RawText`...
- Small helpers: `IM_COL32` → `col32(r, g, b, a)`, `vector_slice(v) -> []T`, a `cstring` temp helper.

### Tests (`odin test tools/gen`)

As in Dawn: JSON snippets → expected Odin output for each mapping rule, error cases, and a test that
regenerates from the committed JSON and compares with the committed `imgui_generated.odin`.

## Phase 4 — ABI check and runtime tests

The risk with 77 structs, bitfields and enum-sized arrays is a silent layout mismatch. So:

- `tools/abi/`: the generator also emits `abi_check.c` (compiled with `imconfig_odin.h`, prints
  `sizeof`/`offsetof` of every struct and field, and every enum value) and `abi_check.odin` (prints the
  same with `size_of`/`offset_of`). CI diffs the two outputs, on both platforms.
- `tests/`: `odin test tests` against the real library, headless (no window, no GPU): create a context,
  set `DisplaySize`, build the font atlas, run a few frames with windows, tables and widgets, check
  `GetDrawData()` (command lists, vertex counts), exercise `Vector`, string wrappers, flags, default
  arguments, `ImTextureData` requests. This runs on the CI runners, which have no GPU.

## Phase 5 — The backends in Odin

### `imgui_impl_glfw` (port of `imgui_impl_glfw.cpp`, 1,734 lines; GLFW 3.4, as `vendor:glfw`)

API: `Init(window, install_callbacks := true) -> bool`, `Shutdown()`, `NewFrame()`, plus the callbacks
for users that install their own (`WindowFocusCallback`, `CursorPosCallback`, `MouseButtonCallback`,
`ScrollCallback`, `KeyCallback`, `CharCallback`, `MonitorCallback`...), `RestoreCallbacks`,
`SetCallbacksChainForAllWindows`, `GetContentScaleForWindow`.

- Backend data in `io.BackendPlatformUserData`, as the C++ (multiple contexts work).
- Callbacks are `proc "c"`, chaining to the previously installed ones, restoring the Odin `context` from
  one stored in the backend data.
- Key translation (GLFW keys → `ImGuiKey`, with the keyboard-layout fix via `glfw.GetKeyName`), modifiers,
  mouse buttons/wheel/position/source, focus, cursor enter/leave, chars, gamepad (`glfw.GetGamepadState`),
  mouse cursors (`glfw.CreateStandardCursor`, 3.4 resize cursors), clipboard through
  `PlatformIO.Platform_{Get,Set}ClipboardTextFn`, `Platform_OpenInShellFn`, DPI: framebuffer scale and
  content scale (`io.DisplayFramebufferScale`, the 1.92+ `ConfigDpiScaleFonts`/`FontScaleDpi` path).
- Dropped: Emscripten paths, Win32-specific hacks (no Windows yet). X11/Wayland differences kept where
  GLFW 3.4 exposes them (`glfw.GetPlatform`).
- Multi-viewport code (`ImGuiPlatformIO.Platform_CreateWindow`...) left out for now: the C++ WebGPU
  backend has no `RendererHasViewports` support either, so it would have no renderer to pair with.
  Docking itself works inside the main window without it.

### `imgui_impl_wgpu` (port of `imgui_impl_wgpu.cpp`, 1,154 lines)

API: `Init(info: InitInfo) -> bool` (device, render target format, depth format, frames in flight,
pipeline multisample state), `Shutdown()`, `NewFrame()`, `RenderDrawData(draw_data, pass_encoder)`,
`CreateDeviceObjects`, `InvalidateDeviceObjects`, `UpdateTexture(tex: ^TextureData)`.

- WGSL shaders (from the C++ source), pipeline, uniform buffer, sampler, per-frame vertex/index buffers
  growing as needed, `ImDrawIdx` 16/32-bit handled by `size_of(DrawIdx)`.
- `RendererHasTextures`: create/update/destroy `wgpu.Texture`s from `platform_io.Textures`
  (`WantCreate`, `WantUpdates` with sub-rect uploads, `WantDestroy`), bind group per texture, cached by
  `TextureID`.
- `RendererHasVtxOffset`, user callbacks, `ImDrawCallback_ResetRenderState`, and the render state exposed
  in `platform_io.Renderer_RenderState` like the C++.
- Written against the wgpu subset common to `vendor:wgpu` and `dawn_webgpu_odin` (decision 5).

## Phase 6 — The example: `examples/glfw_wgpu/`

Port of `examples/example_glfw_wgpu/main.cpp` (573 lines): GLFW window, `vendor:wgpu` instance, adapter,
device (callbacks + `InstanceProcessEvents`, as Dawn's `examples/shared`), surface through
`vendor:wgpu/glfwglue`, reconfigure on resize, `ConfigFlags {.NavEnableKeyboard, .DockingEnable}`,
`DockSpaceOverViewport`, the C++ demo window, a "Hello" window and a small Odin-only window using tables,
plots, a texture, colours, and `--seconds=N` to quit (for smoke runs, as Dawn's examples).

```sh
tools/fetch_imgui_libs.sh     # or tools/build_imgui.sh
odin run examples/glfw_wgpu -extra-linker-flags:"-Wl,-dead_strip"
```

`vendor:wgpu` needs wgpu-native in `$(odin root)/vendor/wgpu/lib/` (macOS has it in this Odin install;
Linux needs a download, which CI does: `tools/fetch_wgpu_native.sh`, matching `BINDINGS_VERSION` 29.0.1.1).

## Phase 7 — Scripts and GitHub Actions

### `tools/fetch_imgui_libs.sh [PLATFORM...]`

Same as `fetch_dawn_libs.sh`: reads `RELEASE_TAG` in `upstream/release.env`, downloads
`dcimgui-<platform>.tar.gz` + the release's `dcimgui_nodefaultargfunctions.h` + `SHA256SUMS`, checks the
checksums and that the header matches the committed one (else: the bindings were regenerated since, build
or wait for the release), extracts to `lib/<platform>/`.

### Release naming

`imgui-v1.93.0-docking-db0.26`. If `imconfig_odin.h` or the build flags change for the same versions, a
`-r2` suffix (the build workflow takes an optional revision input).

### Workflows

| Workflow | Runs | Does |
|---|---|---|
| `ci.yml` | Pushes to `master`, pull requests | Generator tests (incl. generated file up to date), `shellcheck`, and on Linux + macOS: build the library from `upstream/`, ABI check, `odin test tests`, build the example (not run: no GPU). Type-check for the other target too. A few minutes per job, since ImGui builds fast. |
| `build-imgui.yml` | By hand (dear_bindings tag, `publish`), or called | `update_imgui.sh <tag>`, build static + shared per platform (Linux x86_64 on Ubuntu 22.04 for an older glibc, macOS arm64 with `MACOSX_DEPLOYMENT_TARGET=13.0`), ABI check, tests, examples. Check that both platforms generate the same Odin file. With `publish`: create the release with the archives, the header and `SHA256SUMS`, then open a pull request committing `upstream/`, the generated file and `release.env`. |
| `update-imgui.yml` | Mondays, or by hand | `latest_dear_bindings.sh --env`: latest release whose tag ends in `-docking`. If it differs from `upstream/version.env` and its release doesn't exist yet, call `build-imgui.yml` with `publish`. |

Copied from Dawn: pinned action SHAs, `persist-credentials: false` except in the publish job,
concurrency groups, the "Allow GitHub Actions to create and approve pull requests" requirement and the
"close and reopen to run CI" note.

Optional, cheap here: `linux-arm64` on `ubuntu-24.04-arm` runners (free on public repos).

## Order of work and milestones

1. Bootstrap + `update_imgui.sh` + `build_imgui.sh` → `lib/macos-arm64/libdcimgui.a` builds locally.
2. Generator, enough for `odin check imgui` → then the ABI check passes → then the headless tests pass.
   This is the biggest chunk; most of the real-data surprises (name collisions, flag enums, defaults)
   land here.
3. Hand-written wrappers (strings, format functions).
4. `imgui_impl_glfw`, then `imgui_impl_wgpu`, then the example, run on macOS (and Linux if you have a
   machine with a GPU).
5. `ci.yml`, then `build-imgui.yml` (tested with `publish: false` first), `fetch_imgui_libs.sh`, then
   `update-imgui.yml`.
6. README.

## Phase 8 — Later

- Colour emoji: compile `misc/freetype/imgui_freetype.cpp` with `IMGUI_ENABLE_FREETYPE` (and
  `IMGUI_ENABLE_FREETYPE_PLUTOSVG` for SVG emoji fonts) and pass `ImGuiFreeTypeLoaderFlags_LoadColor`.
  Adds a FreeType dependency (static in the release archives, to keep `fetch_imgui_libs.sh` enough).
- Multi-viewports: GLFW platform side (`Platform_CreateWindow`...) and adding `RendererHasViewports` to
  the Odin wgpu backend (one surface per viewport). Beyond what the C++ wgpu backend does.
- `imgui_internal.h` bindings (`dcimgui_internal.json`), mostly for the `DockBuilder*` API that docking
  layouts need. Same generator, second output file.
- Switch the wgpu backend to `dawn_webgpu_odin` (collection, or import swap).
- Odin port of `imgui_demo.cpp`, as the definitive bindings test.
- Windows (MSVC build, `.lib`), more backends (SDL3 via `vendor:sdl3`).

## Risks

- **Flag enums as bit sets:** a few ImGui flag enums hold numbers in bit ranges; covered by the
  exceptions table, and by the ABI check of enum values.
- **Odin nightly on macOS:** Dawn's `setup-odin` notes `dev-2026-10` crashing on Objective-C, which
  `vendor:wgpu/glfwglue` uses on macOS. Check the local `dev-2026-10:c6e2f0ba9` early, pin a release in CI
  if needed.
- **vendor:wgpu vs WebGPU changes:** the C++ backend tracks Dawn's latest `webgpu.h`; `vendor:wgpu` is
  wgpu-native 29. Where they differ, follow `vendor:wgpu`.
- **dear_bindings release cadence:** releases may lag ImGui tags; `update-imgui.yml` follows
  dear_bindings, not ImGui.

## Decided

1. `IMGUI_USE_WCHAR32` on (emoji).
2. `IMGUI_DISABLE_OBSOLETE_FUNCTIONS` on.
3. Methods are named `DrawList_AddLine(dl, ...)`.
4. Repository `mpalomas/imgui_odin`, public: `fetch_imgui_libs.sh` works with plain curl, `gh` optional.
