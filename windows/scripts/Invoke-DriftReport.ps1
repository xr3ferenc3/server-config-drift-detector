<#
.SYNOPSIS
    Generates human-readable and machine-readable drift reports from a snapshot diff.

.DESCRIPTION
    Invoke-DriftReport.ps1 consumes the diff JSON produced by
    Compare-ConfigSnapshots.ps1, applies severity classification per category
    using the thresholds defined in snapshot-config.json, and produces two
    output files: a Markdown report suitable for attaching to a ticket or
    sharing with a team, and a JSON report suitable for audit storage or
    consumption by other tooling.

    WHY THIS SCRIPT EXISTS:
    A raw diff is data. A drift report is information an operator can act on.
    This script is where severity judgement is applied — distinguishing a
    routine software version bump from a new local administrator account.
    Keeping this logic separate from the comparison script means the severity
    model can be tuned in configuration without touching comparison logic.

.PARAMETER DiffFile
    Path to the diff JSON file produced by Compare-ConfigSnapshots.ps1. Required.

.PARAMETER ConfigPath
    Path to snapshot-config.json, used to read severity thresholds and admin
    group names. Required.

.PARAMETER OutputDir
    Directory where the Markdown and JSON report files will be written. Required.

.EXAMPLE
    .\Invoke-DriftReport.ps1 -DiffFile ..\diff\server01_diff_2025-10-01_vs_2025-10-08.json -ConfigPath ..\config\snapshot-config.json -OutputDir ..\reports

.NOTES
    Author: server-config-drift-detector toolkit
    Requires: PowerShell 5.1 or later
    Script Version: 1.0.0

.OUTPUTS
    {hostname}_drift-report_{date}.md
    {hostname}_drift-report_{date}.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the diff JSON file")]
    [ValidateNotNullOrEmpty()]
    [string]$DiffFile,

    [Parameter(Mandatory = $true, HelpMessage = "Path to snapshot-config.json")]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true, HelpMessage = "Directory to write report files into")]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDir
)

#region Script Constants
$ScriptVersion = "1.0.0"
#endregion

