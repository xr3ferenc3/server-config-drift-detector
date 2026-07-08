#!/usr/bin/env bash
#
# drift-report.sh
#
# SYNOPSIS
#   Generates human-readable and machine-readable drift reports from a
#   Linux snapshot diff.
#
# DESCRIPTION
#   drift-report.sh consumes the diff JSON produced by compare-snapshots.sh,
#   applies severity classification per category using the thresholds
#   defined in snapshot.conf, and produces two output files: a Markdown
#   report suitable for attaching to a ticket or sharing with a team, and a
#   JSON report suitable for audit storage or consumption by other tooling.
#
#   WHY THIS SCRIPT EXISTS:
#   A raw diff is data. A drift report is information an operator can act
#   on. This script is where severity judgement is applied -- distinguishing
#   a routine package version bump from a new wheel group membership.
#   Keeping this logic separate from the comparison script means the
#   severity model can be tuned in configuration without touching
#   comparison logic. This script mirrors Invoke-DriftReport.ps1 so that
#   Windows and Linux reports share identical structure, severity model,
#   and operational workflow.
#
# USAGE
#   drift-report.sh --diff <path> --config <path> --output-dir <path>
#
# OPTIONS
#   --diff         Path to the diff JSON file produced by compare-snapshots.sh. Required.
#   --config       Path to snapshot.conf, used to read severity thresholds. Required.
#   --output-dir   Directory where the Markdown and JSON report files will be written. Required.
#   --help         Display this usage information and exit.
#
# EXAMPLES
#   drift-report.sh --diff ../diff/server01_diff.json --config ../config/snapshot.conf --output-dir ../reports
#
# REQUIRES
#   Bash 4.0+, jq
#
# OUTPUTS
#   {hostname}_drift-report_{date}.md
#   {hostname}_drift-report_{date}.json
#
# SCRIPT VERSION: 1.0.0

set -u
set -o pipefail

SCRIPT_VERSION="1.0.0"

print_usage() {
  grep '^#' "$0" | sed -n '/^# SYNOPSIS/,/^# SCRIPT VERSION/p' | sed 's/^# \{0,1\}//'
}

log_message() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  local line="[${timestamp}] [${level}] ${message}"
  if [[ "$level" == "ERROR" ]]; then
    echo "$line" >&2
  else
    echo "$line"
  fi
}

# -----------------------------------------------------------------------------
# Step 1 -- Parse Arguments
# -----------------------------------------------------------------------------
DIFF_PATH=""
CONFIG_PATH=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff)
      DIFF_PATH="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

if [[ -z "$DIFF_PATH" || -z "$CONFIG_PATH" || -z "$OUTPUT_DIR" ]]; then
  echo "ERROR: --diff, --config, and --output-dir are all required." >&2
  print_usage
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 2 -- Validate Inputs
# -----------------------------------------------------------------------------
if [[ ! -f "$DIFF_PATH" ]]; then
  log_message "ERROR" "Diff file not found: $DIFF_PATH"
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  log_message "ERROR" "Configuration file not found: $CONFIG_PATH"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log_message "ERROR" "Required command 'jq' not found on PATH."
  exit 1
fi

if ! jq empty "$DIFF_PATH" 2>/dev/null; then
  log_message "ERROR" "Diff file is not valid JSON: $DIFF_PATH"
  exit 1
fi

if ! jq -e '.metadata, .categories' "$DIFF_PATH" >/dev/null 2>&1; then
  log_message "ERROR" "Diff file is missing required 'metadata' or 'categories' blocks. This may not be a valid diff produced by compare-snapshots.sh."
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_PATH"

if [[ -z "${SCHEMA_VERSION:-}" ]]; then
  log_message "ERROR" "Configuration file did not load expected variables. Confirm $CONFIG_PATH is a valid snapshot.conf file."
  exit 1
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR" || { log_message "ERROR" "Failed to create output directory: $OUTPUT_DIR"; exit 1; }
fi

