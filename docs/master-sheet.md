# Master sheet

One Excel workbook on SharePoint, for example `Laser Cut Times.xlsx`, with one **table** (Insert → Table, tick "My table has headers") named **`CutTimes`**. Power Automate can only add rows to a table, not to a plain range.

Each submission adds one row per **line**:
- **Flat lasers (3030 / 1040):** one line per customer/JN on the program.
- **Tube laser (Tube 7000):** one line per tube type in the production package, for example "Tube 1 × 13".

The column headers must match exactly, in this order:

| # | Column | Flat laser example | Tube laser example | Notes |
|---|---|---|---|---|
| 1 | Submission ID | `256bcede-…` | `9a1f…` | Same on every row of one submission. Links the row back to the app. |
| 2 | Line | `1` | `1` | 1, 2, 3… within the submission |
| 3 | Machine | `3030` | `Tube 7000` | |
| 4 | Program | `54533` | `JN11929_25x25x1point5_MS_SHS` | SigmaNEST program, or the tube production package |
| 5 | JN | `JN11609 PPC` | `JN11929` | |
| 6 | Customer | `Wrightbus` | `InspecVision Ltd` | |
| 7 | Item | `JN11609 PPC` | `Tube 1 × 2` | What this row covers |
| 8 | Material | `MS-S275` | `25x25x1.5 MS SHS` | Tube: the profile from the package name |
| 9 | Thickness (mm) | `4` | | Flat laser only |
| 10 | Sheet / profile | `S100387` | `1_250X250X30_1_15` | |
| 11 | Sheets / tubes | `1` | `3` | Repeats on the flat laser, number of tubes on the tube laser |
| 12 | Posted | `03/11/2026 08:05` | `10/11/2026 10:18` | Posted in SigmaNEST / package saved |
| 13 | Operator | `Evan Kennedy` | `David Pollack` | |
| 14 | Cut date | `10/11/2026` | `11/11/2026` | |
| 15 | Start | `09:14` | `12:35` | Empty on rows 2+ of a whole entry |
| 16 | End | `09:32` | `13:10` | Empty on rows 2+ of a whole entry |
| 17 | Minutes | `18` | `31.5` | Running time. The stopwatch gives one decimal. Empty on rows 2+ of a whole entry. |
| 18 | Paused minutes | `0` | `3.5` | Time the stopwatch was paused between Start and End |
| 19 | Planned minutes | `49.5` | `8.2` | Planned cut time from SigmaNEST / TRUMPF, one decimal (49:30 = 49.5). Same rule as Minutes. |
| 20 | Entry | `Split by customer` | `Whole` | `Whole`, `Split by customer` or `Split by tube` |
| 21 | Timing | `Typed` | `Stopwatch` | Whether the times came from the stopwatch or were typed |
| 22 | Entered at | `10/11/2026 09:45` | `11/11/2026 13:11` | When the operator pressed Submit |

Tips:
- Keep the table on its own sheet and do your reports on other sheets with formulas or pivot tables that point at `CutTimes`.
- **Total cutting minutes** = `SUM(CutTimes[Minutes])`, which counts each program once because whole entries only fill the first row.
- Avoid having the file open for editing all day on one PC. Excel Online and Power Automate cope with this, but a locked file is the most common reason a row fails to add.
