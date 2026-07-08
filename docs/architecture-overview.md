# Architecture Overview

## Purpose of This Document

This document explains how all components of the server-config-drift-detector toolkit fit together. It covers the snapshot lifecycle, the data flow between scripts, the storage model, the report generation pipeline, and how scheduling integrates with the core workflow.

A reader who finishes this document should understand how the system works end to end without needing to open a single script.

---

## Design Philosophy

This toolkit is built on three operational principles.

**Simplicity of dependency.** Every component uses only tools that are present by default on a standard Windows Server 2022 or RHEL 9 installation. No agents are installed. No external services are called. No network connectivity is required for core operation. If the operating system is running, the toolkit can run.

**Separation of concerns.** Data collection, comparison, and reporting are three distinct operations performed by three distinct scripts. No single script does all three. This means each stage can be run independently, re-run if needed, inspected in isolation, and replaced without affecting the others.

**Output that travels.** Every report produced by this toolkit is a standalone file - Markdown for human readers, JSON for programmatic consumption. A report generated on a server at 02:00 can be emailed, attached to a ticket, stored in a shared drive, or read by another tool without any dependency on the toolkit itself.

---

## System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                        OPERATOR / SCHEDULER                      │
│              (manual execution or automated schedule)            │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     CONFIGURATION FILE                           │
│         snapshot-config.json  /  snapshot.conf                   │
│                                                                  │
│  Defines: output directory, retention policy, enabled capture    │
│  categories, severity thresholds, report format preferences      │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    SNAPSHOT SCRIPT (Stage 1)                     │
│      New-ConfigSnapshot.ps1  /  take-snapshot.sh                 │
│                                                                  │
│  Collects server state across all enabled capture categories.    │
│  Writes one timestamped JSON snapshot file per execution.        │
│  Adds metadata block: hostname, OS version, timestamp, schema.   │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     SNAPSHOT STORAGE                             │
│              (local directory defined in config)                 │
│                                                                  │
│  server01_2025-10-01_0200_baseline.json                          │
│  server01_2025-10-08_0200_weekly-review.json                     │
│  server01_2025-10-15_0200_weekly-review.json                     │
│  ...                                                             │
│                                                                  │
│  Retention policy enforced at snapshot time.                     │
│  Oldest snapshots removed when retention limit is exceeded.      │
└──────────────┬──────────────────────────┬───────────────────────┘
               │                          │
               │ (baseline)               │ (comparison target)
               ▼                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                   COMPARISON SCRIPT (Stage 2)                    │
│     Compare-ConfigSnapshots.ps1  /  compare-snapshots.sh         │
│                                                                  │
│  Accepts exactly two snapshot files as input.                    │
│  Performs field-by-field comparison per capture category.        │
│  Produces one structured diff JSON file.                         │
│  Does not classify, score, or interpret - only identifies delta. │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                      DIFF STORAGE                                │
│              (local directory defined in config)                 │
│                                                                  │
│  server01_diff_2025-10-01_vs_2025-10-08.json                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                   REPORT SCRIPT (Stage 3)                        │
│        Invoke-DriftReport.ps1  /  drift-report.sh                │
│                                                                  │
│  Consumes the diff JSON file.                                    │
│  Applies severity classification per category.                   │
│  Produces two output files:                                      │
│    - Markdown report (human-readable, ticket-ready)              │
│    - JSON report (machine-readable, audit-ready)                 │
└──────────────┬──────────────────────────┬───────────────────────┘
               │                          │
               ▼                          ▼
