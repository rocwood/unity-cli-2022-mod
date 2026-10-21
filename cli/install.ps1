<#
.SYNOPSIS
    Unity CLI Installer for Windows.

.DESCRIPTION
    Downloads and installs the Unity CLI binary for Windows.
    Verifies the download with SHA-256 before installing.

.EXAMPLE
    irm https://unity.com/install.ps1 | iex

.PARAMETER Target
    Version to install. Defaults to "latest" (recommended).

.NOTES
    Environment variables:
      UNITY_CLI_HOME    - Installation directory. When set, installs to
                          <UNITY_CLI_HOME>\bin instead of the default
                          %LOCALAPPDATA%\Unity\bin. Use this when the
                          interactive user's profile is not reachable from
                          the account actually running the install (a
                          restricted service/sandbox account) -- point it
                          at a directory that account can read and write,
                          such as a path inside the current workspace.
      UNITY_CLI_CHANNEL - Release channel: alpha, beta, or empty for stable.
                          When empty and no stable release has shipped yet,
                          falls back to beta automatically.

.LINK
    https://unity.com
#>

param(
    [string]$Target = "latest",
    [ValidateSet("", "alpha", "beta")]
    [string]$Channel = $env:UNITY_CLI_CHANNEL
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Faster downloads

# When this script is piped into `irm ... | iex`, there is no script file --
# `iex` runs the text inline in the CALLER's own session, so an `exit` call in
# an error path closes that whole interactive PowerShell/pwsh window instead
# of just stopping the script (a well-known `iex` gotcha, and also hides
# whatever error message we just printed). When the script instead runs as an
# actual file (`& path\install.ps1`, `powershell -File ...`),
# $MyInvocation.MyCommand.Path is set and `exit` only stops the script,
# leaving the caller's own session alone -- and CI/automation invoking the
# file still needs a real non-zero process exit code on failure. So error
# paths below never call `exit` directly; they `throw`, which unwinds to the
# try/catch at the bottom of this script, and only that catch block calls
# `exit`, only when running as a real file.
$IsRunningAsFile = [bool]$MyInvocation.MyCommand.Path

$CdnBase   = "https://public-cdn.cloud.unity3d.com/hub/prod/cli/"
# UNITY_CLI_HOME mirrors install.sh's override (CLI-1204): when set, installs
# to <UNITY_CLI_HOME>\bin rather than the %LOCALAPPDATA%-rooted default. No
# env files are written either way -- the user-PATH registry edit below
# already covers the newly-chosen bin dir the same way it covers the default.
$InstallDir = if ($env:UNITY_CLI_HOME) {
    Join-Path $env:UNITY_CLI_HOME "bin"
} else {
    Join-Path $env:LOCALAPPDATA "Unity\bin"
}

# Channel selects the version manifest: latest.json, latest-beta.json, latest-alpha.json
$ManifestFile = switch ($Channel) {
    "alpha" { "latest-alpha.json" }
    "beta"  { "latest-beta.json" }
    default { "latest.json" }
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$platformKey = "win32-$arch"

# ─── Output helpers ───────────────────────────────────────────────────────────

function Write-Info($msg) {
    Write-Host "  " -NoNewline
    Write-Host "info" -ForegroundColor Cyan -NoNewline
    Write-Host "  $msg"
}

function Write-Warn($msg) {
    Write-Host "  " -NoNewline
    Write-Host "warn" -ForegroundColor Yellow -NoNewline
    Write-Host "  $msg"
}

function Fail($msg) {
    Write-Host "`n  " -NoNewline
    Write-Host "error" -ForegroundColor Red -NoNewline
    Write-Host " $msg`n"
    throw "UnityCliInstallFailed"
}

# ─── Fetch manifest ───────────────────────────────────────────────────────────

function Get-JsonManifest($url, $failMsg, $notFoundFallbackUrl) {
    try {
        $iwrParams = @{ Uri = $url; ErrorAction = "Stop" }
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $iwrParams["UseBasicParsing"] = $true
        }
        $response = Invoke-WebRequest @iwrParams
        return $response.Content | ConvertFrom-Json
    }
    catch {
        # A 404 specifically (not a network failure, not a 5xx) with a
        # fallback on offer means the CALLER already decided this is an
        # acceptable substitution -- see Get-Manifest below. Anything else
        # still fails outright.
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($notFoundFallbackUrl -and $statusCode -eq 404) {
            Write-Info "No stable release yet -- installing the latest beta instead."
            return Get-JsonManifest $notFoundFallbackUrl
        }
        if (-not $failMsg) { $failMsg = "Failed to fetch version manifest from $url" }
        Fail "$failMsg`n  $_"
    }
}

function Get-Manifest {
    Write-Info "Checking for latest version..."
    if ($Channel -eq "") {
        # No channel was requested. The CLI has not reached GA yet, so the
        # stable manifest may not exist (a 404, not a network problem) --
        # fall back to beta rather than failing outright. Once GA ships,
        # latest.json stops 404ing and this fallback never fires again.
        return Get-JsonManifest "${CdnBase}latest.json" $null "${CdnBase}latest-beta.json"
    }
    return Get-JsonManifest "${CdnBase}${ManifestFile}"
}

# ─── Download binary ──────────────────────────────────────────────────────────

function Get-Binary($url, $dest) {
    Write-Info "Downloading binary..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($url, $dest)
    }
    catch {
        Fail "Failed to download binary from $url`n  $_"
    }
}

