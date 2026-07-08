# Drift Response Checklist

## Purpose

This checklist is completed each time a drift report is reviewed. It provides a structured, auditable workflow for working through every finding in a report, ensuring nothing is dismissed without a documented decision and nothing is left in an ambiguous state.

A drift report is not closed until every finding has been assigned one of four outcomes: **Expected**, **Routine**, **Retroactively Documented**, or **Escalated**. This checklist enforces that discipline.

Read `docs/drift-interpretation-guide.md` before working through this checklist for the first time.

---

## Identification

| Field | Value |
|---|---|
| Server hostname | |
| Platform | Windows Server 2022 / RHEL 9 (circle one) |
| Drift report filename | |
| Baseline snapshot referenced | |
| Comparison snapshot referenced | |
| Overall report severity | NONE / INFORMATIONAL / NOTABLE / CRITICAL (circle one) |
| Review performed by | |
| Review date | |

---

## Section 1 - Pre-Review Steps

Complete these steps before examining individual findings.

- [ ] Confirm the drift report file being reviewed was generated from the correct baseline and comparison snapshots. Verify the `baseline_snapshot` and `compare_snapshot` fields in the report metadata match the filenames you intended to compare.
  - Windows: `(Get-Content .\reports\*_drift-report_*.json -Raw | ConvertFrom-Json).metadata`
  - Linux: `jq '.metadata' reports/*_drift-report_*.json`

- [ ] Confirm the report was generated after the comparison snapshot was taken, not before (i.e. confirm the report timestamp is later than the comparison snapshot timestamp).

- [ ] Confirm the `capture_errors` array in the comparison snapshot is empty. A snapshot with capture errors may be missing data in affected categories, which could cause real drift to appear as no change.
  - Windows: `(Get-Content .\snapshots\*_weekly-review.json -Raw | ConvertFrom-Json).capture_errors`
  - Linux: `jq '.capture_errors' snapshots/*_weekly-review.json`
  If `capture_errors` is not empty, document which categories were affected and treat findings in those categories with lower confidence - the absence of findings does not guarantee no change occurred.

- [ ] Review the Summary table first. Record the category-level findings here before diving into detail:

| Category | Change Count | Severity | Initial Assessment |
|---|---|---|---|
| Installed Software / Packages | | | |
| Services | | | |
| Local Users | | | |
| Firewall Rules | | | |
| Scheduled Tasks / Cron Jobs | | | |
| Listening Ports | | | |
| Sudo Access (Linux) | | | |
| Wheel Group (Linux) | | | |
| SELinux Status (Linux) | | | |
| Config File Checksums (Linux) | | | |
| Pending Updates (Windows) | | | |

---

## Section 2 - Finding-by-Finding Review

For each finding in the Detail sections of the report, complete one row in this table. Use the four-question framework from `docs/drift-interpretation-guide.md` to assign an outcome.

Copy this table into a separate document or ticket if there are more findings than fit comfortably here. Every finding must have a row - do not skip INFORMATIONAL findings, as a pattern of undocumented INFORMATIONAL changes is itself operationally significant.

**Outcome codes:**
- **E** - Expected (change was documented in a ticket or change record)
- **R** - Routine (change matches a pre-approved routine operation)
- **D** - Retroactively Documented (change was legitimate but undocumented; ticket filed)
- **X** - Escalated (no legitimate explanation found; incident process initiated)

| # | Category | Change Type | Description | Ticket / Reference | Outcome | Investigated By |
|---|---|---|---|---|---|---|
| 1 | | | | | | |
| 2 | | | | | | |
| 3 | | | | | | |
| 4 | | | | | | |
| 5 | | | | | | |
| 6 | | | | | | |
| 7 | | | | | | |
| 8 | | | | | | |
| 9 | | | | | | |
| 10 | | | | | | |

*Add additional rows as needed.*

---

## Section 3 - CRITICAL Finding Handling

Complete this section for every finding assigned **CRITICAL** severity in the report. If no CRITICAL findings were present, mark this section as not applicable.