┌──────────────────────────┐  ┌──────────────────────────────────┐
│   MARKDOWN DRIFT REPORT  │  │       JSON DRIFT REPORT          │
│                          │  │                                  │
│  Human-readable.         │  │  Machine-readable.               │
│  Attach to ticket.       │  │  Store in audit record.          │
│  Share with team.        │  │  Feed to other tools.            │
│  Print for review.       │  │  Compare across servers.         │
└──────────────────────────┘  └──────────────────────────────────┘
```

---

## Snapshot Lifecycle

A snapshot passes through three states during its operational life.

### State 1 - Baseline

The first snapshot taken on a server after it has been provisioned, configured, patched, and approved. The baseline represents the known-good state. It is the reference point against which all future snapshots are compared.

A baseline snapshot is not taken automatically. It is taken deliberately, after the server has been reviewed and signed off. The `checklists/baseline-snapshot-checklist.md` defines the pre-conditions that must be met before a baseline is established.

A baseline remains valid until one of the following occurs:
- An approved, documented change is made to the server
- An audit requires a new baseline to be established
- The operator explicitly supersedes the baseline with a new one

When a baseline is superseded, the old baseline file is retained for historical reference. It is not deleted.

### State 2 - Comparison Snapshot

Any snapshot taken after the baseline. Comparison snapshots are taken on a schedule - typically daily or weekly - and are compared against the baseline to detect drift. A comparison snapshot becomes the input to Stage 2 (the comparison script) along with the baseline.

Comparison snapshots are subject to the retention policy defined in the configuration file. Older comparison snapshots are removed automatically when the retention limit is reached. Baseline snapshots are exempt from the retention policy.

### State 3 - Promoted Baseline

If a drift report is reviewed and all detected changes are approved and documented, the comparison snapshot may be promoted to become the new baseline. This acknowledges that the server's current state is the new known-good state and resets the reference point for future comparisons.

Promotion is a manual operator action. It is recorded in the `templates/baseline-approval-template.md` document.

---

## File Naming Convention

Consistent file naming is required for the comparison script to locate snapshots reliably and for operators to identify files without opening them.

### Snapshot Files

```
{hostname}_{YYYY-MM-DD}_{HHMM}_{label}.json
```

Examples:
```
server01_2025-10-01_0200_baseline.json
server01_2025-10-08_0200_weekly-review.json
webserver02_2025-10-15_0200_post-patch.json
```

### Diff Files

```
{hostname}_diff_{YYYY-MM-DD}_vs_{YYYY-MM-DD}.json
```

Examples:
```
server01_diff_2025-10-01_vs_2025-10-08.json
webserver02_diff_2025-10-01_vs_2025-10-15.json
```

### Report Files

```
{hostname}_drift-report_{YYYY-MM-DD}.md
{hostname}_drift-report_{YYYY-MM-DD}.json
```

Examples:
```
server01_drift-report_2025-10-08.md
server01_drift-report_2025-10-08.json
```

---

## Data Flow - Windows

```
Windows Server 2022
│
├── New-ConfigSnapshot.ps1
│     reads: snapshot-config.json
│     queries: Win32_Product, Get-Service, Get-LocalUser,
│              Get-NetFirewallRule, Get-ScheduledTask,
│              Get-NetTCPConnection, Get-HotFix, PSWindowsUpdate
│     writes: {hostname}_{date}_{time}_{label}.json
│
├── Compare-ConfigSnapshots.ps1
│     reads: baseline snapshot JSON
│     reads: comparison snapshot JSON
│     writes: {hostname}_diff_{date}_vs_{date}.json
│
└── Invoke-DriftReport.ps1
      reads: diff JSON
      reads: snapshot-config.json (for thresholds)
      writes: {hostname}_drift-report_{date}.md
      writes: {hostname}_drift-report_{date}.json
```

---

## Data Flow - Linux

```
RHEL 9
│
├── take-snapshot.sh
│     reads: snapshot.conf
│     queries: rpm -qa, systemctl list-units, /etc/passwd,
│              /etc/sudoers, /etc/sudoers.d/, firewall-cmd,
│              ss -tlnup, crontab -l, /var/spool/cron/,
│              getenforce, sha256sum of key files
│     writes: {hostname}_{date}_{time}_{label}.json
│
├── compare-snapshots.sh
│     reads: baseline snapshot JSON
│     reads: comparison snapshot JSON
│     invokes: python3 for JSON parsing and diff logic
│     writes: {hostname}_diff_{date}_vs_{date}.json
│
└── drift-report.sh
      reads: diff JSON
      reads: snapshot.conf (for thresholds)
      writes: {hostname}_drift-report_{date}.md
      writes: {hostname}_drift-report_{date}.json
