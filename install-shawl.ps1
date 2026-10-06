# Windows PowerShell installation script for Komari Agent -- Shawl edition
#
# Same behaviour as install.ps1, but registers the Windows service with Shawl
# (https://github.com/mtkennerly/shawl) instead of NSSM. Shawl is a small Rust
# service wrapper that is actively maintained, while NSSM has been unmaintained
# since 2014.
#
# Usage:
#   .\install-shawl.ps1 -e "https://panel.example.com" -t "your-token"
#   .\install-shawl.ps1 --install-dir "D:\Program Files\Komari" --install-version snapshot -e ... -t ...
#   .\install-shawl.ps1 --uninstall
#
# Any argument that is not one of the --install-* options below is passed
# straight through to komari-agent.

#Requires -Version 5.1

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
function Log-Info { param([string]$Message) Write-Host "$Message" -ForegroundColor Cyan }
function Log-Success { param([string]$Message) Write-Host "$Message" -ForegroundColor Green }
function Log-Warning { param([string]$Message) Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Log-Error { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Log-Step { param([string]$Message) Write-Host "$Message" -ForegroundColor Magenta }
function Log-Config { param([string]$Message) Write-Host "- $Message" -ForegroundColor White }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
$InstallDir = Join-Path $Env:ProgramFiles "Komari"
$ServiceName = "komari-agent"
$GitHubProxy = ""
$KomariArgs = @()
$InstallVersion = ""
$InstallBinaryName = "komari-agent.exe"
$ShawlVersion = ""
$RestartDelay = 5000
$UninstallOnly = $false

# ---------------------------------------------------------------------------
# Argument parsing. Unrecognised arguments are forwarded to the agent.
# ---------------------------------------------------------------------------
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "--install-dir" { $InstallDir = $args[$i + 1]; $i++; continue }
        "--install-service-name" { $ServiceName = $args[$i + 1]; $i++; continue }
        "--install-ghproxy" { $GitHubProxy = $args[$i + 1]; $i++; continue }
        "--install-version" { $InstallVersion = $args[$i + 1]; $i++; continue }
        "--install-binary-name" { $InstallBinaryName = $args[$i + 1]; $i++; continue }
        "--install-shawl-version" { $ShawlVersion = $args[$i + 1]; $i++; continue }
        "--install-restart-delay" { $RestartDelay = $args[$i + 1]; $i++; continue }
        "--uninstall" { $UninstallOnly = $true; continue }
        Default { $KomariArgs += $args[$i] }
    }
}

# Quote a value the way the Windows C runtime command-line parser expects, so
# arguments survive command-line re-quoting boundaries (Start-Process
# -ArgumentList, powershell -File, cmd /c, ...) even when they contain spaces
# such as C:\Users\John Doe\... (komari-monitor/komari#655).
function ConvertTo-CommandLineArg {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        Log-Error "Cannot elevate a script that was not run from a file. Save it as install-shawl.ps1 and run it again as Administrator."
        exit 1
    }
    Log-Warning "Administrator privileges are required. Requesting elevation, please accept the UAC prompt..."
    $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-CommandLineArg $PSCommandPath))
    foreach ($a in $args) {
        $relaunchArgs += ConvertTo-CommandLineArg ([string]$a)
    }
    try {
        $elevated = Start-Process -FilePath $hostExe -Verb RunAs -Wait -PassThru -ArgumentList ($relaunchArgs -join ' ')
        exit $elevated.ExitCode
    }
    catch {
        Log-Error "Elevation failed or was cancelled: $_"
        Log-Error "Please run this script as Administrator."
        exit 1
    }
}

# Build a GitHub proxied URL without doubling the separator (install.ps1 ships
# with a "$proxy/$url" concatenation that yields "https://proxy//https://...").
function Join-GhProxyUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    if ($GitHubProxy -eq "") { return $Url }
    return $GitHubProxy.TrimEnd('/') + '/' + $Url
}

