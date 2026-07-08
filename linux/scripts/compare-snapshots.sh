#!/usr/bin/env bash
#
# compare-snapshots.sh
#
# SYNOPSIS
#   Compares two Linux configuration snapshots and produces a structured diff.
#
# DESCRIPTION
#   compare-snapshots.sh accepts two snapshot JSON files produced by
#   take-snapshot.sh -- a baseline and a comparison snapshot -- and performs
#   a field-by-field comparison across every captured category. The result
#   is written as a single structured diff JSON file identifying additions,
#   removals, and modifications per category.
#
#   WHY THIS SCRIPT EXISTS:
#   Raw snapshots are only useful in isolation for inventory purposes. The
#   operational value of this toolkit comes from comparing two points in
#   time. This script performs that comparison deterministically and
#   produces output consumed by drift-report.sh. It does not classify
#   severity or render human-readable output -- that separation of concerns
#   keeps this script focused and testable.
#
#   WHY PYTHON 3 IS USED FOR THE COMPARISON LOGIC:
#   jq is well suited to filtering and transforming JSON, but expressing
#   "match two arrays of objects by key, then diff fields on matched pairs"
#   cleanly in jq's functional language becomes difficult to read and
#   maintain. Python 3 is present by default on RHEL 9 and provides clearer,
#   more maintainable comparison logic via its standard json module. This
#   script remains a Bash script overall -- Python is invoked only for the
#   comparison algorithm itself, keeping the toolkit's primary language
#   consistent with the rest of the Linux components.
#
# USAGE
#   compare-snapshots.sh --baseline <path> --compare <path> --output <path> [--config <path>]
#
# OPTIONS
#   --baseline   Path to the baseline (reference) snapshot JSON file. Required.
#   --compare    Path to the comparison snapshot JSON file. Required.
#   --output     Path where the resulting diff JSON file will be written. Required.
#   --config     Path to snapshot.conf. Optional -- only used to resolve
#                PYTHON3_BINARY if set to a non-default value.
#   --help       Display this usage information and exit.
#
# EXAMPLES
#   compare-snapshots.sh --baseline ../snapshots/server01_baseline.json \
#                         --compare ../snapshots/server01_weekly-review.json \
#                         --output ../diff/server01_diff.json
#
# REQUIRES
#   Bash 4.0+, Python 3 (standard on RHEL 9), jq
#
# OUTPUTS
#   A single diff JSON file describing added, removed, and modified entries
#   per category, written to the specified output path.
#
# SCRIPT VERSION: 1.0.0

set -u
set -o pipefail

SCRIPT_VERSION="1.0.0"
PYTHON3_BINARY="python3"

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
BASELINE_PATH=""
COMPARE_PATH=""
OUTPUT_PATH=""
CONFIG_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)
      BASELINE_PATH="$2"
      shift 2
      ;;
    --compare)
      COMPARE_PATH="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
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

if [[ -z "$BASELINE_PATH" || -z "$COMPARE_PATH" || -z "$OUTPUT_PATH" ]]; then
  echo "ERROR: --baseline, --compare, and --output are all required." >&2
  print_usage
  exit 1
fi