#region Logging Function
function Write-ReportLog {
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

#region Step 1 — Validate Inputs
if (-not (Test-Path -Path $DiffFile)) {
    Write-ReportLog -Message "Diff file not found: $DiffFile" -Level "ERROR"
    exit 1
}

if (-not (Test-Path -Path $ConfigPath)) {
    Write-ReportLog -Message "Configuration file not found: $ConfigPath" -Level "ERROR"
    exit 1
}

try {
    $diff = Get-Content -Path $DiffFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-ReportLog -Message "Failed to parse diff file as JSON: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

try {
    $config = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-ReportLog -Message "Failed to parse configuration file as JSON: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

if (-not $diff.metadata -or -not $diff.categories) {
    Write-ReportLog -Message "Diff file is missing required 'metadata' or 'categories' blocks. This may not be a valid diff produced by Compare-ConfigSnapshots.ps1." -Level "ERROR"
    exit 1
}

if (-not (Test-Path -Path $OutputDir)) {
    try {
        New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-ReportLog -Message "Failed to create output directory '$OutputDir': $($_.Exception.Message)" -Level "ERROR"
        exit 1
    }
}
#endregion

#region Step 2 — Severity Classification Function
# WHY: Severity is determined by category and change type (added/removed/modified),
# with an escalation rule for privileged group membership changes. This mirrors
# the design in docs/architecture-overview.md and keeps the logic data-driven
# from configuration rather than hardcoded, so operators can retune thresholds
# without editing script code.
function Get-ChangeSeverity {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$ChangeType,
        [Parameter(Mandatory = $false)][object]$ItemDetail,
        [Parameter(Mandatory = $true)][object]$Config
    )

    # Escalation rule: any modification involving an admin-equivalent group
    # membership is always CRITICAL, regardless of configured threshold.
    if ($Category -eq "local_users" -and $ChangeType -eq "modified" -and $ItemDetail) {
        foreach ($field in $ItemDetail.changed_fields) {
            if ($field.field -eq "group_memberships") {
                foreach ($adminGroup in $Config.adminGroupNames.groups) {
                    if ($field.to -match [regex]::Escape($adminGroup)) {
                        return "CRITICAL"
                    }
                }
            }
        }
    }

    $categoryThresholds = $Config.severityThresholds.$Category
    if ($categoryThresholds -and $categoryThresholds.$ChangeType) {
        return $categoryThresholds.$ChangeType
    }

    # Default fallback if a category/changeType combination is not explicitly
    # configured. NOTABLE ensures unconfigured categories are never silently
    # downgraded to invisible.
    return "NOTABLE"
}

function Get-SeverityWeight {
    param([string]$Severity)
    switch ($Severity) {
        "CRITICAL"      { return 3 }
        "NOTABLE"       { return 2 }
        "INFORMATIONAL" { return 1 }
        default         { return 0 }
    }
}
#endregion

#region Step 3 — Process Categories and Build Findings
Write-ReportLog -Message "Classifying drift findings..." -Level "INFO"

$categoryDisplayNames = [ordered]@{
    software        = "Installed Software"
    services        = "Services"
    local_users     = "Local Users"
    firewall        = "Firewall Rules"
    scheduled_jobs  = "Scheduled Tasks"
    listening_ports = "Listening Ports"
}

$findings = [ordered]@{}
$summaryRows = New-Object System.Collections.Generic.List[object]
$highestOverallSeverity = "NONE"

foreach ($catKey in $categoryDisplayNames.Keys) {
    $catData = $diff.categories.$catKey
    if (-not $catData) { continue }

    $catFindings = New-Object System.Collections.Generic.List[object]
    $catHighestSeverity = "NONE"

    foreach ($item in $catData.added) {
        $severity = Get-ChangeSeverity -Category $catKey -ChangeType "added" -ItemDetail $item -Config $config
        $catFindings.Add([ordered]@{ change_type = "added"; severity = $severity; detail = $item })
        if ((Get-SeverityWeight $severity) -gt (Get-SeverityWeight $catHighestSeverity)) { $catHighestSeverity = $severity }
    }
    foreach ($item in $catData.removed) {
        $severity = Get-ChangeSeverity -Category $catKey -ChangeType "removed" -ItemDetail $item -Config $config
        $catFindings.Add([ordered]@{ change_type = "removed"; severity = $severity; detail = $item })
        if ((Get-SeverityWeight $severity) -gt (Get-SeverityWeight $catHighestSeverity)) { $catHighestSeverity = $severity }
    }
    foreach ($item in $catData.modified) {
        $severity = Get-ChangeSeverity -Category $catKey -ChangeType "modified" -ItemDetail $item -Config $config
        $catFindings.Add([ordered]@{ change_type = "modified"; severity = $severity; detail = $item })
        if ((Get-SeverityWeight $severity) -gt (Get-SeverityWeight $catHighestSeverity)) { $catHighestSeverity = $severity }
    }

    $totalChanges = $catData.added.Count + $catData.removed.Count + $catData.modified.Count
    $findings[$catKey] = $catFindings

    $summaryRows.Add([ordered]@{
        category    = $categoryDisplayNames[$catKey]
        change_count = $totalChanges
        severity    = if ($totalChanges -eq 0) { "NONE" } else { $catHighestSeverity }
    })

    if ((Get-SeverityWeight $catHighestSeverity) -gt (Get-SeverityWeight $highestOverallSeverity)) {
        $highestOverallSeverity = $catHighestSeverity
    }
}

# Pending updates handled separately — informational category, not part of
# the core security-relevant summary table escalation logic.
$pendingUpdatesData = $diff.categories.platform_specific.pending_updates
$pendingUpdatesFindings = New-Object System.Collections.Generic.List[object]
if ($pendingUpdatesData) {
    foreach ($item in $pendingUpdatesData.added) {
        $severity = Get-ChangeSeverity -Category "pendingUpdates" -ChangeType "added" -ItemDetail $item -Config $config
        $pendingUpdatesFindings.Add([ordered]@{ change_type = "added"; severity = $severity; detail = $item })
    }
    foreach ($item in $pendingUpdatesData.removed) {
        $severity = Get-ChangeSeverity -Category "pendingUpdates" -ChangeType "removed" -ItemDetail $item -Config $config
        $pendingUpdatesFindings.Add([ordered]@{ change_type = "removed"; severity = $severity; detail = $item })
    }
    $pendingUpdatesCount = $pendingUpdatesData.added.Count + $pendingUpdatesData.removed.Count
    $summaryRows.Add([ordered]@{
        category     = "Pending Windows Updates"
        change_count = $pendingUpdatesCount
        severity     = if ($pendingUpdatesCount -eq 0) { "NONE" } else { "INFORMATIONAL" }
    })
}

Write-ReportLog -Message "Classification complete. Overall severity: $highestOverallSeverity" -Level "INFO"
#endregion

#region Step 4 — Render Markdown Report
function Format-FindingDetailMarkdown {
    param([string]$ChangeType, [object]$Detail)

    switch ($ChangeType) {
        "added"   { return "Added: ``$($Detail | ConvertTo-Json -Compress)``" }
        "removed" { return "Removed: ``$($Detail | ConvertTo-Json -Compress)``" }
        "modified" {
            $changes = ($Detail.changed_fields | ForEach-Object { "$($_.field): '$($_.from)' -> '$($_.to)'" }) -join "; "
            return "Modified **$($Detail.key)**: $changes"
        }
    }
}

$reportDate = Get-Date -Format "yyyy-MM-dd"
$reportTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Drift Report — $($diff.metadata.hostname)")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Field | Value |")
[void]$md.AppendLine("|---|---|")
[void]$md.AppendLine("| Hostname | $($diff.metadata.hostname) |")
[void]$md.AppendLine("| Platform | Windows |")
[void]$md.AppendLine("| Baseline Snapshot | $($diff.metadata.baseline_snapshot) |")
[void]$md.AppendLine("| Baseline Timestamp | $($diff.metadata.baseline_timestamp) |")
[void]$md.AppendLine("| Comparison Snapshot | $($diff.metadata.compare_snapshot) |")
[void]$md.AppendLine("| Comparison Timestamp | $($diff.metadata.compare_timestamp) |")
[void]$md.AppendLine("| Report Generated | $reportTime |")
[void]$md.AppendLine("| Overall Severity | **$highestOverallSeverity** |")
[void]$md.AppendLine("")
[void]$md.AppendLine("## Summary")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Category | Changes | Severity |")
[void]$md.AppendLine("|---|---|---|")
foreach ($row in $summaryRows) {
    [void]$md.AppendLine("| $($row.category) | $($row.change_count) | $($row.severity) |")
}
[void]$md.AppendLine("")
[void]$md.AppendLine("## Detail")
[void]$md.AppendLine("")

foreach ($catKey in $categoryDisplayNames.Keys) {
    $catFindings = $findings[$catKey]
    if (-not $catFindings -or $catFindings.Count -eq 0) { continue }

    $relevantFindings = $catFindings
    if (-not $config.reportOptions.includeInformationalChangesInDetail) {
        $relevantFindings = $catFindings | Where-Object { $_.severity -ne "INFORMATIONAL" }
    }
    if ($relevantFindings.Count -eq 0) { continue }

    [void]$md.AppendLine("### $($categoryDisplayNames[$catKey])")
    [void]$md.AppendLine("")
    foreach ($f in $relevantFindings) {
        $line = Format-FindingDetailMarkdown -ChangeType $f.change_type -Detail $f.detail
        [void]$md.AppendLine("- **[$($f.severity)]** $line")
    }
    [void]$md.AppendLine("")
}

if ($pendingUpdatesFindings.Count -gt 0) {
    [void]$md.AppendLine("### Pending Windows Updates")
    [void]$md.AppendLine("")
    foreach ($f in $pendingUpdatesFindings) {
        $line = Format-FindingDetailMarkdown -ChangeType $f.change_type -Detail $f.detail
        [void]$md.AppendLine("- **[$($f.severity)]** $line")
    }
    [void]$md.AppendLine("")
}

if (($summaryRows | Measure-Object -Property change_count -Sum).Sum -eq 0) {
    [void]$md.AppendLine("No drift detected. Server state matches the baseline across all monitored categories.")
    [void]$md.AppendLine("")
}

[void]$md.AppendLine("## Operational Notes")
[void]$md.AppendLine("")
[void]$md.AppendLine("- Review findings using the decision framework in ``docs/drift-interpretation-guide.md``")
[void]$md.AppendLine("- CRITICAL findings should be investigated before this report is closed")
[void]$md.AppendLine("- If all findings are approved as legitimate, consider promoting this snapshot to the new baseline using ``templates/baseline-approval-template.md``")
[void]$md.AppendLine("")
[void]$md.AppendLine("---")
[void]$md.AppendLine("*Generated by Invoke-DriftReport.ps1 v$ScriptVersion*")
#endregion

#region Step 5 — Build JSON Report
$jsonReport = [ordered]@{
    metadata = [ordered]@{
        hostname            = $diff.metadata.hostname
        platform            = "windows"
        baseline_snapshot   = $diff.metadata.baseline_snapshot
        baseline_timestamp  = $diff.metadata.baseline_timestamp
        compare_snapshot    = $diff.metadata.compare_snapshot
        compare_timestamp   = $diff.metadata.compare_timestamp
        report_generated    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        overall_severity    = $highestOverallSeverity
        script_version      = $ScriptVersion
    }
    summary  = $summaryRows
    findings = $findings
    pending_updates_findings = $pendingUpdatesFindings
}
#endregion

#region Step 6 — Write Output Files
$baseFileName = "{0}_drift-report_{1}" -f $diff.metadata.hostname, $reportDate

if ($config.reportOptions.generateMarkdown) {
    $mdPath = Join-Path -Path $OutputDir -ChildPath "$baseFileName.md"
    try {
        $md.ToString() | Out-File -FilePath $mdPath -Encoding utf8 -ErrorAction Stop
        Write-ReportLog -Message "Markdown report written to: $mdPath" -Level "INFO"
    }
    catch {
        Write-ReportLog -Message "Failed to write Markdown report: $($_.Exception.Message)" -Level "ERROR"
        exit 1
    }
}

if ($config.reportOptions.generateJson) {
    $jsonPath = Join-Path -Path $OutputDir -ChildPath "$baseFileName.json"
    try {
        $jsonReport | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8 -ErrorAction Stop
        Write-ReportLog -Message "JSON report written to: $jsonPath" -Level "INFO"
    }
    catch {
        Write-ReportLog -Message "Failed to write JSON report: $($_.Exception.Message)" -Level "ERROR"
        exit 1
    }
}
#endregion

#region Step 7 — Summary
$totalFindings = ($summaryRows | Measure-Object -Property change_count -Sum).Sum
Write-ReportLog -Message "Report generation complete. Total findings: $totalFindings. Overall severity: $highestOverallSeverity." -Level "INFO"

if ($highestOverallSeverity -eq "CRITICAL") {
    Write-ReportLog -Message "CRITICAL severity findings present. Immediate review recommended." -Level "WARN"
    exit 3
}

exit 0
#endregion