# Run an Invoke-WebRequest / Invoke-RestMethod against GitHub, falling back to a
# direct connection when a GitHub proxy is configured but unreachable.
# Pass -OutFile <path> to download to disk instead of returning a parsed body.
function Invoke-GitHub {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$OutFile
    )
    $urls = @(Join-GhProxyUrl $Url)
    if ($GitHubProxy -ne "") { $urls += $Url }

    for ($i = 0; $i -lt $urls.Count; $i++) {
        try {
            if ($OutFile) {
                # Assign to a local first: binding $OutFile directly would make
                # PowerShell resolve -OutFile against this function's own
                # parameter before Invoke-WebRequest ever sees the path.
                $dest = $OutFile
                Invoke-WebRequest -Uri $urls[$i] -OutFile $dest -UseBasicParsing
            }
            else {
                return Invoke-RestMethod -Uri $urls[$i] -UseBasicParsing
            }
            return $null
        }
        catch {
            if ($i -lt ($urls.Count - 1)) {
                Log-Warning "Request through GitHub proxy failed, retrying directly..."
            }
            else {
                throw $_
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Architecture detection
# ---------------------------------------------------------------------------
switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $arch = 'amd64' }
    'ARM64' { $arch = 'arm64' }
    'x86' { $arch = '386' }
    Default { Log-Error "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE"; exit 1 }
}

# Shawl publishes a native win64 build, unlike NSSM where every architecture
# shares the 32-bit binary.
$ShawlAssetArch = if ($arch -eq '386') { 'win32' } else { 'win64' }

$BinaryName = "komari-agent-windows-$arch.exe"
$AgentPath = Join-Path $InstallDir $InstallBinaryName
$ShawlExe = Join-Path $InstallDir "shawl.exe"

if ($GitHubProxy -ne "") { $ProxyDisplay = $GitHubProxy } else { $ProxyDisplay = '(direct)' }

Log-Step "Ensuring installation directory exists: $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction SilentlyContinue | Out-Null

# ---------------------------------------------------------------------------
# Uninstall helper (shared by --uninstall and the upgrade path)
# ---------------------------------------------------------------------------
function Remove-ExistingService {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Log-Info "Service $ServiceName does not exist."
        return
    }

    Log-Info "Stopping service $ServiceName..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

    # If an NSSM-based installation is being replaced, let nssm clean up its own
    # registry entries; otherwise fall back to sc.exe.
    $nssmExe = Join-Path $InstallDir "nssm.exe"
    if (Test-Path $nssmExe) {
        Log-Info "Removing legacy NSSM service registration..."
        & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null
    }

    sc.exe delete $ServiceName 2>&1 | Out-Null

    # A deleted service lingers until every handle to it is closed (ERROR 1072,
    # "marked for deletion"), which would make the subsequent create fail with
    # ERROR 1073. Wait for it to disappear.
    for ($w = 0; $w -lt 30; $w++) {
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Log-Warning "Service $ServiceName is still marked for deletion; retrying in 5s..."
        Start-Sleep -Seconds 5
    }
}

