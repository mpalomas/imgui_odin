#Requires -Version 7.4
<#
Downloads the prebuilt Dear ImGui libraries that match the committed bindings into lib/<os>-<arch>/, from
the GitHub release named in upstream/release.env (written by .github/workflows/build-imgui.yml). The
PowerShell version of tools/fetch_imgui_libs.sh.

Usage: tools/fetch_imgui_libs.ps1 [PLATFORM...]
  PLATFORM  windows-x86_64, linux-x86_64 or macos-arm64 (default: this machine's)

Checks the release's dear_bindings header and imconfig_odin.h against the committed ones, and the
downloads against the release's SHA256SUMS. Uses gh when it is installed and logged in, else
Invoke-WebRequest.
Environment:
  IMGUI_RELEASE_REPO  (default: mpalomas/imgui_odin)
  IMGUI_RELEASE_URL   Base URL of the release downloads, without gh (default: the repository's releases)
#>
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Platforms
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Repo = Split-Path -Parent $PSScriptRoot
$Slug = $env:IMGUI_RELEASE_REPO ? $env:IMGUI_RELEASE_REPO : 'mpalomas/imgui_odin'
$BaseUrl = $env:IMGUI_RELEASE_URL ? $env:IMGUI_RELEASE_URL : "https://github.com/$Slug/releases/download"
$Pin = Join-Path $Repo 'upstream/release.env'
$Header = 'dcimgui_nodefaultargfunctions.h'

if (-not (Test-Path $Pin)) { throw "no ${Pin}: the committed bindings do not come from a release. Build the library with tools/build_imgui.ps1" }
$Tag = (Select-String -Path $Pin -Pattern '^RELEASE_TAG=(.+)$').Matches.Groups[1].Value
if (-not $Tag) { throw "no RELEASE_TAG in $Pin" }

if (-not $Platforms) {
    $os = $IsWindows ? 'windows' : $IsMacOS ? 'macos' : $IsLinux ? 'linux' : (throw 'unsupported OS')
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'x86_64' }
        'Arm64' { 'arm64' }
        default { throw "unsupported architecture $_" }
    }
    $Platforms = @("$os-$arch")
}

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) "imgui_libs_$PID"
New-Item -ItemType Directory -Force $Tmp | Out-Null
try {
    $files = @($Header, 'imconfig_odin.h', 'SHA256SUMS') + ($Platforms | ForEach-Object { "dcimgui-$_.tar.gz" })

    Write-Host "Downloading $($files -join ' ') from release $Tag of $Slug"
    $gh = -not $env:IMGUI_RELEASE_URL -and (Get-Command gh -ErrorAction SilentlyContinue)
    if ($gh) {
        try { gh auth status 2>&1 | Out-Null } catch { $gh = $false }
    }
    if ($gh) {
        gh release download $Tag --repo $Slug --dir $Tmp @($files | ForEach-Object { '--pattern', $_ })
    } else {
        foreach ($f in $files) {
            try {
                Invoke-WebRequest -MaximumRetryCount 3 -OutFile "$Tmp/$f" "$BaseUrl/$Tag/$f"
            } catch {
                throw "cannot download ${f}: $($_.Exception.Message)"
            }
        }
    }
    foreach ($f in $files) {
        if (-not (Test-Path "$Tmp/$f")) { throw "release $Tag has no $f" }
    }

    # "<sha256>  <file>" or "<sha256> *<file>"
    $sums = @{}
    foreach ($line in Get-Content "$Tmp/SHA256SUMS") {
        if ($line -match '^([0-9a-f]{64}) [ *](.+)$') { $sums[$Matches[2]] = $Matches[1] }
    }
    foreach ($f in $files | Where-Object { $_ -ne 'SHA256SUMS' }) {
        if (-not $sums.ContainsKey($f)) { throw "$f is not in the release's SHA256SUMS" }
        if ((Get-FileHash -Algorithm SHA256 "$Tmp/$f").Hash -ne $sums[$f].ToUpperInvariant()) { throw "checksum mismatch for $f" }
    }

    # The library must be the ImGui version and configuration the bindings were generated for. Compared
    # without the CRs that a checkout with core.autocrlf may have added.
    function Get-Text([string]$Path) { (Get-Content -Raw $Path) -replace "`r", '' }
    if ((Get-Text "$Tmp/$Header") -cne (Get-Text (Join-Path $Repo "upstream/dear_bindings/$Header"))) {
        throw "upstream/dear_bindings/$Header differs from release ${Tag}'s: the bindings were updated since. Build the library with tools/build_imgui.ps1"
    }
    if ((Get-Text "$Tmp/imconfig_odin.h") -cne (Get-Text (Join-Path $Repo 'upstream/imconfig_odin.h'))) {
        throw "upstream/imconfig_odin.h differs from release ${Tag}'s: the configuration changed since. Build the library with tools/build_imgui.ps1"
    }

    foreach ($platform in $Platforms) {
        # The archives hold lib/<platform>/<libraries>. tar is in Windows 10 and later.
        tar -xzf "$Tmp/dcimgui-$platform.tar.gz" -C $Repo
        Write-Host "Extracted to lib/${platform}/:"
        Get-ChildItem (Join-Path $Repo "lib/$platform") | Format-Table Name, Length -AutoSize | Out-Host
    }
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
