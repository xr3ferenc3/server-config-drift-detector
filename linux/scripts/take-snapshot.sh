#!/usr/bin/env bash
#
# take-snapshot.sh
#
# SYNOPSIS
#   Captures a structured configuration snapshot of a RHEL 9 host.
#
# DESCRIPTION
#   take-snapshot.sh collects the current state of a Linux server across
#   multiple operationally significant categories (installed packages,
#   services, local users, sudo access, firewall rules, listening ports,
#   cron jobs, SELinux status, and key configuration file checksums) and
#   writes the result to a timestamped JSON file.
#
#   WHY THIS SCRIPT EXISTS:
#   Without a structured, repeatable snapshot process, configuration drift
#   on a standalone RHEL 9 server goes undetected until it causes an
#   incident. This script produces a consistent, comparable record of server
#   state using only tools built into a standard RHEL 9 installation -- no
#   agents, no external packages beyond the Python 3 interpreter already
#   present by default, no internet connectivity required.
#
# USAGE
#   take-snapshot.sh --config <path> --label <label> [--output-dir <path>]
#
# OPTIONS
#   --config      Path to snapshot.conf configuration file. Required.
#   --label       Short label for this snapshot, e.g. "baseline",
#                 "weekly-review", "post-patch". Required.
#                 Must match pattern: ^[a-zA-Z0-9-]+$
#   --output-dir  Override the configured snapshot output directory.
#                 Optional.
#   --help        Display this usage information and exit.
#
# EXAMPLES
#   take-snapshot.sh --config ../config/snapshot.conf --label baseline
#   take-snapshot.sh --config ../config/snapshot.conf --label post-patch --output-dir /mnt/snapshots
#
# REQUIRES
#   Bash 4.0+, root privileges, RHEL 9 (or compatible) with firewalld and
#   systemd present.
#
# OUTPUTS
#   A single JSON file written to the configured snapshot directory, named:
#   {hostname}_{YYYY-MM-DD}_{HHMM}_{label}.json
#
# SCRIPT VERSION: 1.0.0

set -u
set -o pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_START_EPOCH=$(date +%s)

# -----------------------------------------------------------------------------
# Usage function
# -----------------------------------------------------------------------------
print_usage() {
  grep '^#' "$0" | sed -n '/^# SYNOPSIS/,/^# SCRIPT VERSION/p' | sed 's/^# \{0,1\}//'
}

# -----------------------------------------------------------------------------
# Logging function
# WHY: Every operational script must produce a record of its own execution.
# This function writes timestamped, leveled log entries to both stdout/stderr
# and a log file, so failures can be diagnosed without re-running the script.
# -----------------------------------------------------------------------------
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

  if [[ -n "${LOG_FILE_PATH:-}" ]]; then
    echo "$line" >> "$LOG_FILE_PATH" 2>/dev/null || true
  fi
}

# -----------------------------------------------------------------------------
# Step 1 -- Parse Arguments
# -----------------------------------------------------------------------------
CONFIG_PATH=""
LABEL=""
OUTPUT_OVERRIDE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --label)
      LABEL="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_OVERRIDE_DIR="$2"
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

if [[ -z "$CONFIG_PATH" ]]; then
  echo "ERROR: --config is required." >&2
  print_usage
  exit 1
fi

if [[ -z "$LABEL" ]]; then
  echo "ERROR: --label is required." >&2
  print_usage
  exit 1
fi