HOSTNAME_VAL=$(jq -r '.metadata.hostname' "$DIFF_PATH")
BASELINE_SNAPSHOT=$(jq -r '.metadata.baseline_snapshot' "$DIFF_PATH")
BASELINE_TS=$(jq -r '.metadata.baseline_timestamp' "$DIFF_PATH")
COMPARE_SNAPSHOT=$(jq -r '.metadata.compare_snapshot' "$DIFF_PATH")
COMPARE_TS=$(jq -r '.metadata.compare_timestamp' "$DIFF_PATH")
REPORT_GENERATED=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
REPORT_DATE=$(date "+%Y-%m-%d")

log_message "INFO" "Classifying drift findings for ${HOSTNAME_VAL}..."

# -----------------------------------------------------------------------------
# Step 3 -- Severity Weight Function
# WHY: Used to determine the highest overall severity across all categories,
# mirroring Get-SeverityWeight in Invoke-DriftReport.ps1.
# -----------------------------------------------------------------------------
severity_weight() {
  case "$1" in
    CRITICAL) echo 3 ;;
    NOTABLE) echo 2 ;;
    INFORMATIONAL) echo 1 ;;
    *) echo 0 ;;
  esac
}

# -----------------------------------------------------------------------------
# Step 4 -- Build Per-Category Findings with Severity
# WHY: jq is used here (rather than another Python subprocess) because the
# severity assignment is a straightforward lookup against Bash variables
# already loaded from snapshot.conf, with one escalation rule for privileged
# group membership -- well suited to jq's --arg-driven templating without
# needing a second language dependency for this stage.
# -----------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

build_category_findings() {
  local category_key="$1"
  local display_name="$2"
  local sev_added="$3"
  local sev_removed="$4"
  local sev_modified="$5"
  local escalation_check="$6"   # "true" for local_users (privileged group escalation), else "false"

  local added_count removed_count modified_count
  added_count=$(jq "[.categories.${category_key}.added // [] | length] | add // 0" "$DIFF_PATH" 2>/dev/null || echo 0)
  removed_count=$(jq "[.categories.${category_key}.removed // [] | length] | add // 0" "$DIFF_PATH" 2>/dev/null || echo 0)
  modified_count=$(jq "[.categories.${category_key}.modified // [] | length] | add // 0" "$DIFF_PATH" 2>/dev/null || echo 0)
  local total=$((added_count + removed_count + modified_count))

  local highest_severity="NONE"

  # Build the findings array for this category as JSON.
  local findings_json="[]"

  if [[ "$added_count" -gt 0 ]]; then
    findings_json=$(jq --argjson existing "$findings_json" --arg sev "$sev_added" \
      '.categories.'"$category_key"'.added // [] | map({change_type: "added", severity: $sev, detail: .}) as $new | $existing + $new' "$DIFF_PATH")
    if [[ $(severity_weight "$sev_added") -gt $(severity_weight "$highest_severity") ]]; then highest_severity="$sev_added"; fi
  fi

  if [[ "$removed_count" -gt 0 ]]; then
    findings_json=$(jq --argjson existing "$findings_json" --arg sev "$sev_removed" \
      '.categories.'"$category_key"'.removed // [] | map({change_type: "removed", severity: $sev, detail: .}) as $new | $existing + $new' "$DIFF_PATH")
    if [[ $(severity_weight "$sev_removed") -gt $(severity_weight "$highest_severity") ]]; then highest_severity="$sev_removed"; fi
  fi

  if [[ "$modified_count" -gt 0 ]]; then
    # WHY: Privileged group escalation rule. Any modification to a
    # local_users entry where group_memberships changes to include a
    # privileged group (wheel, root, sudo) is always classified CRITICAL,
    # mirroring the equivalent escalation rule in Invoke-DriftReport.ps1.
    if [[ "$escalation_check" == "true" ]]; then
      local privileged_pattern
      privileged_pattern=$(printf '%s\n' "${PRIVILEGED_GROUPS[@]}" | paste -sd'|')
      findings_json=$(jq --argjson existing "$findings_json" --arg sev "$sev_modified" --arg pattern "$privileged_pattern" \
        '.categories.'"$category_key"'.modified // [] | map(
          {
            change_type: "modified",
            severity: (
              if (.changed_fields | any(.field == "group_memberships" and (.to | test($pattern))))
              then "CRITICAL"
              else $sev
              end
            ),
            detail: .
          }
        ) as $new | $existing + $new' "$DIFF_PATH")
      if echo "$findings_json" | jq -e 'any(.change_type == "modified" and .severity == "CRITICAL")' >/dev/null 2>&1; then
        highest_severity="CRITICAL"
      elif [[ $(severity_weight "$sev_modified") -gt $(severity_weight "$highest_severity") ]]; then
        highest_severity="$sev_modified"
      fi
    else
      findings_json=$(jq --argjson existing "$findings_json" --arg sev "$sev_modified" \
        '.categories.'"$category_key"'.modified // [] | map({change_type: "modified", severity: $sev, detail: .}) as $new | $existing + $new' "$DIFF_PATH")
      if [[ $(severity_weight "$sev_modified") -gt $(severity_weight "$highest_severity") ]]; then highest_severity="$sev_modified"; fi
    fi
  fi

  jq -n --arg display_name "$display_name" --arg severity "$highest_severity" --arg count "$total" --argjson findings "$findings_json" \
    '{display_name: $display_name, change_count: ($count | tonumber), severity: $severity, findings: $findings}'
}

