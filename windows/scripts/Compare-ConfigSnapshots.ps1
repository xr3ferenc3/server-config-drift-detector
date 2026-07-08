<#
.SYNOPSIS
    Compares two Windows configuration snapshots and produces a structured diff.

.DESCRIPTION
    Compare-ConfigSnapshots.ps1 accepts two snapshot JSON files produced by
    New-ConfigSnapshot.ps1 — a baseline and a comparison snapshot — and performs
    a field-by-field comparison across every captured category. The result is
    written as a single structured diff JSON file identifying additions,
    removals, and modifications per category.

    WHY THIS SCRIPT EXISTS:
    Raw snapshots are only useful in isolation for inventory purposes. The
    operational value of this toolkit comes from comparing two points in time.
    This script performs that comparison deterministically and produces output
    that is consumed by Invoke-DriftReport.ps1. It does not classify severity
    or render human-readable output — that separation of concerns keeps this
    script focused and testable.

.PARAMETER BaselineSnapshot
    Path to the baseline (reference) snapshot JSON file. Required.

.PARAMETER CompareSnapshot
    Path to the comparison snapshot JSON file to evaluate against the baseline. Required.

.PARAMETER OutputPath
    Path where the resulting diff JSON file will be written. Required.

.EXAMPLE
    .\Compare-ConfigSnapshots.ps1 -BaselineSnapshot ..\snapshots\server01_2025-10-01_0200_baseline.json -CompareSnapshot ..\snapshots\server01_2025-10-08_0200_weekly-review.json -OutputPath ..\diff\server01_diff_2025-10-01_vs_2025-10-08.json

.NOTES
    Author: server-config-drift-detector toolkit
    Requires: PowerShell 5.1 or later
    Script Version: 1.0.0

.OUTPUTS
    A single diff JSON file describing added, removed, and modified entries
    per category, written to the specified output path.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the baseline snapshot JSON file")]
    [ValidateNotNullOrEmpty()]
    [string]$BaselineSnapshot,

    [Parameter(Mandatory = $true, HelpMessage = "Path to the comparison snapshot JSON file")]
    [ValidateNotNullOrEmpty()]
    [string]$CompareSnapshot,

    [Parameter(Mandatory = $true, HelpMessage = "Path where the diff JSON output will be written")]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

#region Script Constants
$ScriptVersion = "1.0.0"
#endregion