Not applicable: [ ]

For each CRITICAL finding:

### CRITICAL Finding 1

| Field | Value |
|---|---|
| Category | |
| Change description | |
| Initial discovery time | |
| Assigned to | |
| Ticket number | |
| Outcome | Expected / Retroactively Documented / Escalated |
| Resolution confirmed by | |
| Resolution date | |

*Copy this block for each additional CRITICAL finding.*

- [ ] All CRITICAL findings have been assigned to a named owner.
- [ ] All CRITICAL findings have a ticket number for tracking.
- [ ] No CRITICAL finding has been marked as "Routine" - CRITICAL findings always require individual investigation and documentation, never pre-approval as routine.

---

## Section 4 - Pattern Review

After completing Section 2, review the findings as a whole rather than individually. Answer each question below.

- [ ] **Clustering check:** Are multiple unrelated CRITICAL or NOTABLE findings present in the same report? If so, note this - simultaneous changes across multiple security-relevant categories is a stronger signal than isolated changes.
  - Note:

- [ ] **Recurrence check:** Have any of the same findings appeared in the previous review's drift report? If so, note which categories are showing repeated, undocumented drift.
  - Note:

- [ ] **Process gap check:** Were any findings assigned outcome D (Retroactively Documented)? If yes, note how many. Repeated D outcomes suggest a process gap, not isolated oversights.
  - Count of D outcomes: ____
  - Note:

- [ ] **Baseline accuracy check:** Does the current server state, after all findings are reviewed, still reflect an operationally accurate, approved configuration? Or have legitimate, approved changes accumulated to the point where the baseline no longer reflects current reality?

---

## Section 5 - Disposition Decision

Based on Sections 2, 3, and 4, determine the overall disposition of this drift report.

Choose exactly one:

- [ ] **CLOSE - No action required.** All findings were Expected or Routine. No open items remain. No baseline update needed.

- [ ] **CLOSE WITH FOLLOW-UP.** All findings have been reviewed and assigned outcomes, but one or more retroactively filed tickets (D outcomes) remain open and should be confirmed closed at the next review. Note ticket numbers: ________________

- [ ] **BASELINE UPDATE REQUIRED.** All findings are resolved and approved. The current server state represents a new known-good configuration. Proceed to Section 6 before closing.

- [ ] **HOLD - ESCALATED.** One or more findings were escalated (X outcome). This report cannot be closed until the incident process concludes. Do not promote a new baseline while an escalation is open.

---

## Section 6 - Baseline Promotion (If Applicable)

Complete this section only if Section 5 disposition is **BASELINE UPDATE REQUIRED**.

- [ ] Confirm every finding in Section 2 has outcome E, R, or D - no X outcomes are present.

- [ ] Confirm all D-outcome tickets have been filed and the changes are confirmed as legitimate.

- [ ] Take a fresh baseline snapshot:
  - Windows: `.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath .\windows\config\snapshot-config.json -Label "baseline"`
  - Linux: `sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label baseline`

- [ ] Complete `templates/baseline-approval-template.md` for the new baseline.

- [ ] Record the new baseline filename and SHA-256 checksum:
  - Windows: `Get-FileHash .\snapshots\*_baseline.json -Algorithm SHA256`
  - Linux: `sha256sum snapshots/*_baseline.json`
  - New baseline filename: ________________
  - New baseline SHA-256: ________________

- [ ] Store a read-only copy of the new baseline in a separate location, per `docs/security-considerations.md`.

---

## Section 7 - Sign-Off

This drift review is complete when all findings have an assigned outcome, all CRITICAL findings have a ticket number, and Section 5 disposition has been selected and actioned.

| Field | Value |
|---|---|
| Total findings reviewed | |
| Expected (E) outcomes | |
| Routine (R) outcomes | |
| Retroactively Documented (D) outcomes | |
| Escalated (X) outcomes | |
| Final disposition | |
| Review completed by | |
| Date completed | |
| Secondary reviewer (if applicable) | |

---

