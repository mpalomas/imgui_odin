#Requires -Version 7.4
<#
Builds Dear ImGui and its C API (dear_bindings) from upstream/ into lib/windows-<arch>/: dcimgui.lib
(static), and dcimgui.dll with its import library dcimgui.dll.lib (shared). Windows only: Linux and macOS
use tools/build_imgui.sh.

Usage: tools/build_imgui.ps1 [static|shared|all]   (default: all)

Builds CMakeLists.txt with CMake, which finds Visual Studio itself: the newest installed by default (Visual
Studio 2026, or its Build Tools), no developer prompt needed. See CMakeLists.txt for the build.
Environment:
  CMAKE_GENERATOR  e.g. "Visual Studio 18 2026" to require that version, or Ninja (from a developer prompt)
  CXXFLAGS         Extra compiler flags
#>
param(
    [ValidateSet('static', 'shared', 'all')]
    [string]$Linkage = 'all'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Repo = Split-Path -Parent $PSScriptRoot
if (-not $IsWindows) { throw 'tools/build_imgui.ps1 builds on Windows: on Linux and macOS, run tools/build_imgui.sh' }
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { throw 'cmake is required (https://cmake.org, or Visual Studio''s "C++ CMake tools")' }

$arch, $cmakeArch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x86_64', 'x64' }
    'Arm64' { 'arm64', 'ARM64' }
    default { throw "unsupported architecture $_" }
}
$platform = "windows-$arch"
$libDir = Join-Path $Repo "lib/$platform"
$buildDir = Join-Path $Repo "build/$platform"

$configure = @(
    '-S', $Repo, '-B', $buildDir,
    "-DDCIMGUI_STATIC=$($Linkage -ne 'shared' ? 'ON' : 'OFF')",
    "-DDCIMGUI_SHARED=$($Linkage -ne 'static' ? 'ON' : 'OFF')"
)
# Visual Studio generators take the architecture as a platform and build the --config below. The others
# (Ninja) take the architecture from the developer prompt, and the configuration here.
if (-not $env:CMAKE_GENERATOR -or $env:CMAKE_GENERATOR -like 'Visual Studio*') {
    $configure += '-A', $cmakeArch
} else {
    $configure += '-DCMAKE_BUILD_TYPE=Release'
}

# A fresh build directory, so that a change of generator or options applies.
Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
cmake @configure
cmake --build $buildDir --config Release --parallel

$files = @()
if ($Linkage -ne 'shared') { $files += 'dcimgui.lib' }
if ($Linkage -ne 'static') { $files += 'dcimgui.dll', 'dcimgui.dll.lib' }
New-Item -ItemType Directory -Force $libDir | Out-Null
foreach ($f in $files) { Remove-Item -Force (Join-Path $libDir $f) -ErrorAction SilentlyContinue }
cmake --install $buildDir --config Release --prefix $libDir
foreach ($f in $files) {
    if (-not (Test-Path (Join-Path $libDir $f))) { throw "the build made no $f" }
}
Write-Host "Built in lib/$platform/:"
Get-ChildItem $libDir -Filter 'dcimgui*' | Format-Table Name, Length -AutoSize | Out-Host