function Remove-StrayProcesses {
    # Any leftover wrapper/agent process still holding the install directory
    # would block the service from restarting cleanly.
    $names = @('shawl', 'nssm', [System.IO.Path]::GetFileNameWithoutExtension($InstallBinaryName))
    foreach ($n in $names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [System.StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object {
                Log-Warning "Terminating leftover process $($_.ProcessName) (PID $($_.Id))..."
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
    }
}

function Remove-ExistingFiles {
    if (Test-Path $AgentPath) {
        Log-Warning "Removing old binary..."
        Remove-Item $AgentPath -Force
    }
}

# ---------------------------------------------------------------------------
# Uninstall-only path
# ---------------------------------------------------------------------------
if ($UninstallOnly) {
    Log-Step "Uninstalling Komari Agent..."
    Remove-ExistingService
    Remove-StrayProcesses
    Remove-ExistingFiles
    if (Test-Path $ShawlExe) {
        Log-Warning "Removing shawl.exe..."
        Remove-Item $ShawlExe -Force -ErrorAction SilentlyContinue
    }
    Log-Success "Komari Agent has been uninstalled."
    Log-Config "Note: $($InstallDir) was left in place if it still contains other files."
    exit 0
}

# ---------------------------------------------------------------------------
# Fresh install / upgrade
# ---------------------------------------------------------------------------
Log-Step "Checking for existing service..."
Remove-ExistingService
Remove-StrayProcesses
Remove-ExistingFiles

# ---------------------------------------------------------------------------
# Resolve and fetch Shawl
# ---------------------------------------------------------------------------
function Ensure-Shawl {
    # Reuse a local copy when it is already present and runnable.
    if (Test-Path $ShawlExe) {
        try {
            $existing = & $ShawlExe --version 2>&1
            Log-Info "Found existing shawl at $ShawlExe ($existing)."
            return
        }
        catch {
            Log-Warning "Local shawl.exe failed to run, will download a fresh copy."
        }
    }

    $apiUrl = "https://api.github.com/repos/mtkennerly/shawl/releases/latest"
    if ($ShawlVersion) {
        Log-Info "Resolving requested shawl version: $ShawlVersion"
        $release = Invoke-GitHub -Url "https://api.github.com/repos/mtkennerly/shawl/releases/tags/v$ShawlVersion"
    }
    else {
        Log-Info "Fetching latest shawl release from GitHub API..."
        $release = Invoke-GitHub -Url $apiUrl
    }

    $wantedAssetName = "shawl-$($release.tag_name)-$ShawlAssetArch.zip"
    $asset = @($release.assets) | Where-Object { $_.name -eq $wantedAssetName } | Select-Object -First 1
    if (-not $asset) {
        Log-Error "Release $($release.tag_name) has no asset $wantedAssetName."
        Log-Error "Available: $(@($release.assets | ForEach-Object { $_.name }) -join ', ')"
        exit 1
    }

    $downloadUrl = Join-GhProxyUrl $asset.browser_download_url
    # The asset name already carries its own extension, so keep it verbatim
    # instead of appending another ".zip".
    $tempZip = Join-Path $env:TEMP ("shawl-{0}" -f $asset.name)
    $tempExtract = Join-Path $env:TEMP "shawl_extract_temp"

    try {
        Log-Info "Downloading $wantedAssetName..."
        Invoke-GitHub -Url $asset.browser_download_url -OutFile $tempZip

        # GitHub exposes a sha256 digest for release assets; verify when present.
        if ($asset.digest -and $asset.digest -like 'sha256:*') {
            $expected = ($asset.digest -split ':')[1].ToLower()
            $actual = (Get-FileHash -Path $tempZip -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $expected) {
                Log-Error "SHA256 mismatch for $wantedAssetName."
                Log-Error "expected: $expected"
                Log-Error "actual:   $actual"
                exit 1
            }
            Log-Success "SHA256 verified."
        }

        if (Test-Path $tempExtract) { Remove-Item -Recurse -Force $tempExtract }
        New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

        $source = Get-ChildItem -Path $tempExtract -Recurse -Filter "shawl.exe" | Select-Object -First 1
        if (-not $source) {
            Log-Error "shawl.exe not found inside the extracted archive."
            exit 1
        }

        Copy-Item -Path $source.FullName -Destination $ShawlExe -Force
        Log-Success "Installed shawl $($release.tag_name) to $ShawlExe"
    }
    finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempExtract) { Remove-Item -Recurse -Force $tempExtract -ErrorAction SilentlyContinue }
    }
}

Log-Step "Preparing Shawl service wrapper..."
Ensure-Shawl

# Never continue with a missing wrapper: every later step depends on it, and
# the resulting "command not found" errors are far less obvious than this one.
if (-not (Test-Path $ShawlExe)) {
    Log-Error "shawl.exe is missing at $ShawlExe; aborting before anything is registered."
    exit 1
}

$shawlVersionOutput = & $ShawlExe --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Log-Error "shawl.exe at $ShawlExe failed to run (exit code $LASTEXITCODE)."
    exit 1
}
Log-Info "Using shawl: $shawlVersionOutput"

# ---------------------------------------------------------------------------
# Resolve the agent version to install
# ---------------------------------------------------------------------------
function Get-LatestSnapshotVersion {
    param([Parameter(Mandatory = $true)][string]$AssetName)

    $releases = Invoke-GitHub -Url "https://api.github.com/repos/VMCoud/komari-agent/releases?per_page=100"
    if (-not $releases) { throw "No snapshot release contains asset $AssetName." }

    $latestSnapshot = $releases |
        Where-Object {
            $_.draft -eq $false -and
            $_.prerelease -eq $true -and
            $_.tag_name -like "Snapshot-*" -and
            (@($_.assets.name) -contains $AssetName)
        } |
        Sort-Object -Property @{ Expression = { [datetime]$_.published_at }; Descending = $true }, @{ Expression = { $_.tag_name }; Descending = $true } |
        Select-Object -First 1

    if ($latestSnapshot) { return $latestSnapshot.tag_name }
    throw "No snapshot release contains asset $AssetName."
}

Log-Step "Installation configuration:"
Log-Config "Service name: $ServiceName"
Log-Config "Install directory: $InstallDir"
Log-Config "Binary name: $InstallBinaryName"
Log-Config "GitHub proxy: $ProxyDisplay"
Log-Config "Agent arguments: $($KomariArgs -join ' ')"
Log-Config "Restart delay: $RestartDelay ms"
if ($InstallVersion -ne "") {
    Log-Config "Specified agent version: $InstallVersion"
}
else {
    Log-Config "Agent version: Latest"
}

