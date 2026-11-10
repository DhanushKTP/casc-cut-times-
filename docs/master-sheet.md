# Master sheet

One Excel workbook on SharePoint, for example `Laser Cut Times.xlsx`, with one **table** (Insert → Table, tick "My table has headers") named **`CutTimes`**. Power Automate can only add rows to a table, not to a plain range.

The column headers must match exactly, in this order:

| # | Column | Example | Notes |
|---|---|---|---|
| 1 | Submission ID | `256bcede-12c3-…` | Same on every row of one submission. Links the row back to the app. |
| 2 | Line | `1` | 1, 2, 3… for each customer/JN on the program |
| 3 | Program | `54533` | SigmaNEST program number |
| 4 | Laser | `3030` | |
| 5 | Material | `MS-S275` | |
| 6 | Thickness (mm) | `4` | |
| 7 | Sheet | `S100387` | |
| 8 | Sheets | `1` | Number of times the nest was cut (repeats) |
| 9 | Posted | `03/11/2026 08:05` | When it was posted in SigmaNEST |
| 10 | Customer | `Wrightbus` | |
| 11 | JN | `JN11609 PPC` | |
| 12 | Operator | `Evan Kennedy` | |
| 13 | Cut date | `10/11/2026` | |
| 14 | Start | `09:14` | Empty on rows 2+ of a whole-program entry |
| 15 | End | `09:32` | Empty on rows 2+ of a whole-program entry |
| 16 | Minutes | `18` | Empty on rows 2+ of a whole-program entry |
| 17 | Planned minutes | `17` | SigmaNEST planned cut time (× sheets). Same rule as Minutes. |
| 18 | Entry | `Split` or `Whole` | |
| 19 | Entered at | `10/11/2026 09:45` | When the operator pressed Submit |

Tips:
- Keep the table on its own sheet and do your reports on other sheets with formulas or pivot tables that point at `CutTimes`.
- **Total cutting minutes** = `SUM(CutTimes[Minutes])`, which counts each program once because whole-program entries only fill the first row.
- Avoid having the file open for editing all day on one PC. Excel Online and Power Automate cope with this, but a locked file is the most common reason a row fails to add.