# ─── SHA-256 verification ─────────────────────────────────────────────────────

function Confirm-Sha256($file, $expected) {
    Write-Info "Verifying checksum..."
    $actual = (Get-FileHash -Path $file -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        Fail "SHA-256 verification failed.`n    Expected: $expected`n    Actual:   $actual"
    }
}

# ─── PATH management ──────────────────────────────────────────────────────────

# Edit HKCU\Environment\Path through the registry directly, NOT through
# [Environment]::GetEnvironmentVariable/SetEnvironmentVariable(..., "User").
# That pair corrupts the value in two ways a PATH edit must not:
#
#   1. The getter EXPANDS variable references, so a read-modify-write freezes
#      every %VAR% entry into a literal resolved against THIS process's
#      environment. "%USERPROFILE%\.dotnet\tools" comes back as a hardcoded
#      absolute path, and an entry whose variable this process does not define
#      survives as dead literal text that nothing will ever expand again.
#   2. The setter always writes REG_SZ, downgrading the REG_EXPAND_SZ value
#      Windows creates — which is what makes the frozen entries permanent.
#
# Both are silent; the damage only surfaces later when a PATH entry stops
# resolving. Read raw, write back under the kind the value already had. The C#
# port (UnityCli.Native.WindowsUserPath) shares this contract.
#
# Returns the C# side's three-state PathOutcome, as a string: "configured" (we
# added it), "already" (a previous install did), or "manual" (we could not, and
# the caller must say so). It is deliberately NOT a bool — the caller renders a
# different closing message for each, and collapsing "manual" onto "already"
# made the script claim `unity` was ready right after warning that it wasn't.
function Add-ToUserPath($dir) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Environment")
    try {
        $current = $key.GetValue(
            "Path", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $current) {
            # No PATH stored yet — create it the way Windows does.
            $current = ""
            $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        }
        elseif ($current -isnot [string]) {
            # Only REG_SZ and REG_EXPAND_SZ read back as a string. Anything
            # else is not a PATH we know how to edit, and appending to a guess
            # would destroy it. The caller prints the manual instructions.
            return "manual"
        }
        else {
            $kind = $key.GetValueKind("Path")
        }

        $dirs = @($current -split ";" | Where-Object { $_ -ne "" })
        # Windows PATH matching is case-insensitive and a trailing slash is
        # cosmetic, so "C:\Foo", "c:\foo\" and "C:\FOO" are the same entry. Trim
        # trailing separators and compare with an ordinal case-insensitive comparer
        # (no per-entry lowercasing allocations) so we don't append a duplicate that
        # differs only by case or a trailing slash. Entries are compared BOTH raw
        # and expanded, so a hand-added "%LOCALAPPDATA%\Unity\bin" is recognized as
        # this same directory — the expansion is used for the comparison only, and
        # the raw text is what gets written back.
        $target = $dir.TrimEnd('\', '/')
        foreach ($existing in $dirs) {
            $expanded = [System.Environment]::ExpandEnvironmentVariables($existing)
            if ([string]::Equals($existing.TrimEnd('\', '/'), $target, [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals($expanded.TrimEnd('\', '/'), $target, [System.StringComparison]::OrdinalIgnoreCase)) {
                return "already"
            }
        }
        $newPath = ($dirs + $dir) -join ";"
        $key.SetValue("Path", $newPath, $kind)
    }
    finally {
        $key.Dispose()
    }
    Publish-EnvironmentChange
    return "configured"
}

# Broadcast WM_SETTINGCHANGE("Environment") so Explorer and anything launched
# from it (new Windows Terminal tabs, Start menu) pick up the PATH change
# without signing out. Already-open shells still need a restart — they only
# read the environment at startup. Best-effort: a failure must not fail the
# install.
function Publish-EnvironmentChange {
    try {
        if (-not ("UnityCli.NativeMethods" -as [type])) {
            Add-Type -Namespace UnityCli -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $HWND_BROADCAST = [IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x001A
        $SMTO_ABORTIFHUNG = 0x0002
        $result = [UIntPtr]::Zero
        [void][UnityCli.NativeMethods]::SendMessageTimeout(
            $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "Environment",
            $SMTO_ABORTIFHUNG, 2000, [ref]$result)
    }
    catch {
        # Non-fatal: the PATH is set either way; only propagation is delayed.
    }
}

# Record where the binary landed, in the app-data directory the CLI and the Hub
# already share. The user-PATH edit above lands in HKCU\Environment, and a
# process's environment block is a snapshot taken at startup; the broadcast
# reaches Explorer and its future children, but never a Hub that is ALREADY
# RUNNING. So a Hub that has just installed the CLI asks `where unity` and is
# told there is none; this file is the answer that does not depend on PATH.
#
# Mirrors src/Modules/InstallReceipt.cs byte for byte (2-space indent,
# camelCase keys, key order, trailing newline) so a receipt is the same
# document whichever transport wrote it. Best-effort: never fail an install
# over its receipt.
function Write-InstallReceipt {
    param([string]$BinaryPath, [string]$Version)
    try {
        $appData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME "AppData\Roaming" }
        $dir = Join-Path $appData "UnityHub"
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $file = Join-Path $dir "cli-install.json"
        # ConvertTo-Json would emit its own key order and escaping; the shape
        # here is pinned against the C# writer, so build it literally.
        $escape = { param($s) $s -replace '\\', '\\' -replace '"', '\"' }
        $lines = @(
            '{',
            ('  "path": "{0}",' -f (& $escape $BinaryPath)),
            ('  "version": "{0}",' -f (& $escape $Version)),
            '  "layout": "windows",',
            ('  "installedAt": "{0}"' -f `
                [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")),
            '}'
        )
        # Staged then renamed, so a Hub reading concurrently sees the old
        # receipt or the new one, never a half-written document. UTF8 without
        # a BOM: the C# reader is fed straight to a JSON parser.
        $tmp = "$file.staging.$PID"
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($tmp, ($lines -join "`n") + "`n", $utf8)
        Move-Item -Path $tmp -Destination $file -Force
    }
    catch {
        # Non-fatal: the binary is placed either way, and every consumer falls
        # back to probing.
    }
}

# ─── Main ─────────────────────────────────────────────────────────────────────
# Wrapped in try/catch so a Fail()/throw above unwinds here instead of via
# `exit` -- see $IsRunningAsFile above for why that distinction matters. The
# platform check lives inside this block for the same reason: a throw before
# the try starts is not caught by it, so it must not be the FIRST thing that
# can throw in the script.
try {

# ─── Platform check ───────────────────────────────────────────────────────────

if ([System.IntPtr]::Size -ne 8) {
    Write-Host "`n  error Windows 32-bit is not supported. Unity CLI requires a 64-bit system.`n" -ForegroundColor Red
    throw "UnityCliInstallFailed"
}

Write-Host ""
Write-Host "  Unity CLI Installer" -ForegroundColor White
Write-Host ""

# Resolve the manifest for the version we're installing. Each release publishes
# its own manifest at <version>/latest.json (always that name, regardless of
# channel) alongside the channel manifest, which only ever describes the latest
# release. So a pinned -Target goes straight to that release's manifest — the
# channel manifest would be the wrong version anyway, and skipping it avoids a
# needless request and failure point. Without a pin we resolve "latest" from the
# channel manifest. Either way filename/sha256 match the binary we download.
if ($Target -eq "latest") {
    $manifest = Get-Manifest
    $version = $manifest.version
}
else {
    $version = $Target
    Write-Info "Using requested version: $version"
    $manifest = Get-JsonManifest "${CdnBase}${version}/latest.json" `
        "Failed to fetch manifest for version '$version'. Check that it is a published version.`n`n    ${CdnBase}${version}/latest.json"
    if ($manifest.version -ne $version) {
        Fail "Version manifest mismatch: requested '$version' but manifest reports '$($manifest.version)'."
    }
}

$binaryInfo = $manifest.binaries.$platformKey

if (-not $binaryInfo) {
    $available = ($manifest.binaries | Get-Member -MemberType NoteProperty).Name -join ", "
    Fail "No binary available for platform '$platformKey'. Available: $available"
}

$filename = $binaryInfo.filename
$sha256   = $binaryInfo.sha256

Write-Info "Installing version $version for $platformKey..."

# Create install directory
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# Download to a temp path
$tmpFile = Join-Path $env:TEMP "unity-cli-install-$([System.Guid]::NewGuid().ToString('N')).exe"
$downloadUrl = "${CdnBase}${version}/$filename"

Get-Binary $downloadUrl $tmpFile

try {
    # Verify checksum
    Confirm-Sha256 $tmpFile $sha256

    # Move to install location
    $destFile = Join-Path $InstallDir "unity.exe"
    Move-Item -Path $tmpFile -Destination $destFile -Force

    # Add to user PATH
    $pathOutcome = Add-ToUserPath $InstallDir

    Write-InstallReceipt $destFile $version
}
catch {
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    throw
}

# ─── Success ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  " -NoNewline
# Parenthesized so PowerShell evaluates the cast; a bare `[char]0x2714`
# argument is passed to Write-Host as the literal string "[char]0x2714".
Write-Host ([char]0x2714) -ForegroundColor Green -NoNewline
Write-Host "  Unity CLI $version installed!" -ForegroundColor White
Write-Host ""
Write-Host "  Get started:" -ForegroundColor White
Write-Host "    unity --help           Show available commands"
Write-Host "    unity editors list     List installed Unity editors"
Write-Host "    unity install          Install a Unity editor"
Write-Host "    unity self-update      Update to the latest CLI version"
Write-Host ""
# PowerShell form: the bash `VAR=1 cmd` prefix does not parse here.
Write-Host "  AI agents: start with " -NoNewline
Write-Host '$env:UNITY_CLI_FTUE=1; unity auth status --json' -ForegroundColor Cyan
Write-Host ""

switch ($pathOutcome) {
    "configured" {
        Write-Host "  Note: Restart your terminal to use " -NoNewline
        Write-Host "unity" -ForegroundColor Cyan -NoNewline
        Write-Host "."
    }
    "manual" {
        # PATH was deliberately left alone (a value kind we will not rewrite),
        # so this must NOT claim unity is ready.
        Write-Warn "Your PATH is stored in an unexpected format, so it was left unchanged."
        Write-Host "        Add " -NoNewline
        Write-Host $InstallDir -ForegroundColor Cyan -NoNewline
        Write-Host " to your PATH, then open a new terminal."
    }
    default {
        Write-Host "  " -NoNewline
        Write-Host "unity" -ForegroundColor Cyan -NoNewline
        Write-Host " is ready. Open a new terminal and run " -NoNewline
        Write-Host "unity --help" -ForegroundColor Cyan -NoNewline
        Write-Host " to get started."
    }
}

Write-Host ""

}
catch {
    if ($_.Exception.Message -ne "UnityCliInstallFailed") {
        # A genuinely unexpected failure -- Fail()/the platform check already
        # print their own message and throw the sentinel above, so reaching
        # here with a different message means neither of those ran. Surface
        # it rather than swallowing it silently.
        Write-Host "`n  " -NoNewline
        Write-Host "error" -ForegroundColor Red -NoNewline
        Write-Host " Unexpected error: $_`n"
    }
    # Request a real process exit only when this IS a script file (see
    # $IsRunningAsFile above). Piped through `irm ... | iex`, exiting here
    # would close the caller's own interactive session instead of just
    # ending this script -- so in that case we deliberately do nothing
    # further and let the script end on its own.
    if ($IsRunningAsFile) {
        exit 1
    }
}