$versionToInstall = ""
if ($InstallVersion -ne "") {
    Log-Info "Attempting to install specified version: $InstallVersion"
    if ($InstallVersion -ieq "snapshot") {
        Log-Info "Resolving the latest snapshot version..."
        try {
            $versionToInstall = Get-LatestSnapshotVersion -AssetName $BinaryName
            Log-Success "Latest snapshot version fetched: $versionToInstall"
        }
        catch {
            Log-Error "Failed to resolve the latest snapshot version: $_"
            exit 1
        }
    }
    else {
        $versionToInstall = $InstallVersion
    }
}
else {
    try {
        Log-Step "Fetching latest release version from GitHub API..."
        $release = Invoke-GitHub -Url "https://api.github.com/repos/VMCoud/komari-agent/releases/latest"
        $versionToInstall = $release.tag_name
        Log-Success "Latest version fetched: $versionToInstall"
    }
    catch {
        Log-Error "Failed to fetch latest version: $_"
        exit 1
    }
}
Log-Success "Installing Komari Agent version: $versionToInstall"

# ---------------------------------------------------------------------------
# Download the agent binary
# ---------------------------------------------------------------------------
$DownloadUrl = Join-GhProxyUrl "https://github.com/VMCoud/komari-agent/releases/download/$versionToInstall/$BinaryName"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Log-Info "URL: $DownloadUrl"
try {
    Invoke-GitHub -Url "https://github.com/VMCoud/komari-agent/releases/download/$versionToInstall/$BinaryName" -OutFile $AgentPath
}
catch {
    Log-Error "Download failed: $_"
    exit 1
}
Log-Success "Downloaded and saved to $AgentPath"

# ---------------------------------------------------------------------------
# Register the service with Shawl
# ---------------------------------------------------------------------------
Log-Step "Configuring Windows service with shawl..."

# --restart always relaunches the agent, matching NSSM's "AppExit Default
# Restart". --kill-process-tree puts the agent in a Job Object so the PowerShell
# helpers it spawns for remote tasks are torn down with the service.
# --stop-timeout is raised from Shawl's 3s default because komari-agent performs
# a graceful shutdown that flushes state over the network.
$shawlAddArgs = @(
    'add',
    '--name', $ServiceName,
    '--restart',
    '--restart-delay', "$RestartDelay",
    '--stop-timeout', '15000',
    '--kill-process-tree',
    '--cwd', $InstallDir,
    '--log-dir', $InstallDir,
    '--', $AgentPath
)
if ($KomariArgs.Count -gt 0) {
    $shawlAddArgs += $KomariArgs
}

try {
    & $ShawlExe @shawlAddArgs
    if ($LASTEXITCODE -ne 0) {
        Log-Error "shawl add failed with exit code $LASTEXITCODE"
        exit 1
    }
}
catch {
    Log-Error "Failed to register the service with shawl: $_"
    exit 1
}

Log-Step "Applying service settings..."
sc.exe config $ServiceName start= auto | Out-Null
sc.exe config $ServiceName DisplayName= "Komari Agent Service ($ServiceName)" | Out-Null
sc.exe description $ServiceName "Komari monitoring agent, wrapped by Shawl." | Out-Null

Log-Step "Starting service..."
sc.exe start $ServiceName | Out-Null

# Give the service a moment to settle, then confirm it is actually running.
$running = $false
for ($t = 0; $t -lt 20; $t++) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { $running = $true; break }
    if ($svc -and $svc.Status -eq 'Stopped') { break }
    Start-Sleep -Milliseconds 500
}

if ($running) {
    Log-Success "Service $ServiceName installed and started using shawl."
}
else {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $status = if ($svc) { $svc.Status } else { 'NotFound' }
    Log-Error "Service $ServiceName was created but is not running (status: $status)."
    Log-Error "Check the Shawl log in $InstallDir (shawl_for_*_CURRENT.log) for details."
    exit 1
}

Log-Success "Komari Agent installation completed!"
Log-Config "Service name: $ServiceName"
Log-Config "Arguments: $($KomariArgs -join ' ')"
Log-Config "Shawl log: $(Join-Path $InstallDir 'shawl_for_*_CURRENT.log')"
Log-Config "To uninstall: .\install-shawl.ps1 --uninstall"