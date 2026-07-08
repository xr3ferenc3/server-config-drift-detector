<#
.SYNOPSIS
    Registers a Windows Scheduled Task to run New-ConfigSnapshot.ps1 on a daily schedule.

.DESCRIPTION
    Register-SnapshotTask.ps1 creates (or updates, if already present) a Windows
    Scheduled Task named "ConfigDriftDetector-Snapshot" that executes
    New-ConfigSnapshot.ps1 once per day. The task runs as SYSTEM with highest
    privileges, which is required because several capture categories (firewall
    rules, scheduled tasks, local user group membership, Windows Update queries)
    require elevation to enumerate completely and accurately.

    WHY THIS SCRIPT EXISTS:
    Manual snapshot execution does not scale operationally — it depends on a
    human remembering to run it. Automated scheduling is what makes ongoing
    drift detection possible without daily manual intervention. This script
    is idempotent: running it multiple times updates the existing task rather
    than creating duplicates, which makes it safe to re-run after configuration
    changes.

.PARAMETER ConfigPath
    Path to snapshot-config.json that the scheduled task will pass to
    New-ConfigSnapshot.ps1 at execution time. Required.

.PARAMETER ScriptPath
    Path to New-ConfigSnapshot.ps1. Required.

.PARAMETER TriggerTime
    The daily time the task should run, in 24-hour HH:mm format. Defaults to 02:00,
    chosen to run during typical low-activity hours.

.PARAMETER TaskName
    Name of the scheduled task. Defaults to "ConfigDriftDetector-Snapshot".

.EXAMPLE
    .\Register-SnapshotTask.ps1 -ConfigPath "C:\Tools\server-config-drift-detector\windows\config\snapshot-config.json" -ScriptPath "C:\Tools\server-config-drift-detector\windows\scripts\New-ConfigSnapshot.ps1"

    Registers the task using default trigger time of 02:00 daily.

.EXAMPLE
    .\Register-SnapshotTask.ps1 -ConfigPath "C:\Tools\snapshot-config.json" -ScriptPath "C:\Tools\New-ConfigSnapshot.ps1" -TriggerTime "03:30"

    Registers the task to run at 03:30 daily instead of the default.

.NOTES
    Author: server-config-drift-detector toolkit
    Requires: PowerShell 5.1 or later, Administrator privileges
    Script Version: 1.0.0

    Why absolute paths are required:
    Scheduled Tasks execute outside of any user's working directory context.
    Relative paths supplied to -ConfigPath or -ScriptPath would resolve
    unpredictably (typically against C:\Windows\System32) when the task runs.
    This script validates that both paths are absolute before proceeding.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Absolute path to snapshot-config.json")]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true, HelpMessage = "Absolute path to New-ConfigSnapshot.ps1")]
    [ValidateNotNullOrEmpty()]
    [string]$ScriptPath,

    [Parameter(Mandatory = $false, HelpMessage = "Daily trigger time in HH:mm 24-hour format")]
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$TriggerTime = "02:00",

    [Parameter(Mandatory = $false, HelpMessage = "Name of the scheduled task")]
    [string]$TaskName = "ConfigDriftDetector-Snapshot"
)

#region Logging Function
function Write-RegisterLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
        "WARN"  { Write-Host $logLine -ForegroundColor Yellow }
        default { Write-Host $logLine }
    }
}
#endregion

#region Step 1 — Validate Prerequisites
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-RegisterLog -Message "This script must be run as Administrator. Scheduled Task registration requires elevated privileges." -Level "ERROR"
    exit 1
}

# WHY: Validating absolute paths here prevents a task being silently
# registered with a relative path that will fail every time it runs
# unattended — a failure mode that would not surface until the next
# scheduled execution, far from when the mistake was made.
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    Write-RegisterLog -Message "ConfigPath must be an absolute path. Received: '$ConfigPath'. Relative paths will not resolve correctly when the task runs unattended." -Level "ERROR"
    exit 1
}

