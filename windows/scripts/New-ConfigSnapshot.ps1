<#
.SYNOPSIS
    Captures a structured configuration snapshot of a Windows Server 2022 host.

.DESCRIPTION
    New-ConfigSnapshot.ps1 collects the current state of a Windows server across
    multiple operationally significant categories (installed software, services,
    local users, firewall rules, scheduled tasks, listening ports, and pending
    Windows Updates) and writes the result to a timestamped JSON file.

    This snapshot is the foundational data point for the drift detection workflow.
    It is intended to be run either manually to establish a baseline, or on a
    schedule (via the included Windows Scheduled Task) to capture ongoing state
    for comparison against that baseline.

    WHY THIS SCRIPT EXISTS:
    Without a structured, repeatable snapshot process, configuration drift on a
    standalone or workgroup server goes undetected until it causes an incident.
    This script produces a consistent, comparable record of server state using
    only capabilities built into Windows Server 2022 — no agents, no external
    modules, no internet connectivity required.

.PARAMETER ConfigPath
    Path to the snapshot-config.json configuration file. Required.

.PARAMETER Label
    A short label describing the purpose of this snapshot (e.g. "baseline",
    "weekly-review", "post-patch"). Used in the output filename. Required.

.PARAMETER OutputOverridePath
    Optional. Overrides the snapshot output directory defined in the
    configuration file. Useful for ad-hoc snapshots without modifying config.

.EXAMPLE
    .\New-ConfigSnapshot.ps1 -ConfigPath ..\config\snapshot-config.json -Label "baseline"

    Captures a full snapshot using settings from the configuration file and
    labels it as the baseline.

.EXAMPLE
    .\New-ConfigSnapshot.ps1 -ConfigPath ..\config\snapshot-config.json -Label "post-patch" -OutputOverridePath "D:\Snapshots"

    Captures a snapshot labelled "post-patch" and writes it to D:\Snapshots
    instead of the directory defined in the configuration file.

.NOTES
    Author: server-config-drift-detector toolkit
    Requires: PowerShell 5.1 or later, Administrator privileges
    Script Version: 1.0.0

.OUTPUTS
    A single JSON file written to the configured snapshot directory, named:
    {hostname}_{yyyy-MM-dd}_{HHmm}_{label}.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to snapshot-config.json")]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true, HelpMessage = "Label for this snapshot, e.g. 'baseline' or 'weekly-review'")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-zA-Z0-9\-]+$')]
    [string]$Label,

    [Parameter(Mandatory = $false, HelpMessage = "Override the configured snapshot output directory")]
    [string]$OutputOverridePath
)

#region Script Constants
$ScriptVersion = "1.0.0"
$ScriptStartTime = Get-Date
#endregion