```

---

## Snapshot JSON Schema

Both platforms produce snapshots that follow the same top-level schema. This consistency means a reader familiar with one platform's output can navigate the other without relearning the structure.

```json
{
  "metadata": {
    "schema_version": "1.0",
    "hostname": "server01",
    "platform": "windows | linux",
    "os_version": "...",
    "snapshot_label": "baseline | weekly-review | post-patch | ...",
    "snapshot_timestamp": "2025-10-01T02:00:11Z",
    "script_version": "1.0.0",
    "captured_by": "SYSTEM | root"
  },
  "software": [],
  "services": [],
  "local_users": [],
  "firewall": [],
  "scheduled_jobs": [],
  "listening_ports": [],
  "platform_specific": {},
  "config_checksums": {}
}
```

Platform-specific fields (Windows Update pending updates, Linux SELinux status, Linux sudo rules) appear under `platform_specific` to maintain schema consistency while accommodating genuine platform differences.

---

## Diff JSON Schema

The diff file produced by the comparison script follows a consistent structure regardless of platform.

```json
{
  "metadata": {
    "schema_version": "1.0",
    "hostname": "server01",
    "platform": "windows | linux",
    "baseline_snapshot": "server01_2025-10-01_0200_baseline.json",
    "baseline_timestamp": "2025-10-01T02:00:11Z",
    "compare_snapshot": "server01_2025-10-08_0200_weekly-review.json",
    "compare_timestamp": "2025-10-08T02:00:09Z",
    "diff_generated": "2025-10-08T06:00:00Z",
    "script_version": "1.0.0"
  },
  "categories": {
    "software": {
      "added": [],
      "removed": [],
      "modified": []
    },
    "services": {
      "added": [],
      "removed": [],
      "modified": []
    },
    "local_users": {
      "added": [],
      "removed": [],
      "modified": []
    },
    "firewall": {
      "added": [],
      "removed": [],
      "modified": []
    },
    "scheduled_jobs": {
      "added": [],
      "removed": [],
      "modified": []
    },
    "listening_ports": {
      "added": [],
      "removed": [],
      "modified": []
    },
    "platform_specific": {},
    "config_checksums": {
      "changed": []
    }
  }
}
```

---

## Severity Classification

The report script applies a severity classification to each category based on the number and nature of changes detected. Thresholds are operator-configurable in the configuration file.

| Severity | Meaning | Default Trigger |
|---|---|---|
| `NONE` | No changes detected in this category | Zero changes |
| `INFORMATIONAL` | Changes detected, low operational significance | Software updates, service restart count changes |
| `NOTABLE` | Changes detected, warrants review | Service state changes, new listening ports, scheduled task modifications |
| `CRITICAL` | Changes detected, immediate review required | New local user accounts, firewall rule removals, config file checksum changes, new sudo grants |

The `CRITICAL` classification does not mean an incident has occurred. It means the change is significant enough to require a deliberate human decision before it can be approved or dismissed.

---

## Scheduling Integration

### Windows

A Windows Scheduled Task triggers `New-ConfigSnapshot.ps1` daily. The task runs as the SYSTEM account with highest privileges. Task registration is handled by `Register-SnapshotTask.ps1`. The task definition is also provided as `snapshot-task-definition.xml` for audit and change management purposes.

The comparison and reporting scripts are not scheduled automatically. They are run manually by the operator during the weekly review, or on demand following a change or incident. This is intentional - automated comparison requires a defined baseline selection strategy that varies by environment.

### Linux

A systemd timer triggers `take-snapshot.sh` daily. The service unit applies security restrictions (NoNewPrivileges, PrivateTmp, restricted write paths). The timer and service are installed manually following the instructions in `docs/operational-guide.md`.

The same scheduling boundary applies: comparison and reporting are manual operations.

---

## What This Toolkit Does Not Do

Stating explicit boundaries is as important as stating capabilities.

| Capability | In Scope | Out of Scope |
|---|---|---|
| Detecting configuration changes | Yes | - |
| Preventing configuration changes | - | No |
| Real-time alerting | - | No |
| Automated remediation | - | No |
| Multi-server centralised management | - | No |
| Network device configuration tracking | - | No |
| Application configuration tracking | - | No |
| File content change detection (beyond key system files) | - | No |
| User activity logging | - | No |
| Integration with SIEM or log aggregation | - | No |

These are not limitations of the design. They are deliberate scope boundaries. Each excluded capability either requires enterprise tooling, introduces significant complexity, or falls outside the operational problem this toolkit is designed to solve.

---

## Extending This Toolkit

Operators who wish to extend the toolkit should follow these principles to maintain consistency and supportability.

- Add new capture categories to the snapshot script first, then extend the comparison script to handle the new category, then extend the report script to render it
- Update the snapshot JSON schema version in `metadata.schema_version` when adding new top-level fields
- Document new categories in `docs/snapshot-methodology.md`
- Add the new category to the severity classification table in the configuration file
- Test comparison across a schema version boundary before deploying to production
- Update `CHANGELOG.md` with the new category addition