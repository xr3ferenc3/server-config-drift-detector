
# server-config-drift-detector

Lightweight configuration snapshot and drift detection for Windows Server 2022 and RHEL 9.
No agents. No enterprise tools. No cloud dependency.

---

## What This Is

**server-config-drift-detector** captures structured snapshots of server configuration state and compares them over time to detect, report, and track configuration drift.

A snapshot records what a server looks like at a specific point in time - its services, users, firewall rules, installed software, scheduled tasks, listening ports, and more. When a later snapshot is compared against a baseline, any difference is a drift event: something changed. That change may be expected, may be undocumented, or may be a security concern. This toolkit surfaces it clearly so an operator can decide what to do.

This is not a monitoring tool. It does not watch systems in real time.
This is a change detection tool. It answers the question: *what is different from what we approved?*

---

## Why This Exists

In environments without enterprise configuration management - no SCCM, no Ansible, no Puppet, no Chef - servers change silently. A service gets disabled during a failed update. A firewall rule is added by a developer. A user account appears with no corresponding ticket. A scheduled task is modified and nobody documented it.

These changes are invisible until something breaks.

By the time an incident occurs, there is no baseline to compare against. The team is left asking what changed, when it changed, and who changed it - without answers.

This toolkit solves that problem using only the tools already present on Windows Server 2022 and RHEL 9. No additional software is required. No agents are installed. No data leaves the server unless the operator explicitly moves it.

---

## Who This Is For

- Sysadmins managing Windows Server 2022 or RHEL 9 systems without enterprise configuration management
- Small-to-medium IT teams who need auditable change detection without enterprise tooling budget
- Operations teams preparing for audits who need documented evidence of configuration stability
- Incident responders who need to determine what changed on a system before or during an incident

---

## What It Captures

### Windows Server 2022

| Category | Data Collected |
|---|---|
| Installed Software | Name, version, publisher, install date |
| Services | Name, display name, status, start type |
| Local Users | Name, enabled status, last logon, group membership |
| Firewall Rules | Name, enabled state, direction, action, profile |
| Scheduled Tasks | Name, state, last run time, next run time, run-as account |
| Listening Ports | Protocol, local address, port, owning process |
| Pending Updates | Update title, KB article, severity |
| System Metadata | Hostname, OS version, uptime, snapshot timestamp |

### RHEL 9 / Linux

| Category | Data Collected |
|---|---|
| Installed Packages | Name, version, architecture, install date |
| Services | Name, load state, active state, sub-state |
| Local Users | Username, UID, GID, shell, home directory |
| Sudo Access | User and group sudo rules across sudoers.d |
| Firewall Rules | firewalld zones, services, ports, rich rules |
| Listening Ports | Protocol, local address, port, process name, PID |
| Cron Jobs | System and user crontab entries |
| SELinux | Mode, policy, enforcement status |
| Config File Checksums | SHA-256 checksums of key system files |
| System Metadata | Hostname, kernel version, OS release, snapshot timestamp |

---

## How It Works

```
1. Establish baseline
   Run the snapshot script on a known-good, approved server state.
   The snapshot is saved as a timestamped JSON file.

2. Schedule ongoing snapshots
   Configure the included scheduled task (Windows) or systemd timer (Linux)
   to capture snapshots automatically on a defined interval.

3. Compare snapshots
   Run the comparison script with a baseline and a later snapshot as input.
   The comparison script produces a structured diff.

4. Generate drift report
   Run the report script against the comparison output.
   A Markdown report and JSON report are produced.

5. Review and act
   Consult the drift-interpretation-guide to classify each change.
   Use the drift-response-checklist to work through the findings.
   Attach the report to the relevant ticket or change record.
```

---

## Repository Structure