log_message "INFO" "Building category findings..."

SOFTWARE_FINDINGS=$(build_category_findings "software" "Installed Packages" "$SEVERITY_PACKAGES_ADDED" "$SEVERITY_PACKAGES_REMOVED" "$SEVERITY_PACKAGES_MODIFIED" "false")
SERVICES_FINDINGS=$(build_category_findings "services" "Services" "$SEVERITY_SERVICES_ADDED" "$SEVERITY_SERVICES_REMOVED" "$SEVERITY_SERVICES_MODIFIED" "false")
USERS_FINDINGS=$(build_category_findings "local_users" "Local Users" "$SEVERITY_USERS_ADDED" "$SEVERITY_USERS_REMOVED" "$SEVERITY_USERS_MODIFIED" "true")
FIREWALL_FINDINGS=$(build_category_findings "firewall" "Firewall Rules" "$SEVERITY_FIREWALL_ADDED" "$SEVERITY_FIREWALL_REMOVED" "$SEVERITY_FIREWALL_MODIFIED" "false")
CRON_FINDINGS=$(build_category_findings "scheduled_jobs" "Cron Jobs" "$SEVERITY_CRON_ADDED" "$SEVERITY_CRON_REMOVED" "$SEVERITY_CRON_MODIFIED" "false")
PORTS_FINDINGS=$(build_category_findings "listening_ports" "Listening Ports" "$SEVERITY_PORTS_ADDED" "$SEVERITY_PORTS_REMOVED" "$SEVERITY_PORTS_MODIFIED" "false")
SUDO_FINDINGS=$(build_category_findings "sudo_access" "Sudo Access" "$SEVERITY_SUDO_ADDED" "$SEVERITY_SUDO_REMOVED" "$SEVERITY_SUDO_MODIFIED" "false")

