#Requires -Version 7.4
<#
Prints the latest dear_bindings release for the Dear ImGui docking branch. The PowerShell version of
tools/latest_dear_bindings.sh.

Usage: tools/latest_dear_bindings.ps1 [-Env]
  -Env  Print KEY=VALUE lines for CI: DEAR_BINDINGS_TAG, DEAR_BINDINGS_VERSION, IMGUI_TAG

The releases are tagged DearBindings_v<version>_ImGui_v<imgui version>, with a -docking suffix for the
docking branch. "Latest" is the most recently published one.
Environment: GH_TOKEN  Optional, for the GitHub API (its anonymous rate limit is 60 requests an hour)
#>
param([switch]$Env)

$ErrorActionPreference = 'Stop'

$headers = @{ Accept = 'application/vnd.github+json' }
if ($env:GH_TOKEN) { $headers.Authorization = "Bearer $env:GH_TOKEN" }
try {
    $releases = Invoke-RestMethod -MaximumRetryCount 3 -Headers $headers 'https://api.github.com/repos/dearimgui/dear_bindings/releases?per_page=50'
} catch {
    throw "cannot list the releases of dearimgui/dear_bindings: $($_.Exception.Message)"
}
$tag = $releases |
    Where-Object { -not $_.draft -and -not $_.prerelease -and $_.tag_name -match '^DearBindings_v[0-9.]+_ImGui_v.*-docking$' } |
    Sort-Object { [datetime]$_.published_at } | Select-Object -Last 1 -ExpandProperty tag_name
if (-not $tag) { throw 'no docking release found' }

if (-not $Env) {
    $tag
    exit 0
}
if ($tag -notmatch '^DearBindings_v([0-9.]+)_ImGui_(v.*)$') { throw "unexpected tag $tag" }
"DEAR_BINDINGS_TAG=$tag"
"DEAR_BINDINGS_VERSION=$($Matches[1])"
"IMGUI_TAG=$($Matches[2])"