```
server-config-drift-detector/
│
├── README.md                          # This file
├── CHANGELOG.md                       # Version history
├── LICENSE                            # MIT License
├── .gitignore                         # Excludes snapshot output and OS artifacts
│
├── docs/
│   ├── architecture-overview.md       # How all components fit together
│   ├── threat-model.md                # What this protects, what it does not
│   ├── operational-guide.md           # How to install, run, and use this toolkit
│   ├── snapshot-methodology.md        # What is captured and why
│   ├── drift-interpretation-guide.md  # How to read and act on drift reports
│   ├── troubleshooting.md             # Known failure modes and resolution
│   ├── security-considerations.md     # Snapshot security and access control
│   └── command-reference.md           # All script parameters at a glance
│
├── windows/
│   ├── scripts/
│   │   ├── New-ConfigSnapshot.ps1     # Captures Windows server state to JSON
│   │   ├── Compare-ConfigSnapshots.ps1 # Compares two snapshots, outputs diff
│   │   └── Invoke-DriftReport.ps1    # Generates Markdown and JSON drift report
│   ├── config/
│   │   └── snapshot-config.json      # Operator-controlled configuration
│   └── scheduled-task/
│       ├── Register-SnapshotTask.ps1  # Creates the Windows scheduled task
│       └── snapshot-task-definition.xml # Raw XML task definition for audit
│
├── linux/
│   ├── scripts/
│   │   ├── take-snapshot.sh           # Captures Linux server state to JSON
│   │   ├── compare-snapshots.sh       # Compares two snapshots, outputs diff
│   │   └── drift-report.sh           # Generates Markdown and JSON drift report
│   ├── config/
│   │   └── snapshot.conf             # Operator-controlled configuration
│   └── systemd/
│       ├── snapshot.service           # systemd service unit for snapshot execution
│       └── snapshot.timer            # systemd timer unit for scheduling
│
├── checklists/
│   ├── baseline-snapshot-checklist.md # Steps for establishing a valid baseline
│   ├── drift-response-checklist.md   # Steps for responding to drift findings
│   └── weekly-review-checklist.md    # Steps for the scheduled weekly review
│
├── samples/
│   ├── windows/
│   │   ├── sample-snapshot-windows.json       # Example Windows snapshot output
│   │   ├── sample-drift-report-windows.md     # Example Windows drift report
│   │   └── sample-drift-report-windows.json   # Example Windows drift report (JSON)
│   └── linux/
│       ├── sample-snapshot-linux.json         # Example Linux snapshot output
│       ├── sample-drift-report-linux.md       # Example Linux drift report
│       └── sample-drift-report-linux.json     # Example Linux drift report (JSON)
│
└── templates/
    ├── drift-ticket-template.md        # Ticket template for drift findings
    └── baseline-approval-template.md  # Approval record for accepted baselines
```

---

## Quick Start

### Windows Server 2022

**Requirements:** PowerShell 5.1 or later, run as Administrator.

```powershell
# 1. Clone the repository
git clone https://github.com/YOUR-USERNAME/server-config-drift-detector.git
cd server-config-drift-detector

# 2. Review and edit the configuration file
notepad windows\config\snapshot-config.json

# 3. Capture a baseline snapshot
powershell -ExecutionPolicy Bypass -File windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath windows\config\snapshot-config.json -Label "baseline"

# 4. After changes have occurred, capture a comparison snapshot
powershell -ExecutionPolicy Bypass -File windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath windows\config\snapshot-config.json -Label "weekly-review"

# 5. Compare the two snapshots
powershell -ExecutionPolicy Bypass -File windows\scripts\Compare-ConfigSnapshots.ps1 -BaselineSnapshot "path\to\baseline-snapshot.json" -CompareSnapshot "path\to\weekly-review-snapshot.json" -OutputPath "path\to\diff-output.json"

# 6. Generate the drift report
powershell -ExecutionPolicy Bypass -File windows\scripts\Invoke-DriftReport.ps1 -DiffFile "path\to\diff-output.json" -OutputDir "path\to\reports\"
```

### RHEL 9 / Linux

**Requirements:** Bash 4.0+, Python 3, run as root or with sudo.

