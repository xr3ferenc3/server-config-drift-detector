# Changelog

All notable changes to this project are documented in this file.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and the format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## Version Numbering Convention

| Component | Meaning |
|---|---|
| MAJOR | Incompatible changes to snapshot schema or report format |
| MINOR | New capture categories, new script features, new documentation sections |
| PATCH | Bug fixes, wording corrections, minor improvements |

A MAJOR version increment means existing snapshot files may not be compatible with the new comparison scripts. Always document schema changes explicitly.

---

## [Unreleased]

No changes pending.

---

## [1.0.0] - 2026-07-09

### Added

**Repository Foundation**
- `README.md` - Project overview, quick start instructions, repository structure map, platform support matrix, security notice
- `LICENSE` - MIT License
- `CHANGELOG.md` - This file
- `.gitignore` - Exclusions for snapshot output directories, OS artifacts, and editor temporary files

**Documentation**
- `docs/architecture-overview.md` - Component relationships, snapshot lifecycle, data flow, storage model
- `docs/threat-model.md` - Security scope, data sensitivity classification, attacker scenarios, explicit limitations
- `docs/operational-guide.md` - Installation, first run, baseline establishment, scheduling, report generation, output interpretation
- `docs/snapshot-methodology.md` - Capture rationale per category for both platforms, explicit exclusions and reasoning
- `docs/drift-interpretation-guide.md` - Report structure, severity classification, decision framework, escalation criteria
- `docs/troubleshooting.md` - Known failure modes, diagnosis steps, resolution procedures for both platforms
- `docs/security-considerations.md` - Snapshot file permissions, storage guidance, access control, toolkit hardening
- `docs/command-reference.md` - All script parameters and options for all six scripts across both platforms

**Windows Scripts**
- `windows/scripts/New-ConfigSnapshot.ps1` - Captures Windows Server 2022 configuration state to structured JSON
- `windows/scripts/Compare-ConfigSnapshots.ps1` - Compares two Windows snapshots and produces a structured diff
- `windows/scripts/Invoke-DriftReport.ps1` - Generates Markdown and JSON drift reports from comparison output
- `windows/config/snapshot-config.json` - Operator configuration file for Windows snapshot behaviour
- `windows/scheduled-task/Register-SnapshotTask.ps1` - Creates and validates the Windows scheduled task
- `windows/scheduled-task/snapshot-task-definition.xml` - Auditable XML task definition for change records

**Linux Scripts**
- `linux/scripts/take-snapshot.sh` - Captures RHEL 9 configuration state to structured JSON
- `linux/scripts/compare-snapshots.sh` - Compares two Linux snapshots and produces a structured diff
- `linux/scripts/drift-report.sh` - Generates Markdown and JSON drift reports from comparison output
- `linux/config/snapshot.conf` - Operator configuration file for Linux snapshot behaviour
- `linux/systemd/snapshot.service` - systemd service unit for snapshot execution with security hardening
- `linux/systemd/snapshot.timer` - systemd timer unit for automated scheduling

**Checklists**
- `checklists/baseline-snapshot-checklist.md` - Pre-conditions, execution steps, and post-conditions for baseline establishment
- `checklists/drift-response-checklist.md` - Step-by-step workflow for responding to drift findings
- `checklists/weekly-review-checklist.md` - Structured process for the scheduled weekly drift review

**Sample Outputs**
- `samples/windows/sample-snapshot-windows.json` - Realistic anonymised Windows snapshot
- `samples/windows/sample-drift-report-windows.md` - Realistic Windows drift report in Markdown
- `samples/windows/sample-drift-report-windows.json` - Realistic Windows drift report in JSON
- `samples/linux/sample-snapshot-linux.json` - Realistic anonymised Linux snapshot
- `samples/linux/sample-drift-report-linux.md` - Realistic Linux drift report in Markdown
- `samples/linux/sample-drift-report-linux.json` - Realistic Linux drift report in JSON

**Templates**
- `templates/drift-ticket-template.md` - Structured ticket template for reporting and tracking drift findings
- `templates/baseline-approval-template.md` - Formal approval record for accepted baseline snapshots

---

## How to Update This File

When making changes to this repository:

1. Add entries under `[Unreleased]` as changes are made
2. When releasing a new version, create a new dated section heading
3. Move all `[Unreleased]` entries into the new section
4. Update the version number following the convention above
5. Record the release date in ISO 8601 format: YYYY-MM-DD
6. Commit the CHANGELOG update in the same commit as the version bump

Every entry must be specific enough that an operator can identify exactly which file or behaviour changed and why it matters operationally.

---