# WHY: --config is optional, but if supplied, it should resolve a custom
# Python 3 binary path/name without requiring duplication of the entire
# severity threshold configuration, which this script does not use.
if [[ -n "$CONFIG_PATH" ]]; then
  if [[ -f "$CONFIG_PATH" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_PATH"
  else
    log_message "WARN" "Config path supplied but not found: $CONFIG_PATH. Using default Python 3 binary."
  fi
fi

# -----------------------------------------------------------------------------
# Step 2 -- Validate Inputs
# WHY: Comparison requires two valid, parseable, schema-conformant snapshots.
# Failing fast with a specific error saves the operator diagnostic time
# compared to a generic Python traceback.
# -----------------------------------------------------------------------------
for f in "$BASELINE_PATH" "$COMPARE_PATH"; do
  if [[ ! -f "$f" ]]; then
    log_message "ERROR" "Snapshot file not found: $f"
    exit 1
  fi
done

if ! command -v "$PYTHON3_BINARY" >/dev/null 2>&1; then
  log_message "ERROR" "Required command '$PYTHON3_BINARY' not found on PATH. This script requires Python 3 for comparison logic."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log_message "ERROR" "Required command 'jq' not found on PATH."
  exit 1
fi

if ! jq empty "$BASELINE_PATH" 2>/dev/null; then
  log_message "ERROR" "Baseline snapshot is not valid JSON: $BASELINE_PATH"
  exit 1
fi

if ! jq empty "$COMPARE_PATH" 2>/dev/null; then
  log_message "ERROR" "Comparison snapshot is not valid JSON: $COMPARE_PATH"
  exit 1
fi

if ! jq -e '.metadata' "$BASELINE_PATH" >/dev/null 2>&1; then
  log_message "ERROR" "Baseline snapshot is missing the required 'metadata' block. This may not be a valid snapshot produced by take-snapshot.sh."
  exit 1
fi

if ! jq -e '.metadata' "$COMPARE_PATH" >/dev/null 2>&1; then
  log_message "ERROR" "Comparison snapshot is missing the required 'metadata' block. This may not be a valid snapshot produced by take-snapshot.sh."
  exit 1
fi

BASELINE_SCHEMA=$(jq -r '.metadata.schema_version' "$BASELINE_PATH")
COMPARE_SCHEMA=$(jq -r '.metadata.schema_version' "$COMPARE_PATH")
if [[ "$BASELINE_SCHEMA" != "$COMPARE_SCHEMA" ]]; then
  log_message "WARN" "Schema version mismatch: baseline is '${BASELINE_SCHEMA}', comparison is '${COMPARE_SCHEMA}'. Comparison will proceed but results may be incomplete if category structures differ between schema versions."
fi

BASELINE_HOST=$(jq -r '.metadata.hostname' "$BASELINE_PATH")
COMPARE_HOST=$(jq -r '.metadata.hostname' "$COMPARE_PATH")
if [[ "$BASELINE_HOST" != "$COMPARE_HOST" ]]; then
  log_message "WARN" "Hostname mismatch: baseline is '${BASELINE_HOST}', comparison is '${COMPARE_HOST}'. Comparing snapshots from different hosts is unusual -- confirm this is intentional."
fi

BASELINE_LABEL=$(jq -r '.metadata.snapshot_label' "$BASELINE_PATH")
COMPARE_LABEL=$(jq -r '.metadata.snapshot_label' "$COMPARE_PATH")
BASELINE_TS=$(jq -r '.metadata.snapshot_timestamp' "$BASELINE_PATH")
COMPARE_TS=$(jq -r '.metadata.snapshot_timestamp' "$COMPARE_PATH")

log_message "INFO" "Comparing baseline '${BASELINE_LABEL}' (${BASELINE_TS}) against '${COMPARE_LABEL}' (${COMPARE_TS})"

# -----------------------------------------------------------------------------
# Step 3 -- Output Directory Preparation
# -----------------------------------------------------------------------------
OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR" || { log_message "ERROR" "Failed to create output directory: $OUTPUT_DIR"; exit 1; }
fi

# -----------------------------------------------------------------------------
# Step 4 -- Run Comparison via Python 3
# WHY: The comparison algorithm itself (matching by key field, diffing
# fields on matched pairs, identifying added/removed items) is implemented
# here in Python for clarity and maintainability, as explained in the
# script header. The Python interpreter is invoked as a subprocess from
# Bash, keeping the script's entry point, argument handling, validation,
# and logging in Bash for consistency with the rest of the toolkit.
# -----------------------------------------------------------------------------
log_message "INFO" "Running category comparisons..."

"$PYTHON3_BINARY" - "$BASELINE_PATH" "$COMPARE_PATH" "$OUTPUT_PATH" "$SCRIPT_VERSION" <<'PYTHON_SCRIPT'
import json
import sys
from datetime import datetime, timezone

baseline_path, compare_path, output_path, script_version = sys.argv[1:5]

with open(baseline_path, "r", encoding="utf-8") as f:
    baseline = json.load(f)

with open(compare_path, "r", encoding="utf-8") as f:
    compare = json.load(f)

# Fields excluded from drift comparison because they change on every
# legitimate access/run and would generate false positives. Mirrors the
# exclusion documented in docs/snapshot-methodology.md and implemented
# identically in Compare-ConfigSnapshots.ps1 for cross-platform consistency.
EXCLUDED_FIELDS = {"password_expiry", "last_logon"}


def stringify(value):
    if value is None:
        return ""
    if isinstance(value, list):
        return ",".join(str(v) for v in value)
    return str(value)


def compare_object_list(baseline_list, compare_list, key_field):
    """
    Generic comparator: matches objects in two lists by a key field, then
    identifies additions, removals, and field-level modifications on
    matched pairs. Mirrors Compare-ObjectList in Compare-ConfigSnapshots.ps1
    so that Windows and Linux diffs share identical structure and behaviour.
    """
    baseline_list = baseline_list or []
    compare_list = compare_list or []

    baseline_map = {str(item.get(key_field)): item for item in baseline_list if item.get(key_field) is not None}
    compare_map = {str(item.get(key_field)): item for item in compare_list if item.get(key_field) is not None}

    added = [compare_map[k] for k in compare_map if k not in baseline_map]
    removed = [baseline_map[k] for k in baseline_map if k not in compare_map]

    modified = []
    for k in baseline_map:
        if k not in compare_map:
            continue
        b_item = baseline_map[k]
        c_item = compare_map[k]
        all_fields = set(b_item.keys()) | set(c_item.keys())
        changed_fields = []
        for field in sorted(all_fields):
            if field in EXCLUDED_FIELDS:
                continue
            b_val = stringify(b_item.get(field))
            c_val = stringify(c_item.get(field))
            if b_val != c_val:
                changed_fields.append({"field": field, "from": b_val, "to": c_val})
        if changed_fields:
            modified.append({"key": k, "changed_fields": changed_fields})

    return {"added": added, "removed": removed, "modified": modified}


categories = {}
categories["software"] = compare_object_list(baseline.get("software"), compare.get("software"), "name")
categories["services"] = compare_object_list(baseline.get("services"), compare.get("services"), "name")
categories["local_users"] = compare_object_list(baseline.get("local_users"), compare.get("local_users"), "username")
categories["firewall"] = compare_object_list(
    baseline.get("firewall", {}).get("zones"),
    compare.get("firewall", {}).get("zones"),
    "zone",
)
categories["scheduled_jobs"] = compare_object_list(baseline.get("scheduled_jobs"), compare.get("scheduled_jobs"), "entry")
categories["listening_ports"] = compare_object_list(
    baseline.get("listening_ports"), compare.get("listening_ports"), "local_port"
)

# Platform-specific: sudo access rules, compared by rule text since sudo
# rules have no single natural identifier field.
sudo_baseline = baseline.get("platform_specific", {}).get("sudo_access", {}).get("rules", [])
sudo_compare = compare.get("platform_specific", {}).get("sudo_access", {}).get("rules", [])
categories["sudo_access"] = compare_object_list(sudo_baseline, sudo_compare, "rule")

# Wheel group membership compared as a simple set difference, since it is
# a flat list of usernames rather than a list of objects.
wheel_baseline = set(baseline.get("platform_specific", {}).get("sudo_access", {}).get("wheel_group_members", []) or [])
wheel_compare = set(compare.get("platform_specific", {}).get("sudo_access", {}).get("wheel_group_members", []) or [])
categories["wheel_group"] = {
    "added": sorted(wheel_compare - wheel_baseline),
    "removed": sorted(wheel_baseline - wheel_compare),
}

# SELinux compared as a single-object diff (not a list), since there is
# exactly one SELinux state per host.
selinux_baseline = baseline.get("platform_specific", {}).get("selinux", {}) or {}
selinux_compare = compare.get("platform_specific", {}).get("selinux", {}) or {}
selinux_changed = []
for field in ["enforcement_mode", "policy_name", "policy_config"]:
    b_val = stringify(selinux_baseline.get(field))
    c_val = stringify(selinux_compare.get(field))
    if b_val != c_val:
        selinux_changed.append({"field": field, "from": b_val, "to": c_val})
categories["selinux"] = {"changed": selinux_changed}

# Config checksums compared as a dict diff -- which files changed checksum.
checksums_baseline = baseline.get("config_checksums", {}) or {}
checksums_compare = compare.get("config_checksums", {}) or {}
checksum_changed = []
all_checksum_files = set(checksums_baseline.keys()) | set(checksums_compare.keys())
for fpath in sorted(all_checksum_files):
    b_sum = checksums_baseline.get(fpath, "FILE_NOT_PRESENT_IN_BASELINE")
    c_sum = checksums_compare.get(fpath, "FILE_NOT_PRESENT_IN_COMPARISON")
    if b_sum != c_sum:
        checksum_changed.append({"file": fpath, "from": b_sum, "to": c_sum})
categories["config_checksums"] = {"changed": checksum_changed}

diff = {
    "metadata": {
        "schema_version": "1.0",
        "hostname": baseline.get("metadata", {}).get("hostname"),
        "platform": "linux",
        "baseline_snapshot": baseline_path.split("/")[-1],
        "baseline_timestamp": baseline.get("metadata", {}).get("snapshot_timestamp"),
        "compare_snapshot": compare_path.split("/")[-1],
        "compare_timestamp": compare.get("metadata", {}).get("snapshot_timestamp"),
        "diff_generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "script_version": script_version,
    },
    "categories": categories,
}

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(diff, f, indent=2)

# Print a summary to stdout for the calling Bash script to log.
totals = {"added": 0, "removed": 0, "modified": 0}
for cat_name, cat_data in categories.items():
    if "added" in cat_data:
        totals["added"] += len(cat_data.get("added", []))
        totals["removed"] += len(cat_data.get("removed", []))
        totals["modified"] += len(cat_data.get("modified", []))
    print(
        f"CATEGORY_SUMMARY|{cat_name}|"
        f"{len(cat_data.get('added', []))}|"
        f"{len(cat_data.get('removed', []))}|"
        f"{len(cat_data.get('modified', []))}"
    )

print(f"TOTAL_SUMMARY|{totals['added']}|{totals['removed']}|{totals['modified']}")
PYTHON_SCRIPT

PYTHON_EXIT_CODE=$?

if [[ $PYTHON_EXIT_CODE -ne 0 ]]; then
  log_message "ERROR" "FATAL: Python comparison logic failed with exit code ${PYTHON_EXIT_CODE}."
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 5 -- Validate Output
# -----------------------------------------------------------------------------
if [[ ! -f "$OUTPUT_PATH" ]]; then
  log_message "ERROR" "FATAL: Diff file was not created at expected path: $OUTPUT_PATH"
  exit 1
fi

if ! jq empty "$OUTPUT_PATH" 2>/dev/null; then
  log_message "ERROR" "FATAL: Generated diff file is not valid JSON."
  exit 1
fi

log_message "INFO" "Diff file written successfully to: ${OUTPUT_PATH}"

# -----------------------------------------------------------------------------
# Step 6 -- Summary
# -----------------------------------------------------------------------------
TOTAL_ADDED=$(jq '[.categories[] | .added // [] | length] | add // 0' "$OUTPUT_PATH")
TOTAL_REMOVED=$(jq '[.categories[] | .removed // [] | length] | add // 0' "$OUTPUT_PATH")
TOTAL_MODIFIED=$(jq '[.categories[] | .modified // [] | length] | add // 0' "$OUTPUT_PATH")
TOTAL_CHANGES=$((TOTAL_ADDED + TOTAL_REMOVED + TOTAL_MODIFIED))

log_message "INFO" "Comparison complete. Total changes: ${TOTAL_CHANGES} (added: ${TOTAL_ADDED}, removed: ${TOTAL_REMOVED}, modified: ${TOTAL_MODIFIED})"

if [[ "$TOTAL_CHANGES" -eq 0 ]]; then
  log_message "INFO" "No drift detected. Server state matches baseline."
fi

exit 0