```bash
# 1. Clone the repository
git clone https://github.com/YOUR-USERNAME/server-config-drift-detector.git
cd server-config-drift-detector

# 2. Make scripts executable
chmod +x linux/scripts/*.sh

# 3. Review and edit the configuration file
vi linux/config/snapshot.conf

# 4. Capture a baseline snapshot
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label baseline

# 5. After changes have occurred, capture a comparison snapshot
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label weekly-review

# 6. Compare the two snapshots
sudo bash linux/scripts/compare-snapshots.sh \
  --baseline /path/to/baseline-snapshot.json \
  --compare /path/to/weekly-review-snapshot.json \
  --output /path/to/diff-output.json

# 7. Generate the drift report
sudo bash linux/scripts/drift-report.sh \
  --diff /path/to/diff-output.json \
  --output-dir /path/to/reports/
```

---

## Sample Output

A drift report identifies changes by category, timestamps them against the baseline, and classifies each finding. The following is a representative excerpt.

```
DRIFT REPORT - server01.example.local
Baseline:   2025-10-01 02:00:11
Comparison: 2025-10-08 02:00:09
Generated:  2025-10-08 06:30:00

SUMMARY
-------
Services          3 changes  [NOTABLE]
Local Users       1 change   [CRITICAL]
Firewall Rules    0 changes  [NONE]
Scheduled Tasks   1 change   [NOTABLE]
Listening Ports   2 changes  [NOTABLE]
Installed Software 0 changes [NONE]

DETAIL - Local Users [CRITICAL]
User 'svc_deploy' added
  UID: 1004  Shell: /bin/bash  Groups: wheel
  No corresponding change ticket found in baseline metadata.
```

Full sample reports are available in `samples/windows/` and `samples/linux/`.

---

## Scheduling

Automated snapshot capture is included for both platforms.

**Windows:** A scheduled task runs `New-ConfigSnapshot.ps1` daily at 02:00. See `windows/scheduled-task/` for registration instructions.

**Linux:** A systemd timer runs `take-snapshot.sh` daily at 02:00. See `linux/systemd/` for installation instructions.

---

## Documentation

| Document | Purpose |
|---|---|
| `docs/architecture-overview.md` | How all components work together |
| `docs/operational-guide.md` | Complete setup and usage instructions |
| `docs/snapshot-methodology.md` | What is captured and the reasoning behind it |
| `docs/drift-interpretation-guide.md` | How to read reports and classify findings |
| `docs/threat-model.md` | Security scope and limitations |
| `docs/security-considerations.md` | Hardening the toolkit itself |
| `docs/troubleshooting.md` | Resolving toolkit failures |
| `docs/command-reference.md` | All script parameters at a glance |

---

## Operational Boundaries

This toolkit detects drift. It does not remediate it. It does not prevent changes. It does not replace a change management process. It does not provide real-time alerting.

What it provides is a clear, structured, auditable record of what changed between two points in time - and the operational workflow to act on that information.

---

## Platform Support

| Platform | Supported | Notes |
|---|---|---|
| Windows Server 2022 | Yes | Primary target |
| Windows Server 2019 | Likely | Not validated |
| RHEL 9 | Yes | Primary target |
| RHEL 8 | Likely | Not validated |
| Rocky Linux 9 | Likely | Not validated |
| AlmaLinux 9 | Likely | Not validated |
| Ubuntu Server | No | firewalld and rpm commands not present |

---

## Security Notice

Snapshot files contain sensitive system information including local user account names, service configurations, firewall rules, and installed software inventories. These files must be stored in a location accessible only to authorised administrators. They must never be committed to version control.

The `.gitignore` file in this repository excludes common snapshot output directories. Review it before your first commit. See `docs/security-considerations.md` for full guidance.

---

## Contributing

This is a portfolio and operational reference project. It is not accepting external contributions at this time.

---

## License

MIT License. See `LICENSE` for full terms.


