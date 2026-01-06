#requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Logging
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $ScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogPath = Join-Path $LogDir "install_$Timestamp.log"

Start-Transcript -Path $LogPath -Append | Out-Null
#endregion Logging

function Write-Info($msg)  { Write-Host "[INFO]  $msg" }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-IsRebootPending {
    $paths = @(
        "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending",
        "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }

    try {
        $pfr = (Get-ItemProperty -Path "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue)
        if ($null -ne $pfr.PendingFileRenameOperations) { return $true }
    } catch { }

    return $false
}

function Get-CpuVendor {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Manufacturer
    if ($cpu -match "Intel") { return "Intel" }
    if ($cpu -match "AMD")   { return "AMD" }
    return "Unknown"
}

function Get-GpuVendors {
    $names = Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name
    $vendors = New-Object System.Collections.Generic.HashSet[string]

    foreach ($n in $names) {
        if ($n -match "NVIDIA") { $vendors.Add("NVIDIA") | Out-Null }
        elseif ($n -match "AMD|Radeon") { $vendors.Add("AMD") | Out-Null }
        elseif ($n -match "Intel") { $vendors.Add("Intel") | Out-Null }
    }

    return $vendors
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$OutFile
    )
    Write-Info "Downloading: $Url"
    try {
        Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
    } catch {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
    if (!(Test-Path $OutFile)) {
        throw "Download failed: $Url"
    }
    Write-Info "Saved to: $OutFile"
}

function Invoke-RunInstaller {
    param(
        [Parameter(Mandatory=$true)][string]$ExePath,
        [Parameter(Mandatory=$false)][string[]]$Args = @(),
        [Parameter(Mandatory=$false)][int[]]$SuccessExitCodes = @(0, 3010)
    )

    if (!(Test-Path $ExePath)) { throw "Installer not found: $ExePath" }

    $p = Start-Process -FilePath $ExePath -ArgumentList $Args -Wait -PassThru
    $code = $p.ExitCode

    Write-Info "Installer exit code: $code"
    if ($SuccessExitCodes -notcontains $code) {
        throw "Installer failed with exit code $code"
    }

    return $code
}

function Install-WindowsUpdates {
    Write-Info "Installing Windows Updates (no immediate reboot)..."
    try {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module PSWindowsUpdate -Force -Scope AllUsers
        }

        Import-Module PSWindowsUpdate
        Add-WUServiceManager -MicrosoftUpdate -ErrorAction SilentlyContinue | Out-Null
        Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot
    } catch {
        Write-Warn "Windows Update automation failed. Manual update may be required."
    }
}

try {
    Write-Info "Starting driver helper install pipeline..."

    $cpuVendor = Get-CpuVendor
    $gpuVendors = Get-GpuVendors

    Write-Info "CPU: $cpuVendor"
    Write-Info ("GPU(s): " + (($gpuVendors | Sort-Object) -join ", "))

    Install-WindowsUpdates

    Write-Info "Driver helper phase complete. A reboot may be required."
    if (Test-IsRebootPending) {
        Write-Warn "Reboot required. Restarting now..."
        Stop-Transcript | Out-Null
        Restart-Computer -Force
        return
    }

    Write-Info "Completed without requiring reboot."
}
catch {
    Write-Err $_.Exception.Message
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
