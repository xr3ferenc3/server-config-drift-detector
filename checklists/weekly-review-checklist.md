# Weekly Review Checklist

## Purpose

This checklist defines the structured process for the scheduled weekly drift review. Its purpose is to make the review systematic, consistent, and auditable regardless of which operator performs it - the same steps, in the same order, producing the same quality of output every week.

A weekly review completed using this checklist produces three things: a drift report filed for the record, a completed drift response checklist for any findings, and a documented confirmation that the server's configuration state is known and either matches the baseline or has a plan for any discrepancies.

This checklist is designed to be completed in under 30 minutes for a single server with no CRITICAL findings. CRITICAL findings will extend the review duration according to the time required to investigate and document them.

---

## Identification

| Field | Value |
|---|---|
| Server hostname | |
| Platform | Windows Server 2022 / RHEL 9 (circle one) |
| Review week ending | |
| Review performed by | |
| Start time | |
| End time | |

---

## Section 1 - Environment Confirmation

Before running any scripts, confirm the environment is in an expected state for a routine review.

- [ ] The server is online and reachable.
  - Windows: `Test-Connection -ComputerName localhost -Count 1`
  - Linux: `ping -c 1 localhost`

- [ ] The scheduling mechanism is active and has run since the last review:
  - **Windows:** `Get-ScheduledTaskInfo -TaskName "ConfigDriftDetector-Snapshot"` - confirm `LastRunTime` is within the past 8 days and `LastTaskResult` is 0 or 2.
  - **Linux:** `systemctl list-timers snapshot.timer` - confirm `LAST` column shows a run within the past 8 days, and `sudo journalctl -u snapshot.service --since "8 days ago" | tail -5` shows recent execution.

- [ ] Scheduled snapshots from the past week are present in the snapshot directory:
  - Windows: `Get-ChildItem .\snapshots\*_scheduled.json | Sort-Object LastWriteTime -Descending | Select-Object -First 7`
  - Linux: `ls -lt snapshots/*_scheduled.json | head -7`
  If no scheduled snapshots are present, the scheduling mechanism has failed. Consult `docs/troubleshooting.md` scheduling section before proceeding. Do not use a manually taken snapshot as a substitute for a missing scheduled snapshot without noting this in the review record - a gap in scheduled coverage is itself an operational finding.

- [ ] The current approved baseline snapshot is present and has not been modified since it was established:
  - Windows: `Get-FileHash .\snapshots\*_baseline.json -Algorithm SHA256`
  - Linux: `sha256sum snapshots/*_baseline.json`
  Compare the output against the SHA-256 recorded in `templates/baseline-approval-template.md` for this server. A mismatch is a CRITICAL finding - record it and treat it as Threat 2 (Baseline Tampering) from `docs/threat-model.md` until proven otherwise.

---

## Section 2 - Identify the Comparison Target

Select the snapshot to compare against the baseline for this week's review.

- [ ] Identify the most recent `scheduled` snapshot from the past seven days:
  - Windows: `Get-ChildItem .\snapshots\*_scheduled.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName`
  - Linux: `ls -t snapshots/*_scheduled.json | head -1`

- [ ] Record the selected snapshot filename here: ________________

- [ ] Confirm the selected snapshot's `capture_errors` array is empty before using it as the comparison target:
  - Windows: `(Get-Content .\snapshots\<selected_filename> -Raw | ConvertFrom-Json).capture_errors`
  - Linux: `jq '.capture_errors' snapshots/<selected_filename>`
  If `capture_errors` is not empty, record which categories were affected in the review notes and proceed with the understanding that those categories may have gaps.

---

## Section 3 - Run the Comparison

- [ ] Run the comparison script with the approved baseline and the selected snapshot:

  **Windows:**
  ```powershell
  .\windows\scripts\Compare-ConfigSnapshots.ps1 `
    -BaselineSnapshot ".\snapshots\<baseline_filename>" `
    -CompareSnapshot  ".\snapshots\<selected_filename>" `
    -OutputPath       ".\diff\<hostname>_diff_<baseline_date>_vs_<comparison_date>.json"
  ```

  **Linux:**
  ```bash
  bash linux/scripts/compare-snapshots.sh \
    --baseline snapshots/<baseline_filename> \
    --compare  snapshots/<selected_filename> \
    --output   diff/<hostname>_diff_<baseline_date>_vs_<comparison_date>.json
  ```

- [ ] The comparison script exited with code 0.
  - Windows: `$LASTEXITCODE`
  - Linux: `echo $?`
  If exit code was 1, the comparison failed. Consult `docs/troubleshooting.md` Comparison Script Issues before proceeding.

- [ ] The diff file was created in the diff output directory:
  - Windows: `Test-Path .\diff\<diff_filename>`
  - Linux: `test -f diff/<diff_filename> && echo "exists"`

- [ ] Record the diff filename here: ________________

---

## Section 4 - Generate the Drift Report

- [ ] Run the report generation script against the diff file:

  **Windows:**
  ```powershell
  .\windows\scripts\Invoke-DriftReport.ps1 `
    -DiffFile   ".\diff\<diff_filename>" `
    -ConfigPath ".\windows\config\snapshot-config.json" `
    -OutputDir  ".\reports"
  ```

  **Linux:**
  ```bash
  bash linux/scripts/drift-report.sh \
    --diff       diff/<diff_filename> \
    --config     linux/config/snapshot.conf \
    --output-dir reports
  ```

