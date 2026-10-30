#Requires -Version 7.4
<#
Imports a dear_bindings release and the matching Dear ImGui sources into upstream/, and regenerates the
Odin bindings. The PowerShell version of tools/update_imgui.sh.

Usage: tools/update_imgui.ps1 [-SourcesOnly] [DEAR_BINDINGS_TAG]
  DEAR_BINDINGS_TAG  e.g. DearBindings_v0.26_ImGui_v1.93.0-docking (default: the one in
                     upstream/version.env)
  -SourcesOnly       Only import the sources: no Odin needed.

Downloads the release's dcimgui files, checked against the SHA-256 digests GitHub lists for them, and
clones ocornut/imgui at the tag the release names (ImGui_v1.93.0-docking: v1.93.0-docking). Checks that
both are the same ImGui version, replaces upstream/imgui/ and upstream/dear_bindings/, writes
upstream/version.env, then runs tools/gen and, on Windows with CMake installed, builds the library and
checks the bindings against it.
Environment:
  ODIN      (default: odin from PATH)
  GH_TOKEN  Optional, for the GitHub API (its anonymous rate limit is 60 requests an hour)
#>
param(
    [switch]$SourcesOnly,
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Repo = Split-Path -Parent $PSScriptRoot
$Odin = $env:ODIN ? $env:ODIN : 'odin'
$VersionEnv = Join-Path $Repo 'upstream/version.env'
$Slug = 'dearimgui/dear_bindings'

# The release files the bindings use. dcimgui.h is the API with the default argument helpers, kept as a
# reference to read.
$BindingFiles = @(
    'dcimgui_nodefaultargfunctions.h'
    'dcimgui_nodefaultargfunctions.cpp'
    'dcimgui_nodefaultargfunctions.json'
    'dcimgui.h'
    'LICENSE.txt'
)
# The Dear ImGui files the library is built from. No backends.
$ImguiFiles = @(
    'imgui.h', 'imgui.cpp', 'imgui_draw.cpp', 'imgui_tables.cpp', 'imgui_widgets.cpp', 'imgui_demo.cpp', 'imgui_internal.h'
    'imstb_rectpack.h', 'imstb_textedit.h', 'imstb_truetype.h', 'imconfig.h', 'LICENSE.txt'
)

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required' }

if (-not $Tag) {
    if (-not (Test-Path $VersionEnv)) { throw "no ${VersionEnv}: pass a dear_bindings release tag" }
    $Tag = (Select-String -Path $VersionEnv -Pattern '^DEAR_BINDINGS_TAG=(.+)$').Matches.Groups[1].Value
    if (-not $Tag) { throw "no DEAR_BINDINGS_TAG in $VersionEnv" }
}
# DearBindings_v0.26_ImGui_v1.93.0-docking
if ($Tag -cnotmatch '^DearBindings_v([0-9.]+)_ImGui_(v[0-9][0-9A-Za-z.-]*)$') {
    throw "'$Tag' is not a tag like DearBindings_v0.26_ImGui_v1.93.0-docking"
}
$DearBindingsVersion = $Matches[1]
$ImguiTag = $Matches[2]

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) "imgui_update_$PID"
New-Item -ItemType Directory -Force $Tmp | Out-Null
try {
    $headers = @{ Accept = 'application/vnd.github+json' }
    if ($env:GH_TOKEN) { $headers.Authorization = "Bearer $env:GH_TOKEN" }

    Write-Host "Downloading release $Tag of $Slug"
    try {
        $release = Invoke-RestMethod -MaximumRetryCount 3 -Headers $headers "https://api.github.com/repos/$Slug/releases/tags/$Tag"
    } catch {
        throw "cannot get the release $Tag of ${Slug}: $($_.Exception.Message)"
    }
    $bindingsDir = New-Item -ItemType Directory -Force "$Tmp/dear_bindings"
    foreach ($f in $BindingFiles) {
        $asset = $release.assets | Where-Object name -CEQ $f
        if (-not $asset) { throw "release $Tag has no $f" }
        Invoke-WebRequest -MaximumRetryCount 3 -OutFile "$bindingsDir/$f" $asset.browser_download_url
        if ($asset.digest -like 'sha256:*') {
            if ((Get-FileHash -Algorithm SHA256 "$bindingsDir/$f").Hash -ne $asset.digest.Substring(7).ToUpperInvariant()) {
                throw "checksum mismatch for $f"
            }
        } else {
            Write-Warning "GitHub lists no SHA-256 digest for $f"
        }
    }

    Write-Host "Cloning ocornut/imgui at $ImguiTag"
    # Its output only on failure: a shallow clone of an annotated tag warns that the tag "is not a commit".
    # With LF line endings, so that the sources are the same on every platform: ImGui's .gitattributes marks
    # them as text, which Windows checks out with CRLF by default (core.eol=native).
    $log = git -c advice.detachedHead=false -c core.autocrlf=false -c core.eol=lf clone --quiet --depth 1 --branch $ImguiTag `
        https://github.com/ocornut/imgui.git "$Tmp/imgui-src" 2>&1 | Out-String -ErrorAction SilentlyContinue
    if (-not (Test-Path "$Tmp/imgui-src/imgui.h")) {
        Write-Host $log
        throw "cannot clone ocornut/imgui at $ImguiTag"
    }
    $ImguiCommit = git -C "$Tmp/imgui-src" rev-parse HEAD
    $imguiDir = New-Item -ItemType Directory -Force "$Tmp/imgui"
    foreach ($f in $ImguiFiles) {
        if (-not (Test-Path "$Tmp/imgui-src/$f")) { throw "ImGui $ImguiTag has no $f" }
        Copy-Item "$Tmp/imgui-src/$f" $imguiDir
    }

    # `#define IMGUI_VERSION_NUM 19300` in both headers.
    function Get-VersionNum([string]$Path) {
        (Select-String -Path $Path -Pattern '^#define\s*IMGUI_VERSION_NUM\s*([0-9]+)' | Select-Object -First 1).Matches.Groups[1].Value
    }
    $ImguiVersionNum = Get-VersionNum "$imguiDir/imgui.h"
    $bindingsNum = Get-VersionNum "$bindingsDir/dcimgui_nodefaultargfunctions.h"
    if (-not $ImguiVersionNum) { throw 'no IMGUI_VERSION_NUM in imgui.h' }
    if ($ImguiVersionNum -ne $bindingsNum) {
        throw "ImGui $ImguiTag is version $ImguiVersionNum, the bindings of $Tag are for $($bindingsNum ? $bindingsNum : 'an unknown version')"
    }
    $json = Get-Content -Raw "$bindingsDir/dcimgui_nodefaultargfunctions.json" | ConvertFrom-Json
    $jsonNum = ($json.defines | Where-Object name -CEQ 'IMGUI_VERSION_NUM').content
    if ($jsonNum -ne $ImguiVersionNum) {
        throw "dcimgui_nodefaultargfunctions.json is for ImGui version $($jsonNum ? $jsonNum : 'unknown'), not $ImguiVersionNum"
    }

    $upstream = Join-Path $Repo 'upstream'
    Remove-Item -Recurse -Force "$upstream/imgui", "$upstream/dear_bindings" -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $upstream | Out-Null
    Copy-Item -Recurse $imguiDir "$upstream/imgui"
    Copy-Item -Recurse $bindingsDir "$upstream/dear_bindings"
    # LF line endings, as the other scripts write it.
    $versionText = @(
        '# The dear_bindings release and Dear ImGui sources in upstream/. Written by tools/update_imgui.sh.'
        "DEAR_BINDINGS_TAG=$Tag"
        "DEAR_BINDINGS_VERSION=$DearBindingsVersion"
        "IMGUI_TAG=$ImguiTag"
        "IMGUI_COMMIT=$ImguiCommit"
        "IMGUI_VERSION_NUM=$ImguiVersionNum"
    ) -join "`n"
    [System.IO.File]::WriteAllText($VersionEnv, "$versionText`n")
    Write-Host "Imported dear_bindings $DearBindingsVersion and ImGui $ImguiTag ($ImguiCommit)"
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

if ($SourcesOnly) { exit 0 }
Push-Location $Repo
try {
    # Relative paths with /, which the generated files name.
    & $Odin run tools/gen -out:build/gen.exe -- `
        upstream/dear_bindings/dcimgui_nodefaultargfunctions.json upstream/imconfig_odin.h `
        imgui/imgui_generated.odin tools/abi
    if ($IsWindows -and (Get-Command cmake -ErrorAction SilentlyContinue)) {
        & "$PSScriptRoot/build_imgui.ps1"
        & "$PSScriptRoot/abi/check.ps1"
    } else {
        Write-Host 'No CMake, or not on Windows: the library is not built and the ABI not checked'
    }
} finally {
    Pop-Location
}