#region Logging Function
# WHY: Every operational script must produce a record of its own execution.
# This function writes timestamped, leveled log entries to both the console
# and a log file, so failures can be diagnosed without re-running the script.
function Write-SnapshotLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO",

        [Parameter(Mandatory = $false)]
        [string]$LogFilePath
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
        "WARN"  { Write-Host $logLine -ForegroundColor Yellow }
        default { Write-Host $logLine }
    }

    if ($LogFilePath) {
        try {
            Add-Content -Path $LogFilePath -Value $logLine -ErrorAction Stop
        }
        catch {
            Write-Host "[$timestamp] [WARN] Failed to write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
#endregion

#region Step 1 — Validate Prerequisites
# WHY: Failing fast with a clear message is more professional and more useful
# to an operator than failing partway through data collection with an unclear
# error. Administrator privileges are required because several categories
# (firewall rules, scheduled tasks, some service properties) require elevation
# to enumerate fully and accurately.
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-SnapshotLog -Message "This script must be run as Administrator. Current session is not elevated." -Level "ERROR"
    Write-SnapshotLog -Message "Re-launch PowerShell with 'Run as Administrator' and try again." -Level "ERROR"
    exit 1
}

if (-not (Test-Path -Path $ConfigPath)) {
    Write-SnapshotLog -Message "Configuration file not found at path: $ConfigPath" -Level "ERROR"
    exit 1
}

try {
    $config = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-SnapshotLog -Message "Failed to parse configuration file as JSON: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}
#endregion

#region Step 2 — Resolve Output Paths
# WHY: Paths in the config file may be relative. Resolving them against the
# repository root (parent of the script's parent directory) makes the script
# runnable from any working directory without requiring absolute paths in config.
$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

function Resolve-ConfiguredPath {
    param([string]$ConfiguredPath)
    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        return $ConfiguredPath
    }
    return Join-Path -Path $repoRoot -ChildPath $ConfiguredPath
}

$snapshotDir = if ($OutputOverridePath) { $OutputOverridePath } else { Resolve-ConfiguredPath -ConfiguredPath $config.output.snapshotDirectory }
$logDir = Resolve-ConfiguredPath -ConfiguredPath $config.output.logDirectory

foreach ($dir in @($snapshotDir, $logDir)) {
    if (-not (Test-Path -Path $dir)) {
        try {
            New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-SnapshotLog -Message "Failed to create directory '$dir': $($_.Exception.Message)" -Level "ERROR"
            exit 1
        }
    }
}

$logFileName = "snapshot_{0}.log" -f (Get-Date -Format "yyyy-MM-dd")
$logFilePath = Join-Path -Path $logDir -ChildPath $logFileName

Write-SnapshotLog -Message "New-ConfigSnapshot.ps1 v$ScriptVersion started. Label: '$Label'" -Level "INFO" -LogFilePath $logFilePath
#endregion

#region Step 3 — Initialise Snapshot Object
$hostname = $env:COMPUTERNAME
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

$snapshot = [ordered]@{
    metadata = [ordered]@{
        schema_version    = $config.schemaVersion
        hostname          = $hostname
        platform          = "windows"
        os_version        = if ($osInfo) { "$($osInfo.Caption) ($($osInfo.Version))" } else { "unknown" }
        os_build          = if ($osInfo) { $osInfo.BuildNumber } else { "unknown" }
        last_boot_time    = if ($osInfo) { $osInfo.LastBootUpTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { "unknown" }
        powershell_version = $PSVersionTable.PSVersion.ToString()
        snapshot_label    = $Label
        snapshot_timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        script_version    = $ScriptVersion
        captured_by       = "$env:USERDOMAIN\$env:USERNAME"
    }
    software         = @()
    services         = @()
    local_users      = @()
    firewall         = @()
    scheduled_jobs   = @()
    listening_ports  = @()
    platform_specific = [ordered]@{
        pending_updates = @()
    }
    capture_errors = @()
}
#endregion

#region Step 4 — Capture Installed Software
# WHY: Win32_Product can trigger Windows Installer self-repair as a documented
# side effect of querying it (see Microsoft KB and docs/snapshot-methodology.md).
# Registry enumeration is the safer default and is used unless explicitly
# overridden in configuration.
if ($config.captureCategories.installedSoftware) {
    Write-SnapshotLog -Message "Capturing installed software..." -Level "INFO" -LogFilePath $logFilePath
    try {
        $softwareList = New-Object System.Collections.Generic.List[object]

        if ($config.installedSoftwareOptions.useRegistryEnumeration) {
            $uninstallPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            foreach ($path in $uninstallPaths) {
                if (Test-Path -Path $path) {
                    Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne "" } |
                        ForEach-Object {
                            $softwareList.Add([ordered]@{
                                name      = $_.DisplayName
                                version   = if ($_.DisplayVersion) { $_.DisplayVersion } else { "unknown" }
                                publisher = if ($_.Publisher) { $_.Publisher } else { "unknown" }
                                install_date = if ($_.InstallDate) { $_.InstallDate } else { "unknown" }
                            })
                        }
                }
            }
        }

        if ($config.installedSoftwareOptions.useWmiQuery) {
            Write-SnapshotLog -Message "useWmiQuery is enabled. This may trigger Windows Installer self-repair (documented limitation)." -Level "WARN" -LogFilePath $logFilePath
            Get-CimInstance -ClassName Win32_Product -ErrorAction SilentlyContinue | ForEach-Object {
                $softwareList.Add([ordered]@{
                    name      = $_.Name
                    version   = $_.Version
                    publisher = $_.Vendor
                    install_date = $_.InstallDate
                })
            }
        }

        $snapshot.software = $softwareList | Sort-Object name -Unique
        Write-SnapshotLog -Message "Captured $($snapshot.software.Count) installed software entries." -Level "INFO" -LogFilePath $logFilePath
    }
    catch {
        $errMsg = "Failed to capture installed software: $($_.Exception.Message)"
        Write-SnapshotLog -Message $errMsg -Level "ERROR" -LogFilePath $logFilePath
        $snapshot.capture_errors += $errMsg
    }
}
#endregion

#region Step 5 — Capture Services
if ($config.captureCategories.services) {
    Write-SnapshotLog -Message "Capturing services..." -Level "INFO" -LogFilePath $logFilePath
    try {
        $wmiServices = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop
        $snapshot.services = $wmiServices | ForEach-Object {
            [ordered]@{
                name         = $_.Name
                display_name = $_.DisplayName
                status       = $_.State
                start_type   = $_.StartMode
            }
        } | Sort-Object name
        Write-SnapshotLog -Message "Captured $($snapshot.services.Count) services." -Level "INFO" -LogFilePath $logFilePath
    }
    catch {
        $errMsg = "Failed to capture services: $($_.Exception.Message)"
        Write-SnapshotLog -Message $errMsg -Level "ERROR" -LogFilePath $logFilePath
        $snapshot.capture_errors += $errMsg
    }
}
#endregion

#region Step 6 — Capture Local Users
if ($config.captureCategories.localUsers) {
    Write-SnapshotLog -Message "Capturing local user accounts..." -Level "INFO" -LogFilePath $logFilePath
    try {
        $localUsers = Get-LocalUser -ErrorAction Stop
        $snapshot.local_users = $localUsers | ForEach-Object {
            $userName = $_.Name
            $groups = @()
            try {
                $groups = Get-LocalGroup -ErrorAction SilentlyContinue | Where-Object {
                    $members = Get-LocalGroupMember -Group $_.Name -ErrorAction SilentlyContinue
                    $members | Where-Object { $_.Name -like "*\$userName" -or $_.Name -eq $userName }
                } | Select-Object -ExpandProperty Name
            }
            catch {
                # Group enumeration failure for a single user should not halt the whole capture.
                Write-SnapshotLog -Message "Could not enumerate group membership for user '$userName': $($_.Exception.Message)" -Level "WARN" -LogFilePath $logFilePath
            }

            [ordered]@{
                username          = $_.Name
                enabled           = $_.Enabled
                description       = $_.Description
                last_logon        = if ($_.LastLogon) { $_.LastLogon.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { "never" }
                password_last_set = if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { "unknown" }
                group_memberships = $groups
            }
        } | Sort-Object username
        Write-SnapshotLog -Message "Captured $($snapshot.local_users.Count) local user accounts." -Level "INFO" -LogFilePath $logFilePath
    }
    catch {
        $errMsg = "Failed to capture local users: $($_.Exception.Message)"
        Write-SnapshotLog -Message $errMsg -Level "ERROR" -LogFilePath $logFilePath
        $snapshot.capture_errors += $errMsg
    }
}
#endregion

#region Step 7 — Capture Firewall Rules
if ($config.captureCategories.firewallRules) {
    Write-SnapshotLog -Message "Capturing firewall rules..." -Level "INFO" -LogFilePath $logFilePath
    try {
        $rules = Get-NetFirewallRule -ErrorAction Stop
        $snapshot.firewall = $rules | ForEach-Object {
            $rule = $_
            $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $addressFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue

            [ordered]@{
                name           = $rule.Name
                display_name   = $rule.DisplayName
                enabled        = $rule.Enabled.ToString()
                direction      = $rule.Direction.ToString()
                action         = $rule.Action.ToString()
                profile        = $rule.Profile.ToString()
                protocol       = if ($portFilter) { $portFilter.Protocol } else { "unknown" }
                local_port     = if ($portFilter) { $portFilter.LocalPort -join "," } else { "unknown" }
                remote_address = if ($addressFilter) { $addressFilter.RemoteAddress -join "," } else { "unknown" }
            }
        } | Sort-Object name
        Write-SnapshotLog -Message "Captured $($snapshot.firewall.Count) firewall rules." -Level "INFO" -LogFilePath $logFilePath
    }
    catch {
        $errMsg = "Failed to capture firewall rules: $($_.Exception.Message)"
        Write-SnapshotLog -Message $errMsg -Level "ERROR" -LogFilePath $logFilePath
        $snapshot.capture_errors += $errMsg
    }
}
#endregion

#region Step 8 — Capture Scheduled Tasks
if ($config.captureCategories.scheduledTasks) {
    Write-SnapshotLog -Message "Capturing scheduled tasks..." -Level "INFO" -LogFilePath $logFilePath
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop
        $snapshot.scheduled_jobs = $tasks | ForEach-Object {
            $task = $_
            $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            $actionSummary = ($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " | "
            $triggerSummary = ($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ", "

            [ordered]@{
                name           = $task.TaskName
                path           = $task.TaskPath
                state          = $task.State.ToString()
                run_as_account = $task.Principal.UserId
                last_run_time  = if ($info -and $info.LastRunTime) { $info.LastRunTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { "never" }
                next_run_time  = if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { "not scheduled" }
                action_summary = $actionSummary
                trigger_summary = $triggerSummary
            }
        } | Sort-Object path, name
        Write-SnapshotLog -Message "Captured $($snapshot.scheduled_jobs.Count) scheduled tasks." -Level "INFO" -LogFilePath $logFilePath
    }
    catch {
        $errMsg = "Failed to capture scheduled tasks: $($_.Exception.Message)"
        Write-SnapshotLog -Message $errMsg -Level "ERROR" -LogFilePath $logFilePath
        $snapshot.capture_errors += $errMsg
    }
}
#endregion

#region Step 9 — Capture Listening Ports
if ($config.captureCategories.listeningPorts) {
    Write-SnapshotLog -Message "Capturing listening ports..." -Level "INFO" -LogFilePath $logFilePath
    try {
        $portList = New-Object System.Collections.Generic.List[object]

        $tcpConnections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
        foreach ($conn in $tcpConnections) {
            $procName = "unknown"
            try {
                $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                if ($proc) { $procName = $proc.ProcessName }
            }
            catch { }

            $portList.Add([ordered]@{
                protocol        = "TCP"
                local_address   = $conn.LocalAddress
                local_port      = $conn.LocalPort
                state           = "Listen"
                owning_pid      = $conn.OwningProcess
                owning_process  = $procName
            })
        }

        $udpEndpoints = Get-NetUDPEndpoint -ErrorAction SilentlyContinue
        foreach ($ep in $udpEndpoints) {
            $procName = "unknown"
            try {
                $proc = Get-Process -Id $ep.OwningProcess -ErrorAction SilentlyContinue
                if ($proc) { $procName = $proc.ProcessName }
            }
            catch { }

            $portList.Add([ordered]@{
                protocol        = "UDP"
                local_address   = $ep.LocalAddress
                local_port      = $ep.LocalPort
                state           = "Listen"
                owning_pid      = $ep.OwningProcess
                owning_process  = $procName
            })
        }

        $snapshot.listening_ports = $portList | Sort-Object protocol, local_port
        Write-SnapshotLog -Message "Captured $($snapshot.listening_ports.Count) listening ports." -Level "INFO" -LogFilePath $logFilePath
    }
    catch {
        $errMsg = "Failed to capture listening ports: $($_.Exception.Message)"
        Write-SnapshotLog -Message $errMsg -Level "ERROR" -LogFilePath $logFilePath
        $snapshot.capture_errors += $errMsg
    }
}
#endregion

#region Step 10 — Capture Pending Windows Updates
# WHY: Uses the built-in Windows Update Agent COM interface rather than the
# PSWindowsUpdate module, which is not installed by default on Windows Server
# 2022 and would violate the "no external dependencies" constraint of this toolkit.
if ($config.captureCategories.pendingUpdates) {
    Write-SnapshotLog -Message "Capturing pending Windows Updates..." -Level "INFO" -LogFilePath $logFilePath
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $updateSearcher = $updateSession.CreateUpdateSearcher()
        $searchResult = $updateSearcher.Search("IsInstalled=0 and IsHidden=0")

        $updateList = New-Object System.Collections.Generic.List[object]
        foreach ($update in $searchResult.Updates) {
            $kbArticle = if ($update.KBArticleIDs.Count -gt 0) { "KB$($update.KBArticleIDs[0])" } else { "unknown" }
            $updateList.Add([ordered]@{
                title    = $update.Title
                kb       = $kbArticle
                severity = if ($update.MsrcSeverity) { $update.MsrcSeverity } else { "unspecified" }
                category = if ($update.Categories.Count -gt 0) { $update.Categories.Item(0).Name } else { "unknown" }
            })
        }

        $snapshot.platform_specific.pending_updates = $updateList
        Write-SnapshotLog -Message "Captured $($updateList.Count) pending updates." -Level "INFO" -LogFilePath $logFilePath
    }
    catch {
        $errMsg = "Failed to capture pending Windows Updates: $($_.Exception.Message). This may occur if the Windows Update service is disabled or unreachable."
        Write-SnapshotLog -Message $errMsg -Level "WARN" -LogFilePath $logFilePath
        $snapshot.capture_errors += $errMsg
    }
}
#endregion

#region Step 11 — Write Snapshot File
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$snapshotFileName = "{0}_{1}_{2}.json" -f $hostname, $timestamp, $Label
$snapshotFilePath = Join-Path -Path $snapshotDir -ChildPath $snapshotFileName

try {
    $snapshot | ConvertTo-Json -Depth 10 | Out-File -FilePath $snapshotFilePath -Encoding utf8 -ErrorAction Stop
    Write-SnapshotLog -Message "Snapshot written successfully to: $snapshotFilePath" -Level "INFO" -LogFilePath $logFilePath
}
catch {
    Write-SnapshotLog -Message "FATAL: Failed to write snapshot file: $($_.Exception.Message)" -Level "ERROR" -LogFilePath $logFilePath
    exit 1
}
#endregion

#region Step 12 — Enforce Retention Policy
# WHY: Without retention enforcement, snapshot directories grow unbounded over
# time. Baseline snapshots are explicitly exempt because they represent the
# approved reference state and must never be automatically removed.
if ($config.retention.maxComparisonSnapshots -gt 0) {
    try {
        $allSnapshots = Get-ChildItem -Path $snapshotDir -Filter "*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch "_baseline\.json$" } |
            Sort-Object LastWriteTime -Descending

        if ($allSnapshots.Count -gt $config.retention.maxComparisonSnapshots) {
            $toRemove = $allSnapshots | Select-Object -Skip $config.retention.maxComparisonSnapshots
            foreach ($file in $toRemove) {
                Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
                Write-SnapshotLog -Message "Removed snapshot exceeding retention policy: $($file.Name)" -Level "INFO" -LogFilePath $logFilePath
            }
        }
    }
    catch {
        Write-SnapshotLog -Message "Retention policy enforcement encountered an error: $($_.Exception.Message)" -Level "WARN" -LogFilePath $logFilePath
    }
}
#endregion

#region Step 13 — Summary
$duration = (Get-Date) - $ScriptStartTime
Write-SnapshotLog -Message "Snapshot complete. Duration: $([math]::Round($duration.TotalSeconds, 2))s. Errors: $($snapshot.capture_errors.Count)." -Level "INFO" -LogFilePath $logFilePath

if ($snapshot.capture_errors.Count -gt 0) {
    Write-SnapshotLog -Message "Snapshot completed WITH ERRORS. Review the capture_errors array in the output file before using this snapshot as a baseline." -Level "WARN" -LogFilePath $logFilePath
    exit 2
}

exit 0
#endregion