# Wheel group: simple added/removed list, no "modified" concept. Always
# CRITICAL on any change, since wheel membership grants sudo by default.
WHEEL_ADDED_COUNT=$(jq '.categories.wheel_group.added // [] | length' "$DIFF_PATH")
WHEEL_REMOVED_COUNT=$(jq '.categories.wheel_group.removed // [] | length' "$DIFF_PATH")
WHEEL_TOTAL=$((WHEEL_ADDED_COUNT + WHEEL_REMOVED_COUNT))
WHEEL_SEVERITY="NONE"
[[ "$WHEEL_TOTAL" -gt 0 ]] && WHEEL_SEVERITY="CRITICAL"
WHEEL_FINDINGS=$(jq -n --arg sev "$WHEEL_SEVERITY" --argjson count "$WHEEL_TOTAL" \
  '.categories.wheel_group // {added: [], removed: []} | 
   {display_name: "Wheel Group Membership", change_count: $count, severity: $sev,
    findings: ((.added // [] | map({change_type: "added", severity: $sev, detail: .})) +
               (.removed // [] | map({change_type: "removed", severity: $sev, detail: .})))}' "$DIFF_PATH")

# SELinux: single-object diff, always CRITICAL on any change.
SELINUX_CHANGED_COUNT=$(jq '.categories.selinux.changed // [] | length' "$DIFF_PATH")
SELINUX_SEVERITY="NONE"
[[ "$SELINUX_CHANGED_COUNT" -gt 0 ]] && SELINUX_SEVERITY="$SEVERITY_SELINUX_MODIFIED"
SELINUX_FINDINGS=$(jq -n --arg sev "$SELINUX_SEVERITY" --argjson count "$SELINUX_CHANGED_COUNT" \
  '.categories.selinux // {changed: []} |
   {display_name: "SELinux Status", change_count: $count, severity: $sev,
    findings: (.changed // [] | map({change_type: "modified", severity: $sev, detail: .}))}' "$DIFF_PATH")

# Config checksums: dict diff, always CRITICAL on any change.
CHECKSUM_CHANGED_COUNT=$(jq '.categories.config_checksums.changed // [] | length' "$DIFF_PATH")
CHECKSUM_SEVERITY="NONE"
[[ "$CHECKSUM_CHANGED_COUNT" -gt 0 ]] && CHECKSUM_SEVERITY="$SEVERITY_CHECKSUM_CHANGED"
CHECKSUM_FINDINGS=$(jq -n --arg sev "$CHECKSUM_SEVERITY" --argjson count "$CHECKSUM_CHANGED_COUNT" \
  '.categories.config_checksums // {changed: []} |
   {display_name: "Configuration File Checksums", change_count: $count, severity: $sev,
    findings: (.changed // [] | map({change_type: "modified", severity: $sev, detail: .}))}' "$DIFF_PATH")

log_message "INFO" "Category findings built."

# -----------------------------------------------------------------------------
# Step 5 -- Determine Overall Severity
# -----------------------------------------------------------------------------
ALL_SEVERITIES=$(jq -n \
  --argjson software "$SOFTWARE_FINDINGS" \
  --argjson services "$SERVICES_FINDINGS" \
  --argjson users "$USERS_FINDINGS" \
  --argjson firewall "$FIREWALL_FINDINGS" \
  --argjson cron "$CRON_FINDINGS" \
  --argjson ports "$PORTS_FINDINGS" \
  --argjson sudo "$SUDO_FINDINGS" \
  --argjson wheel "$WHEEL_FINDINGS" \
  --argjson selinux "$SELINUX_FINDINGS" \
  --argjson checksums "$CHECKSUM_FINDINGS" \
  '[$software, $services, $users, $firewall, $cron, $ports, $sudo, $wheel, $selinux, $checksums] | map(.severity)')

OVERALL_SEVERITY="NONE"
for sev in CRITICAL NOTABLE INFORMATIONAL; do
  if echo "$ALL_SEVERITIES" | jq -e --arg s "$sev" 'any(. == $s)' >/dev/null 2>&1; then
    OVERALL_SEVERITY="$sev"
    break
  fi
done

log_message "INFO" "Classification complete. Overall severity: ${OVERALL_SEVERITY}"

# -----------------------------------------------------------------------------
# Step 6 -- Assemble JSON Report
# -----------------------------------------------------------------------------
jq -n \
  --arg hostname "$HOSTNAME_VAL" \
  --arg baseline_snapshot "$BASELINE_SNAPSHOT" \
  --arg baseline_ts "$BASELINE_TS" \
  --arg compare_snapshot "$COMPARE_SNAPSHOT" \
  --arg compare_ts "$COMPARE_TS" \
  --arg report_generated "$REPORT_GENERATED" \
  --arg overall_severity "$OVERALL_SEVERITY" \
  --arg script_version "$SCRIPT_VERSION" \
  --argjson software "$SOFTWARE_FINDINGS" \
  --argjson services "$SERVICES_FINDINGS" \
  --argjson users "$USERS_FINDINGS" \
  --argjson firewall "$FIREWALL_FINDINGS" \
  --argjson cron "$CRON_FINDINGS" \
  --argjson ports "$PORTS_FINDINGS" \
  --argjson sudo "$SUDO_FINDINGS" \
  --argjson wheel "$WHEEL_FINDINGS" \
  --argjson selinux "$SELINUX_FINDINGS" \
  --argjson checksums "$CHECKSUM_FINDINGS" \
  '{
    metadata: {
      hostname: $hostname,
      platform: "linux",
      baseline_snapshot: $baseline_snapshot,
      baseline_timestamp: $baseline_ts,
      compare_snapshot: $compare_snapshot,
      compare_timestamp: $compare_ts,
      report_generated: $report_generated,
      overall_severity: $overall_severity,
      script_version: $script_version
    },
    summary: [
      {category: $software.display_name, change_count: $software.change_count, severity: $software.severity},
      {category: $services.display_name, change_count: $services.change_count, severity: $services.severity},
      {category: $users.display_name, change_count: $users.change_count, severity: $users.severity},
      {category: $firewall.display_name, change_count: $firewall.change_count, severity: $firewall.severity},
      {category: $cron.display_name, change_count: $cron.change_count, severity: $cron.severity},
      {category: $ports.display_name, change_count: $ports.change_count, severity: $ports.severity},
      {category: $sudo.display_name, change_count: $sudo.change_count, severity: $sudo.severity},
      {category: $wheel.display_name, change_count: $wheel.change_count, severity: $wheel.severity},
      {category: $selinux.display_name, change_count: $selinux.change_count, severity: $selinux.severity},
      {category: $checksums.display_name, change_count: $checksums.change_count, severity: $checksums.severity}
    ],
    findings: {
      software: $software.findings,
      services: $services.findings,
      local_users: $users.findings,
      firewall: $firewall.findings,
      cron_jobs: $cron.findings,
      listening_ports: $ports.findings,
      sudo_access: $sudo.findings,
      wheel_group: $wheel.findings,
      selinux: $selinux.findings,
      config_checksums: $checksums.findings
    }
  }' > "$WORK_DIR/report.json"

if ! jq empty "$WORK_DIR/report.json" 2>/dev/null; then
  log_message "ERROR" "FATAL: Assembled JSON report is not valid JSON. Aborting before write."
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 7 -- Render Markdown Report
# -----------------------------------------------------------------------------
MD_PATH_TMP="$WORK_DIR/report.md"

{
  echo "# Drift Report — ${HOSTNAME_VAL}"
  echo ""
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Hostname | ${HOSTNAME_VAL} |"
  echo "| Platform | Linux (RHEL 9) |"
  echo "| Baseline Snapshot | ${BASELINE_SNAPSHOT} |"
  echo "| Baseline Timestamp | ${BASELINE_TS} |"
  echo "| Comparison Snapshot | ${COMPARE_SNAPSHOT} |"
  echo "| Comparison Timestamp | ${COMPARE_TS} |"
  echo "| Report Generated | ${REPORT_GENERATED} |"
  echo "| Overall Severity | **${OVERALL_SEVERITY}** |"
  echo ""
  echo "## Summary"
  echo ""
  echo "| Category | Changes | Severity |"
  echo "|---|---|---|"
  jq -r '.summary[] | "| \(.category) | \(.change_count) | \(.severity) |"' "$WORK_DIR/report.json"
  echo ""
  echo "## Detail"
  echo ""

  jq -r '.findings | to_entries[] | .key' "$WORK_DIR/report.json" | while read -r cat_key; do
    finding_count=$(jq --arg k "$cat_key" '.findings[$k] | length' "$WORK_DIR/report.json")
    [[ "$finding_count" -eq 0 ]] && continue

    display_name=$(jq -r --arg k "$cat_key" '
      .summary[] | select(.category != null) | .category' "$WORK_DIR/report.json" | head -1)

    # Resolve display name via the summary array matched against this category's findings
    section_name=$(jq -r --arg k "$cat_key" '
      if $k == "software" then "Installed Packages"
      elif $k == "services" then "Services"
      elif $k == "local_users" then "Local Users"
      elif $k == "firewall" then "Firewall Rules"
      elif $k == "cron_jobs" then "Cron Jobs"
      elif $k == "listening_ports" then "Listening Ports"
      elif $k == "sudo_access" then "Sudo Access"
      elif $k == "wheel_group" then "Wheel Group Membership"
      elif $k == "selinux" then "SELinux Status"
      elif $k == "config_checksums" then "Configuration File Checksums"
      else $k end' "$WORK_DIR/report.json")

    if [[ "$INCLUDE_INFORMATIONAL_CHANGES_IN_DETAIL" != "true" ]]; then
      relevant_count=$(jq --arg k "$cat_key" '[.findings[$k][] | select(.severity != "INFORMATIONAL")] | length' "$WORK_DIR/report.json")
      [[ "$relevant_count" -eq 0 ]] && continue
    fi

    echo "### ${section_name}"
    echo ""

    jq -r --arg k "$cat_key" --arg include_info "$INCLUDE_INFORMATIONAL_CHANGES_IN_DETAIL" '
      .findings[$k][]
      | select($include_info == "true" or .severity != "INFORMATIONAL")
      | if .change_type == "modified" and (.detail.changed_fields != null) then
          "- **[\(.severity)]** Modified **\(.detail.key)**: " +
          ([.detail.changed_fields[] | "\(.field): '"'"'\(.from)'"'"' -> '"'"'\(.to)'"'"'"] | join("; "))
        elif .change_type == "modified" and (.detail.field != null) then
          "- **[\(.severity)]** \(.detail.field) changed: '"'"'\(.detail.from)'"'"' -> '"'"'\(.detail.to)'"'"'"
        elif .change_type == "modified" and (.detail.file != null) then
          "- **[\(.severity)]** Checksum changed for `\(.detail.file)`"
        elif .change_type == "added" then
          "- **[\(.severity)]** Added: `\(.detail | tostring)`"
        elif .change_type == "removed" then
          "- **[\(.severity)]** Removed: `\(.detail | tostring)`"
        else
          "- **[\(.severity)]** \(.detail | tostring)"
        end
    ' "$WORK_DIR/report.json"
    echo ""
  done

  total_findings=$(jq '[.summary[].change_count] | add // 0' "$WORK_DIR/report.json")
  if [[ "$total_findings" -eq 0 ]]; then
    echo "No drift detected. Server state matches the baseline across all monitored categories."
    echo ""
  fi

  echo "## Operational Notes"
  echo ""
  echo "- Review findings using the decision framework in \`docs/drift-interpretation-guide.md\`"
  echo "- CRITICAL findings should be investigated before this report is closed"
  echo "- If all findings are approved as legitimate, consider promoting this snapshot to the new baseline using \`templates/baseline-approval-template.md\`"
  echo ""
  echo "---"
  echo "*Generated by drift-report.sh v${SCRIPT_VERSION}*"
} > "$MD_PATH_TMP"

# -----------------------------------------------------------------------------
# Step 8 -- Write Output Files
# -----------------------------------------------------------------------------
BASE_FILENAME="${HOSTNAME_VAL}_drift-report_${REPORT_DATE}"

if [[ "${GENERATE_MARKDOWN_REPORT}" == "true" ]]; then
  MD_FINAL_PATH="${OUTPUT_DIR}/${BASE_FILENAME}.md"
  if cp "$MD_PATH_TMP" "$MD_FINAL_PATH"; then
    log_message "INFO" "Markdown report written to: ${MD_FINAL_PATH}"
  else
    log_message "ERROR" "Failed to write Markdown report."
    exit 1
  fi
fi

if [[ "${GENERATE_JSON_REPORT}" == "true" ]]; then
  JSON_FINAL_PATH="${OUTPUT_DIR}/${BASE_FILENAME}.json"
  if cp "$WORK_DIR/report.json" "$JSON_FINAL_PATH"; then
    log_message "INFO" "JSON report written to: ${JSON_FINAL_PATH}"
  else
    log_message "ERROR" "Failed to write JSON report."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# Step 9 -- Summary
# -----------------------------------------------------------------------------
TOTAL_FINDINGS=$(jq '[.summary[].change_count] | add // 0' "$WORK_DIR/report.json")
log_message "INFO" "Report generation complete. Total findings: ${TOTAL_FINDINGS}. Overall severity: ${OVERALL_SEVERITY}."

if [[ "$OVERALL_SEVERITY" == "CRITICAL" ]]; then
  log_message "WARN" "CRITICAL severity findings present. Immediate review recommended."
  exit 3
fi

exit 0