if (-not [System.IO.Path]::IsPathRooted($ScriptPath)) {
    Write-RegisterLog -Message "ScriptPath must be an absolute path. Received: '$ScriptPath'. Relative paths will not resolve correctly when the task runs unattended." -Level "ERROR"
    exit 1
}

if (-not (Test-Path -Path $ConfigPath)) {
    Write-RegisterLog -Message "Configuration file not found at: $ConfigPath" -Level "ERROR"
    exit 1
}

if (-not (Test-Path -Path $ScriptPath)) {
    Write-RegisterLog -Message "Snapshot script not found at: $ScriptPath" -Level "ERROR"
    exit 1
}
#endregion

#region Step 2 — Build Task Components
# WHY: The label "scheduled" distinguishes automated snapshots from manually
# labelled snapshots (e.g. "baseline", "post-patch") in the snapshot directory,
# making it easy for an operator to identify which snapshots were unattended.
$argumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`" -Label `"scheduled`""

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argumentList

$triggerParts = $TriggerTime -split ":"
$triggerDateTime = (Get-Date -Hour ([int]$triggerParts[0]) -Minute ([int]$triggerParts[1]) -Second 0)
$trigger = New-ScheduledTaskTrigger -Daily -At $triggerDateTime

# WHY: SYSTEM is used rather than a named administrator account so the task
# does not depend on a specific user's password remaining valid or that
# account remaining unlocked — both of which would silently break scheduled
# execution. SYSTEM also has the elevation needed for full-fidelity capture
# without storing or managing credentials.
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# WHY: These settings ensure the task is resilient to common real-world
# conditions on a server that may be rebooted unexpectedly or under load
# at the scheduled time.
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew
#endregion

#region Step 3 — Register or Update the Task
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

try {
    if ($existingTask) {
        Write-RegisterLog -Message "Task '$TaskName' already exists. Updating with current configuration." -Level "INFO"
        Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
        Write-RegisterLog -Message "Task '$TaskName' updated successfully." -Level "INFO"
    }
    else {
        Write-RegisterLog -Message "Registering new scheduled task '$TaskName'." -Level "INFO"
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Captures a daily configuration snapshot for drift detection. Part of server-config-drift-detector toolkit. Do not modify manually — re-run Register-SnapshotTask.ps1 to change configuration." -ErrorAction Stop | Out-Null
        Write-RegisterLog -Message "Task '$TaskName' registered successfully." -Level "INFO"
    }
}
catch {
    Write-RegisterLog -Message "Failed to register or update scheduled task: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}
#endregion

#region Step 4 — Validate Registration
$verifyTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if (-not $verifyTask) {
    Write-RegisterLog -Message "Task registration could not be verified. The task does not appear in the Task Scheduler library." -Level "ERROR"
    exit 1
}

if ($verifyTask.State -eq "Disabled") {
    Write-RegisterLog -Message "Task was registered but is in a Disabled state. Enabling now." -Level "WARN"
    try {
        Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    }
    catch {
        Write-RegisterLog -Message "Failed to enable task: $($_.Exception.Message)" -Level "ERROR"
        exit 1
    }
}

$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
Write-RegisterLog -Message "Verification complete." -Level "INFO"
Write-RegisterLog -Message "Task Name: $TaskName" -Level "INFO"
Write-RegisterLog -Message "State: $($verifyTask.State)" -Level "INFO"
Write-RegisterLog -Message "Next Run Time: $($taskInfo.NextRunTime)" -Level "INFO"
Write-RegisterLog -Message "Run As: SYSTEM" -Level "INFO"
Write-RegisterLog -Message "Daily Trigger Time: $TriggerTime" -Level "INFO"
#endregion

#region Step 5 — Summary
Write-RegisterLog -Message "Scheduled task registration complete." -Level "INFO"
Write-RegisterLog -Message "To verify manually: Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo" -Level "INFO"
Write-RegisterLog -Message "To run immediately for testing: Start-ScheduledTask -TaskName '$TaskName'" -Level "INFO"
Write-RegisterLog -Message "To review execution history: open Task Scheduler, locate '$TaskName', and check the History tab (requires Task Scheduler history to be enabled)." -Level "INFO"

exit 0
#endregion