#region Logging Function
function Write-CompareLog {
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
# WHY: Comparison requires two valid, parseable snapshots. Failing fast with a
# specific error (missing file vs malformed JSON vs schema mismatch) saves the
# operator diagnostic time compared to a generic exception trace.
foreach ($path in @($BaselineSnapshot, $CompareSnapshot)) {
    if (-not (Test-Path -Path $path)) {
        Write-CompareLog -Message "Snapshot file not found: $path" -Level "ERROR"
        exit 1
    }
}

try {
    $baseline = Get-Content -Path $BaselineSnapshot -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-CompareLog -Message "Failed to parse baseline snapshot as JSON: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

try {
    $compare = Get-Content -Path $CompareSnapshot -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-CompareLog -Message "Failed to parse comparison snapshot as JSON: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

if (-not $baseline.metadata -or -not $compare.metadata) {
    Write-CompareLog -Message "One or both snapshot files are missing the required 'metadata' block. These may not be valid snapshots produced by New-ConfigSnapshot.ps1." -Level "ERROR"
    exit 1
}

if ($baseline.metadata.schema_version -ne $compare.metadata.schema_version) {
    Write-CompareLog -Message "Schema version mismatch: baseline is '$($baseline.metadata.schema_version)', comparison is '$($compare.metadata.schema_version)'. Comparison will proceed but results may be incomplete if category structures differ between schema versions." -Level "WARN"
}

if ($baseline.metadata.hostname -ne $compare.metadata.hostname) {
    Write-CompareLog -Message "Hostname mismatch: baseline is '$($baseline.metadata.hostname)', comparison is '$($compare.metadata.hostname)'. Comparing snapshots from different hosts is unusual — confirm this is intentional." -Level "WARN"
}

Write-CompareLog -Message "Comparing baseline '$($baseline.metadata.snapshot_label)' ($($baseline.metadata.snapshot_timestamp)) against '$($compare.metadata.snapshot_label)' ($($compare.metadata.snapshot_timestamp))" -Level "INFO"
#endregion

#region Step 2 — Generic List Comparison Function
# WHY: Every category in the snapshot schema is an array of objects with a
# defined key field (e.g. 'name' for services, 'username' for local users).
# Rather than writing separate comparison logic per category, this function
# generalises the pattern: match by key, then diff fields for matched items.
function Compare-ObjectList {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][array]$BaselineList,
        [Parameter(Mandatory = $true)][AllowNull()][array]$CompareList,
        [Parameter(Mandatory = $true)][string]$KeyField
    )

    $result = [ordered]@{
        added    = @()
        removed  = @()
        modified = @()
    }

    if ($null -eq $BaselineList) { $BaselineList = @() }
    if ($null -eq $CompareList) { $CompareList = @() }

    $baselineMap = @{}
    foreach ($item in $BaselineList) {
        $keyValue = $item.$KeyField
        if ($null -ne $keyValue) {
            $baselineMap[[string]$keyValue] = $item
        }
    }

    $compareMap = @{}
    foreach ($item in $CompareList) {
        $keyValue = $item.$KeyField
        if ($null -ne $keyValue) {
            $compareMap[[string]$keyValue] = $item
        }
    }

    # Items present in compare but not baseline = added
    foreach ($key in $compareMap.Keys) {
        if (-not $baselineMap.ContainsKey($key)) {
            $result.added += $compareMap[$key]
        }
    }

    # Items present in baseline but not compare = removed
    foreach ($key in $baselineMap.Keys) {
        if (-not $compareMap.ContainsKey($key)) {
            $result.removed += $baselineMap[$key]
        }
    }

    # Items present in both = check for field-level modifications
    foreach ($key in $baselineMap.Keys) {
        if ($compareMap.ContainsKey($key)) {
            $baselineItem = $baselineMap[$key]
            $compareItem = $compareMap[$key]
            $changedFields = @()

            $allFieldNames = @($baselineItem.PSObject.Properties.Name) + @($compareItem.PSObject.Properties.Name) | Select-Object -Unique

            foreach ($field in $allFieldNames) {
                # last_logon is intentionally excluded from drift comparison —
                # see docs/snapshot-methodology.md: it changes on every authentication
                # event and would generate false positives on every comparison run.
                if ($field -eq "last_logon") { continue }

                $baselineValue = $baselineItem.$field
                $compareValue = $compareItem.$field

                $baselineValueStr = if ($null -eq $baselineValue) { "" } elseif ($baselineValue -is [array]) { ($baselineValue -join ",") } else { [string]$baselineValue }
                $compareValueStr  = if ($null -eq $compareValue)  { "" } elseif ($compareValue -is [array])  { ($compareValue -join ",") }  else { [string]$compareValue }

                if ($baselineValueStr -ne $compareValueStr) {
                    $changedFields += [ordered]@{
                        field    = $field
                        from     = $baselineValueStr
                        to       = $compareValueStr
                    }
                }
            }

            if ($changedFields.Count -gt 0) {
                $result.modified += [ordered]@{
                    key            = $key
                    changed_fields = $changedFields
                }
            }
        }
    }

    return $result
}
#endregion

#region Step 3 — Run Category Comparisons
Write-CompareLog -Message "Running category comparisons..." -Level "INFO"

$categories = [ordered]@{
    software        = Compare-ObjectList -BaselineList $baseline.software       -CompareList $compare.software       -KeyField "name"
    services        = Compare-ObjectList -BaselineList $baseline.services       -CompareList $compare.services       -KeyField "name"
    local_users     = Compare-ObjectList -BaselineList $baseline.local_users    -CompareList $compare.local_users    -KeyField "username"
    firewall        = Compare-ObjectList -BaselineList $baseline.firewall       -CompareList $compare.firewall       -KeyField "name"
    scheduled_jobs  = Compare-ObjectList -BaselineList $baseline.scheduled_jobs -CompareList $compare.scheduled_jobs -KeyField "name"
    listening_ports = Compare-ObjectList -BaselineList $baseline.listening_ports -CompareList $compare.listening_ports -KeyField "local_port"
}

# Pending updates compared by KB article number rather than title, since
# titles can include minor wording variations between query runs while the
# KB identifier remains stable.
$pendingUpdatesBaseline = if ($baseline.platform_specific.pending_updates) { $baseline.platform_specific.pending_updates } else { @() }
$pendingUpdatesCompare  = if ($compare.platform_specific.pending_updates)  { $compare.platform_specific.pending_updates }  else { @() }

$categories["platform_specific"] = [ordered]@{
    pending_updates = Compare-ObjectList -BaselineList $pendingUpdatesBaseline -CompareList $pendingUpdatesCompare -KeyField "kb"
}

foreach ($catName in @("software", "services", "local_users", "firewall", "scheduled_jobs", "listening_ports")) {
    $cat = $categories[$catName]
    $totalChanges = $cat.added.Count + $cat.removed.Count + $cat.modified.Count
    Write-CompareLog -Message "Category '$catName': $($cat.added.Count) added, $($cat.removed.Count) removed, $($cat.modified.Count) modified ($totalChanges total)" -Level "INFO"
}
#endregion

#region Step 4 — Build Diff Object
$diff = [ordered]@{
    metadata = [ordered]@{
        schema_version       = "1.0"
        hostname             = $baseline.metadata.hostname
        platform             = "windows"
        baseline_snapshot    = (Split-Path -Path $BaselineSnapshot -Leaf)
        baseline_timestamp   = $baseline.metadata.snapshot_timestamp
        compare_snapshot     = (Split-Path -Path $CompareSnapshot -Leaf)
        compare_timestamp    = $compare.metadata.snapshot_timestamp
        diff_generated       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        script_version       = $ScriptVersion
    }
    categories = $categories
}
#endregion

#region Step 5 — Write Diff File
$outputDir = Split-Path -Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path -Path $outputDir)) {
    try {
        New-Item -Path $outputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-CompareLog -Message "Failed to create output directory '$outputDir': $($_.Exception.Message)" -Level "ERROR"
        exit 1
    }
}

try {
    $diff | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding utf8 -ErrorAction Stop
    Write-CompareLog -Message "Diff file written successfully to: $OutputPath" -Level "INFO"
}
catch {
    Write-CompareLog -Message "FATAL: Failed to write diff file: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}
#endregion

#region Step 6 — Summary
$totalAdded = 0
$totalRemoved = 0
$totalModified = 0
foreach ($catName in @("software", "services", "local_users", "firewall", "scheduled_jobs", "listening_ports")) {
    $totalAdded += $categories[$catName].added.Count
    $totalRemoved += $categories[$catName].removed.Count
    $totalModified += $categories[$catName].modified.Count
}
$totalAdded += $categories.platform_specific.pending_updates.added.Count
$totalRemoved += $categories.platform_specific.pending_updates.removed.Count
$totalModified += $categories.platform_specific.pending_updates.modified.Count

$totalChanges = $totalAdded + $totalRemoved + $totalModified
Write-CompareLog -Message "Comparison complete. Total changes: $totalChanges (added: $totalAdded, removed: $totalRemoved, modified: $totalModified)" -Level "INFO"

if ($totalChanges -eq 0) {
    Write-CompareLog -Message "No drift detected. Server state matches baseline." -Level "INFO"
}

exit 0
#endregion