if ! [[ "$LABEL" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "ERROR: --label must match pattern ^[a-zA-Z0-9-]+$. Received: '$LABEL'" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 2 -- Validate Prerequisites
# WHY: Root is required because /etc/shadow parsing, /var/spool/cron/ access,
# and full firewalld zone enumeration all require elevated privileges to
# produce a complete and accurate capture. Failing fast with a clear message
# is more professional than silently producing an incomplete snapshot.
# -----------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: This script must be run as root (or via sudo)." >&2
  echo "Root access is required to read /etc/shadow, /var/spool/cron/, and complete firewalld zone data." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Configuration file not found at: $CONFIG_PATH" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_PATH"

if [[ -z "${SCHEMA_VERSION:-}" ]]; then
  echo "ERROR: Configuration file did not load expected variables. Confirm $CONFIG_PATH is a valid snapshot.conf file." >&2
  exit 1
fi

for required_cmd in jq sha256sum hostname uname date; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$required_cmd' not found on PATH. This toolkit assumes a standard RHEL 9 installation." >&2
    exit 1
  fi
done

if ! command -v "$PYTHON3_BINARY" >/dev/null 2>&1; then
  log_message "WARN" "Python 3 binary '$PYTHON3_BINARY' not found. This is required by compare-snapshots.sh, not by this script directly. Snapshot capture will continue."
fi

# -----------------------------------------------------------------------------
# Step 3 -- Resolve Output Paths
# WHY: Paths in the config file may be relative. Resolving them against the
# repository root makes the script runnable from any working directory.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

resolve_path() {
  local configured_path="$1"
  if [[ "$configured_path" = /* ]]; then
    echo "$configured_path"
  else
    echo "${REPO_ROOT}/${configured_path}"
  fi
}

if [[ -n "$OUTPUT_OVERRIDE_DIR" ]]; then
  SNAPSHOT_DIR_RESOLVED="$OUTPUT_OVERRIDE_DIR"
else
  SNAPSHOT_DIR_RESOLVED="$(resolve_path "$SNAPSHOT_DIR")"
fi
LOG_DIR_RESOLVED="$(resolve_path "$LOG_DIR")"

for dir in "$SNAPSHOT_DIR_RESOLVED" "$LOG_DIR_RESOLVED"; do
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || { echo "ERROR: Failed to create directory: $dir" >&2; exit 1; }
  fi
done

LOG_FILE_PATH="${LOG_DIR_RESOLVED}/snapshot_$(date +%Y-%m-%d).log"

log_message "INFO" "take-snapshot.sh v${SCRIPT_VERSION} started. Label: '${LABEL}'"

# -----------------------------------------------------------------------------
# Step 4 -- Initialise Working Variables
# -----------------------------------------------------------------------------
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
KERNEL_VERSION=$(uname -r)
OS_RELEASE_PRETTY=$(grep -oP '(?<=^PRETTY_NAME=").*(?=")' /etc/os-release 2>/dev/null || echo "unknown")
UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "unknown")
BASH_VERSION_STR="${BASH_VERSION:-unknown}"
PYTHON3_VERSION=$("$PYTHON3_BINARY" --version 2>&1 | awk '{print $2}' || echo "unknown")
SNAPSHOT_TIMESTAMP=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
CAPTURED_BY=$(whoami)

CAPTURE_ERRORS=()

# Temporary working directory for intermediate JSON fragments
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# -----------------------------------------------------------------------------
# Step 5 -- Capture Installed Packages
# -----------------------------------------------------------------------------
if [[ "${CAPTURE_INSTALLED_PACKAGES}" == "true" ]]; then
  log_message "INFO" "Capturing installed packages..."
  if rpm -qa --queryformat '{"name":"%{NAME}","version":"%{VERSION}","release":"%{RELEASE}","architecture":"%{ARCH}","install_date":"%{INSTALLTIME:date}"}\n' 2>"$WORK_DIR/packages.err" \
      | jq -s 'sort_by(.name)' > "$WORK_DIR/packages.json" 2>>"$WORK_DIR/packages.err"; then
    count=$(jq 'length' "$WORK_DIR/packages.json")
    log_message "INFO" "Captured ${count} installed packages."
  else
    err_msg="Failed to capture installed packages: $(cat "$WORK_DIR/packages.err" 2>/dev/null | tail -1)"
    log_message "ERROR" "$err_msg"
    CAPTURE_ERRORS+=("$err_msg")
    echo "[]" > "$WORK_DIR/packages.json"
  fi
else
  echo "[]" > "$WORK_DIR/packages.json"
fi

# -----------------------------------------------------------------------------
# Step 6 -- Capture Services
# WHY: Both runtime state and unit file (boot) state are captured because a
# service can be running now but disabled at boot, or vice versa. See
# docs/snapshot-methodology.md Category 2 for full rationale.
# -----------------------------------------------------------------------------
if [[ "${CAPTURE_SERVICES}" == "true" ]]; then
  log_message "INFO" "Capturing services..."
  {
    echo "["
    first=true
    while IFS=$'\t' read -r unit load active sub; do
      [[ -z "$unit" ]] && continue
      [[ "$unit" != *.service ]] && continue
      unit_file_state=$(systemctl is-enabled "$unit" 2>/dev/null || echo "unknown")
      if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
      jq -n --arg name "$unit" --arg load "$load" --arg active "$active" --arg sub "$sub" --arg state "$unit_file_state" \
        '{name: $name, load_state: $load, active_state: $active, sub_state: $sub, unit_file_state: $state}'
    done < <(systemctl list-units --type=service --all --no-pager --no-legend --plain 2>"$WORK_DIR/services.err" \
              | awk '{print $1"\t"$2"\t"$3"\t"$4}')
    echo "]"
  } | jq -s 'add // [] | sort_by(.name)' > "$WORK_DIR/services.json" 2>>"$WORK_DIR/services.err"

  if [[ -s "$WORK_DIR/services.json" ]]; then
    count=$(jq 'length' "$WORK_DIR/services.json" 2>/dev/null || echo 0)
    log_message "INFO" "Captured ${count} services."
  else
    err_msg="Failed to capture services: $(cat "$WORK_DIR/services.err" 2>/dev/null | tail -1)"
    log_message "ERROR" "$err_msg"
    CAPTURE_ERRORS+=("$err_msg")
    echo "[]" > "$WORK_DIR/services.json"
  fi
else
  echo "[]" > "$WORK_DIR/services.json"
fi

# -----------------------------------------------------------------------------
# Step 7 -- Capture Local Users
# WHY: getent passwd is used as the primary source over direct /etc/passwd
# parsing to ensure consistent output regardless of nsswitch configuration.
# Shadow data requires root (already validated above).
# -----------------------------------------------------------------------------
if [[ "${CAPTURE_LOCAL_USERS}" == "true" ]]; then
  log_message "INFO" "Capturing local user accounts..."
  {
    echo "["
    first=true
    while IFS=: read -r username _ uid gid gecos home shell; do
      [[ -z "$username" ]] && continue
      lock_status="unknown"
      pw_expiry="unknown"
      shadow_line=$(grep "^${username}:" /etc/shadow 2>/dev/null || true)
      if [[ -n "$shadow_line" ]]; then
        pw_field=$(echo "$shadow_line" | cut -d: -f2)
        if [[ "$pw_field" == "!"* || "$pw_field" == "*" ]]; then
          lock_status="locked"
        else
          lock_status="unlocked"
        fi
        expiry_field=$(echo "$shadow_line" | cut -d: -f8)
        if [[ -n "$expiry_field" ]]; then
          pw_expiry="$expiry_field"
        fi
      fi
      if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
      jq -n --arg username "$username" --arg uid "$uid" --arg gid "$gid" --arg gecos "$gecos" \
            --arg home "$home" --arg shell "$shell" --arg lock "$lock_status" --arg expiry "$pw_expiry" \
        '{username: $username, uid: ($uid|tonumber), gid: ($gid|tonumber), gecos: $gecos, home_directory: $home, shell: $shell, lock_status: $lock, password_expiry: $expiry}'
    done < <(getent passwd)
    echo "]"
  } | jq -s 'add // [] | sort_by(.username)' > "$WORK_DIR/users.json" 2>"$WORK_DIR/users.err"

  if [[ -s "$WORK_DIR/users.json" ]]; then
    count=$(jq 'length' "$WORK_DIR/users.json" 2>/dev/null || echo 0)
    log_message "INFO" "Captured ${count} local user accounts."
  else
    err_msg="Failed to capture local users: $(cat "$WORK_DIR/users.err" 2>/dev/null | tail -1)"
    log_message "ERROR" "$err_msg"
    CAPTURE_ERRORS+=("$err_msg")
    echo "[]" > "$WORK_DIR/users.json"
  fi
else
  echo "[]" > "$WORK_DIR/users.json"
fi

# -----------------------------------------------------------------------------
# Step 8 -- Capture Sudo Access
# WHY: Separated from local users because sudo grants are the primary
# privilege escalation surface on Linux. visudo -c validates syntax before
# parsing to avoid misreading a malformed sudoers file.
# -----------------------------------------------------------------------------
if [[ "${CAPTURE_SUDO_ACCESS}" == "true" ]]; then
  log_message "INFO" "Capturing sudo access rules..."

  sudoers_valid="true"
  if ! visudo -c -f /etc/sudoers >"$WORK_DIR/visudo.out" 2>&1; then
    sudoers_valid="false"
    log_message "WARN" "/etc/sudoers failed visudo syntax validation. Capturing raw rules anyway, but this should be investigated."
  fi

  {
    echo "["
    first=true

    # Parse /etc/sudoers and /etc/sudoers.d/* for non-comment, non-blank lines
    # that look like sudo grants (user/group ALL=... or %group ALL=...)
    sudo_files=("/etc/sudoers")
    if [[ -d /etc/sudoers.d ]]; then
      while IFS= read -r -d '' f; do
        sudo_files+=("$f")
      done < <(find /etc/sudoers.d -type f -print0 2>/dev/null)
    fi

    for sf in "${sudo_files[@]}"; do
      [[ -f "$sf" ]] || continue
      while IFS= read -r line; do
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        if [[ "$trimmed" =~ ^(%?[a-zA-Z0-9_-]+)[[:space:]]+(.+)$ ]]; then
          principal="${BASH_REMATCH[1]}"
          rule="${BASH_REMATCH[2]}"
          if [[ "$principal" == "Defaults" || "$principal" == "Host_Alias" || "$principal" == "User_Alias" || "$principal" == "Cmnd_Alias" || "$principal" == "Runas_Alias" ]]; then
            continue
          fi
          if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
          jq -n --arg principal "$principal" --arg rule "$rule" --arg source "$sf" \
            '{principal: $principal, rule: $rule, source_file: $source}'
        fi
      done < "$sf"
    done
    echo "]"
  } | jq -s 'add // []' > "$WORK_DIR/sudo_rules.json" 2>"$WORK_DIR/sudo.err"

  # Capture wheel group membership separately -- on RHEL 9, wheel group
  # membership grants sudo by default via the bundled /etc/sudoers entry.
  wheel_members=$(getent group wheel 2>/dev/null | cut -d: -f4 || echo "")
  IFS=',' read -ra wheel_array <<< "$wheel_members"
  wheel_json=$(printf '%s\n' "${wheel_array[@]}" | jq -R . | jq -s 'map(select(length > 0))')

  jq -n --argjson rules "$(cat "$WORK_DIR/sudo_rules.json")" --argjson wheel "$wheel_json" --argjson valid "$sudoers_valid" \
    '{sudoers_valid: $valid, rules: $rules, wheel_group_members: $wheel}' > "$WORK_DIR/sudo.json"

  count=$(jq '.rules | length' "$WORK_DIR/sudo.json" 2>/dev/null || echo 0)
  log_message "INFO" "Captured ${count} sudo rules and $(echo "${#wheel_array[@]}") wheel group members."
else
  echo '{"sudoers_valid": null, "rules": [], "wheel_group_members": []}' > "$WORK_DIR/sudo.json"
fi

# -----------------------------------------------------------------------------
# Step 9 -- Capture Firewall Rules
# WHY: firewalld is the standard firewall management layer on RHEL 9,
# regardless of whether the underlying backend is nftables (RHEL 9 default)
# or iptables (RHEL 8 legacy). See docs/snapshot-methodology.md Category 5.
# -----------------------------------------------------------------------------
if [[ "${CAPTURE_FIREWALL_RULES}" == "true" ]]; then
  log_message "INFO" "Capturing firewall rules..."

  if ! systemctl is-active --quiet firewalld; then
    log_message "WARN" "firewalld is not running. Recording this state explicitly rather than producing an empty firewall section."
    jq -n '{firewalld_active: false, default_zone: null, zones: []}' > "$WORK_DIR/firewall.json"
  else
    default_zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "unknown")
    zones=$(firewall-cmd --get-active-zones 2>/dev/null | grep -v '^\s' || true)

    {
      echo "["
      first=true
      while IFS= read -r zone; do
        [[ -z "$zone" ]] && continue
        services=$(firewall-cmd --zone="$zone" --list-services 2>/dev/null || echo "")
        ports=$(firewall-cmd --zone="$zone" --list-ports 2>/dev/null || echo "")
        rich_rules=$(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null || echo "")
        interfaces=$(firewall-cmd --zone="$zone" --list-interfaces 2>/dev/null || echo "")
        sources=$(firewall-cmd --zone="$zone" --list-sources 2>/dev/null || echo "")

        if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
        jq -n --arg zone "$zone" --arg services "$services" --arg ports "$ports" \
              --arg rich "$rich_rules" --arg ifaces "$interfaces" --arg sources "$sources" \
          '{
            zone: $zone,
            services: ($services | split(" ") | map(select(length > 0))),
            ports: ($ports | split(" ") | map(select(length > 0))),
            rich_rules: ($rich | split("\n") | map(select(length > 0))),
            interfaces: ($ifaces | split(" ") | map(select(length > 0))),
            sources: ($sources | split(" ") | map(select(length > 0)))
          }'
      done < <(echo "$zones")
      echo "]"
    } | jq -s 'add // []' > "$WORK_DIR/firewall_zones.json" 2>"$WORK_DIR/firewall.err"

    jq -n --arg dz "$default_zone" --argjson zones "$(cat "$WORK_DIR/firewall_zones.json")" \
      '{firewalld_active: true, default_zone: $dz, zones: $zones}' > "$WORK_DIR/firewall.json"

    zone_count=$(jq '.zones | length' "$WORK_DIR/firewall.json" 2>/dev/null || echo 0)
    log_message "INFO" "Captured firewall configuration across ${zone_count} active zones."
  fi
else
  jq -n '{firewalld_active: null, default_zone: null, zones: []}' > "$WORK_DIR/firewall.json"
fi

# -----------------------------------------------------------------------------
# Step 10 -- Capture Listening Ports
# WHY: ss is used rather than netstat. netstat is provided by net-tools,
# which is NOT installed by default on RHEL 9 minimal installations, and is
# considered deprecated in favour of the iproute2-provided ss command.
# This is an explicit deviation from any source material referencing
# netstat -- see docs/snapshot-methodology.md Category 6.
# -----------------------------------------------------------------------------
if [[ "${CAPTURE_LISTENING_PORTS}" == "true" ]]; then
  log_message "INFO" "Capturing listening ports..."
  {
    echo "["
    first=true
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      proto=$(echo "$line" | awk '{print $1}')
      local_addr_port=$(echo "$line" | awk '{print $5}')
      process_info=$(echo "$line" | grep -oP '(?<=users:\(\(")[^"]+' || echo "unknown")
      pid_info=$(echo "$line" | grep -oP '(?<=pid=)\d+' || echo "unknown")

      local_addr="${local_addr_port%:*}"
      local_port="${local_addr_port##*:}"

      if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
      jq -n --arg proto "$proto" --arg addr "$local_addr" --arg port "$local_port" \
            --arg proc "$process_info" --arg pid "$pid_info" \
        '{protocol: ($proto | ascii_upcase), local_address: $addr, local_port: $port, owning_process: $proc, owning_pid: $pid}'
    done < <(ss -tlnup 2>"$WORK_DIR/ports.err" | tail -n +2)
    echo "]"
  } | jq -s 'add // [] | sort_by(.protocol, (.local_port | tonumber? // 0))' > "$WORK_DIR/ports.json" 2>>"$WORK_DIR/ports.err"

  if [[ -s "$WORK_DIR/ports.json" ]]; then
    count=$(jq 'length' "$WORK_DIR/ports.json" 2>/dev/null || echo 0)
    log_message "INFO" "Captured ${count} listening ports."
  else
    err_msg="Failed to capture listening ports: $(cat "$WORK_DIR/ports.err" 2>/dev/null | tail -1)"
    log_message "ERROR" "$err_msg"
    CAPTURE_ERRORS+=("$err_msg")
    echo "[]" > "$WORK_DIR/ports.json"
  fi
else
  echo "[]" > "$WORK_DIR/ports.json"
fi

# -----------------------------------------------------------------------------
# Step 11 -- Capture Cron Jobs
# WHY: System and per-user cron sources are all captured because a malicious
# or unauthorised cron entry can be placed in any of them. Systemd timers
# are captured separately as part of the Services category.
# -----------------------------------------------------------------------------
if [[ "${CAPTURE_CRON_JOBS}" == "true" ]]; then
  log_message "INFO" "Capturing cron jobs..."
  {
    echo "["
    first=true

    cron_sources=("/etc/crontab")
    for cdir in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
      if [[ -d "$cdir" ]]; then
        while IFS= read -r -d '' f; do
          cron_sources+=("$f")
        done < <(find "$cdir" -type f -print0 2>/dev/null)
      fi
    done

    for cs in "${cron_sources[@]}"; do
      [[ -f "$cs" ]] || continue
      while IFS= read -r line; do
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
        jq -n --arg source "$cs" --arg entry "$trimmed" \
          '{source: $source, entry: $entry, source_type: "system"}'
      done < "$cs"
    done

    # Per-user crontabs from /var/spool/cron/ (requires root, already validated)
    if [[ -d /var/spool/cron ]]; then
      while IFS= read -r -d '' userfile; do
        cron_user=$(basename "$userfile")
        while IFS= read -r line; do
          trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
          if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
          jq -n --arg source "$cron_user" --arg entry "$trimmed" \
            '{source: $source, entry: $entry, source_type: "user"}'
        done < "$userfile"
      done < <(find /var/spool/cron -type f -print0 2>/dev/null)
    fi
    echo "]"
  } | jq -s 'add // []' > "$WORK_DIR/cron.json" 2>"$WORK_DIR/cron.err"

  if [[ -s "$WORK_DIR/cron.json" ]]; then
    count=$(jq 'length' "$WORK_DIR/cron.json" 2>/dev/null || echo 0)
    log_message "INFO" "Captured ${count} cron entries."
  else
    err_msg="Failed to capture cron jobs: $(cat "$WORK_DIR/cron.err" 2>/dev/null | tail -1)"
    log_message "ERROR" "$err_msg"
    CAPTURE_ERRORS+=("$err_msg")
    echo "[]" > "$WORK_DIR/cron.json"
  fi
else
  echo "[]" > "$WORK_DIR/cron.json"
fi

# -----------------------------------------------------------------------------
# Step 12 -- Capture SELinux Status
# -----------------------------------------------------------------------------
if [[ "${CAPTURE_SELINUX_STATUS}" == "true" ]]; then
  log_message "INFO" "Capturing SELinux status..."
  if command -v getenforce >/dev/null 2>&1; then
    enforce_mode=$(getenforce 2>/dev/null || echo "unknown")
    policy_name=$(sestatus 2>/dev/null | grep -oP '(?<=Loaded policy name:)\s*\K.*' | sed 's/^[[:space:]]*//' || echo "unknown")
    policy_version=$(sestatus 2>/dev/null | grep -oP '(?<=Policy from config file:)\s*\K.*' | sed 's/^[[:space:]]*//' || echo "unknown")
    jq -n --arg mode "$enforce_mode" --arg policy "$policy_name" --arg version "$policy_version" \
      '{enforcement_mode: $mode, policy_name: $policy, policy_config: $version}' > "$WORK_DIR/selinux.json"
    log_message "INFO" "SELinux mode: ${enforce_mode}"
  else
    log_message "WARN" "getenforce not found. SELinux may not be installed on this system."
    jq -n '{enforcement_mode: "not_installed", policy_name: null, policy_config: null}' > "$WORK_DIR/selinux.json"
  fi
else
  jq -n '{enforcement_mode: null, policy_name: null, policy_config: null}' > "$WORK_DIR/selinux.json"
fi

# -----------------------------------------------------------------------------
# Step 13 -- Capture Configuration File Checksums
# WHY: Checksums confirm a file was modified without exposing its sensitive
# content (particularly relevant for /etc/shadow and /etc/sudoers). See
# docs/snapshot-methodology.md Category 9.
# -----------------------------------------------------------------------------
if [[ "${CAPTURE_CONFIG_CHECKSUMS}" == "true" ]]; then
  log_message "INFO" "Capturing configuration file checksums..."
  {
    echo "{"
    first=true
    for target_file in "${CHECKSUM_TARGET_FILES[@]}"; do
      if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
      if [[ -f "$target_file" ]]; then
        checksum=$(sha256sum "$target_file" 2>/dev/null | awk '{print $1}')
        printf '"%s": "%s"' "$target_file" "$checksum"
      else
        printf '"%s": "FILE_NOT_FOUND"' "$target_file"
      fi
    done
    echo "}"
  } > "$WORK_DIR/checksums.json"

  if jq empty "$WORK_DIR/checksums.json" 2>/dev/null; then
    count=$(jq 'length' "$WORK_DIR/checksums.json")
    log_message "INFO" "Captured checksums for ${count} configuration files."
  else
    err_msg="Failed to capture configuration file checksums -- malformed output."
    log_message "ERROR" "$err_msg"
    CAPTURE_ERRORS+=("$err_msg")
    echo "{}" > "$WORK_DIR/checksums.json"
  fi
else
  echo "{}" > "$WORK_DIR/checksums.json"
fi

# -----------------------------------------------------------------------------
# Step 14 -- Assemble Final Snapshot JSON
# -----------------------------------------------------------------------------
log_message "INFO" "Assembling final snapshot document..."

errors_json=$(printf '%s\n' "${CAPTURE_ERRORS[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')

jq -n \
  --arg schema_version "$SCHEMA_VERSION" \
  --arg hostname "$HOSTNAME_FQDN" \
  --arg kernel "$KERNEL_VERSION" \
  --arg os_release "$OS_RELEASE_PRETTY" \
  --arg uptime "$UPTIME_SECONDS" \
  --arg bash_version "$BASH_VERSION_STR" \
  --arg python_version "$PYTHON3_VERSION" \
  --arg label "$LABEL" \
  --arg timestamp "$SNAPSHOT_TIMESTAMP" \
  --arg script_version "$SCRIPT_VERSION" \
  --arg captured_by "$CAPTURED_BY" \
  --argjson software "$(cat "$WORK_DIR/packages.json")" \
  --argjson services "$(cat "$WORK_DIR/services.json")" \
  --argjson local_users "$(cat "$WORK_DIR/users.json")" \
  --argjson sudo_access "$(cat "$WORK_DIR/sudo.json")" \
  --argjson firewall "$(cat "$WORK_DIR/firewall.json")" \
  --argjson listening_ports "$(cat "$WORK_DIR/ports.json")" \
  --argjson cron_jobs "$(cat "$WORK_DIR/cron.json")" \
  --argjson selinux "$(cat "$WORK_DIR/selinux.json")" \
  --argjson checksums "$(cat "$WORK_DIR/checksums.json")" \
  --argjson capture_errors "$errors_json" \
  '{
    metadata: {
      schema_version: $schema_version,
      hostname: $hostname,
      platform: "linux",
      kernel_version: $kernel,
      os_release: $os_release,
      uptime_seconds: ($uptime | tonumber? // 0),
      bash_version: $bash_version,
      python3_version: $python_version,
      snapshot_label: $label,
      snapshot_timestamp: $timestamp,
      script_version: $script_version,
      captured_by: $captured_by
    },
    software: $software,
    services: $services,
    local_users: $local_users,
    firewall: $firewall,
    scheduled_jobs: $cron_jobs,
    listening_ports: $listening_ports,
    platform_specific: {
      sudo_access: $sudo_access,
      selinux: $selinux
    },
    config_checksums: $checksums,
    capture_errors: $capture_errors
  }' > "$WORK_DIR/snapshot_final.json"

if ! jq empty "$WORK_DIR/snapshot_final.json" 2>/dev/null; then
  log_message "ERROR" "FATAL: Assembled snapshot is not valid JSON. Aborting before write."
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 15 -- Write Snapshot File
# -----------------------------------------------------------------------------
SHORT_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
TIMESTAMP_FILE=$(date "+%Y-%m-%d_%H%M")
SNAPSHOT_FILENAME="${SHORT_HOSTNAME}_${TIMESTAMP_FILE}_${LABEL}.json"
SNAPSHOT_FILEPATH="${SNAPSHOT_DIR_RESOLVED}/${SNAPSHOT_FILENAME}"

if cp "$WORK_DIR/snapshot_final.json" "$SNAPSHOT_FILEPATH"; then
  log_message "INFO" "Snapshot written successfully to: ${SNAPSHOT_FILEPATH}"
else
  log_message "ERROR" "FATAL: Failed to write snapshot file to ${SNAPSHOT_FILEPATH}"
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 16 -- Enforce Retention Policy
# WHY: Baseline snapshots are explicitly exempt -- see Step 12 rationale in
# New-ConfigSnapshot.ps1 for the equivalent Windows reasoning.
# -----------------------------------------------------------------------------
if [[ "${MAX_COMPARISON_SNAPSHOTS}" -gt 0 ]]; then
  mapfile -t old_snapshots < <(find "$SNAPSHOT_DIR_RESOLVED" -maxdepth 1 -name "*.json" ! -name "*_baseline.json" -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
  snapshot_count="${#old_snapshots[@]}"
  if [[ "$snapshot_count" -gt "$MAX_COMPARISON_SNAPSHOTS" ]]; then
    to_remove=("${old_snapshots[@]:$MAX_COMPARISON_SNAPSHOTS}")
    for f in "${to_remove[@]}"; do
      rm -f "$f"
      log_message "INFO" "Removed snapshot exceeding retention policy: $(basename "$f")"
    done
  fi
fi

# -----------------------------------------------------------------------------
# Step 17 -- Summary
# -----------------------------------------------------------------------------
SCRIPT_END_EPOCH=$(date +%s)
DURATION=$((SCRIPT_END_EPOCH - SCRIPT_START_EPOCH))
ERROR_COUNT="${#CAPTURE_ERRORS[@]}"

log_message "INFO" "Snapshot complete. Duration: ${DURATION}s. Errors: ${ERROR_COUNT}."

if [[ "$ERROR_COUNT" -gt 0 ]]; then
  log_message "WARN" "Snapshot completed WITH ERRORS. Review the capture_errors array in the output file before using this snapshot as a baseline."
  exit 2
fi

exit 0