- [ ] Record the report script exit code:
  - 0 = success, no CRITICAL findings
  - 1 = error (consult `docs/troubleshooting.md`)
  - 3 = success, CRITICAL findings present (proceed to Section 5 immediately)
  - Exit code recorded: ____

- [ ] The Markdown and JSON report files were created in the reports directory:
  - Windows: `Get-ChildItem .\reports\*_drift-report_*.md | Sort-Object LastWriteTime -Descending | Select-Object -First 1`
  - Linux: `ls -t reports/*_drift-report_*.md | head -1`

- [ ] Record the report filename here: ________________

---

## Section 5 - Review the Drift Report

- [ ] Open the generated Markdown report.

- [ ] Read the Summary table. Record the overall severity here: ________________

- [ ] If overall severity is **NONE**:
  - [ ] Confirm the Summary table shows zero changes across all categories.
  - [ ] Record in the sign-off below: "No drift detected this week."
  - [ ] Skip to Section 7.

- [ ] If overall severity is **INFORMATIONAL**:
  - [ ] Review the Detail section for INFORMATIONAL findings.
  - [ ] Determine if any INFORMATIONAL findings form part of a concerning pattern (see `docs/drift-interpretation-guide.md` Pattern Recognition section).
  - [ ] If no pattern of concern: note findings in the sign-off, skip to Section 7.
  - [ ] If a pattern is identified: complete `checklists/drift-response-checklist.md` before proceeding.

- [ ] If overall severity is **NOTABLE** or **CRITICAL**:
  - [ ] Complete `checklists/drift-response-checklist.md` in full before proceeding to Section 7 of this checklist. The drift response checklist must reach a final disposition before this weekly review checklist can be signed off.
  - [ ] Attach or reference the completed drift response checklist in the sign-off below.

---

## Section 6 - Toolkit Health Check

This section confirms the toolkit's own components are operating correctly. Complete it during every weekly review, not only when findings are present.

- [ ] **Scheduler health:**
  - Windows: confirm `LastTaskResult` from `Get-ScheduledTaskInfo -TaskName "ConfigDriftDetector-Snapshot"` is 0 or 2 for all runs this week. A result of 2 means the snapshot ran with partial errors - review the log file for that date.
  - Linux: confirm `sudo journalctl -u snapshot.service --since "7 days ago" | grep -E "ERROR|WARN"` shows no unexpected errors.

- [ ] **Log file review:** Open the most recent log file from the `logs/` directory for this server and confirm there are no ERROR entries that were not explained by a known, expected condition.
  - Windows: `Get-Content .\logs\snapshot_$(Get-Date -Format "yyyy-MM-dd").log | Select-String "ERROR"`
  - Linux: `grep "ERROR" logs/snapshot_$(date +%Y-%m-%d).log 2>/dev/null || echo "No errors found"`

- [ ] **Retention policy check:** Confirm the snapshot directory does not contain more comparison snapshots than the configured `maxComparisonSnapshots` (Windows) or `MAX_COMPARISON_SNAPSHOTS` (Linux) limit. The retention policy should be enforcing this automatically, but a manual check confirms it is working.
  - Windows: `(Get-ChildItem .\snapshots\*_scheduled.json).Count`
  - Linux: `ls snapshots/*_scheduled.json 2>/dev/null | wc -l`

- [ ] **Script file integrity check:** Confirm no script files have been modified since the last review by checking git status:
  ```bash
  git diff --name-only HEAD windows/scripts/ linux/scripts/
  ```
  Expected output: empty (no tracked files modified). If any script file appears as modified and no intentional update was made, treat this as a potential Threat 3 (Script Modification) per `docs/threat-model.md` and investigate before continuing.

- [ ] **Baseline integrity check:** Confirm the baseline snapshot SHA-256 still matches the value recorded in `templates/baseline-approval-template.md`. This check was completed in Section 1 - record the result here for completeness:
  - SHA-256 matches approved record: Yes / No
  - If No: this is a CRITICAL finding - record it and consult `docs/threat-model.md` Threat 2 immediately.

---

## Section 7 - Filing and Archiving

- [ ] File the generated drift report (both Markdown and JSON) in the location designated by your organisation for operational records. If no centralised location exists, note the local path here: ________________

- [ ] If a drift response checklist was completed this week, file it alongside the drift report.

- [ ] If a `templates/drift-ticket-template.md` was used to open a follow-up ticket for any finding, record the ticket number(s) here: ________________

- [ ] If a baseline promotion was performed this week, record the new baseline filename and confirm the old baseline is retained in the archive location: ________________

---

## Section 8 - Sign-Off

| Field | Value |
|---|---|
| Weekly review completed | Yes / No |
| Drift report filename | |
| Overall severity | NONE / INFORMATIONAL / NOTABLE / CRITICAL |
| Total findings reviewed | |
| Open follow-up tickets | |
| Baseline updated this week | Yes / No |
| Drift response checklist completed | Yes / No / Not required |
| Toolkit health issues found | Yes / No |
| Review completed by | |
| Date and time completed | |
| Secondary reviewer (if required by your change control process) | |

---

## Notes

*Use this space for any observations not captured in the structured sections above - unusual patterns, environmental context that explains unexpected findings, or reminders for the following week's review.*

---

