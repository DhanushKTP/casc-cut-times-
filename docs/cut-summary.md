# Cut summary (per job) for Job Card Timings Comparison

The *Cut* sheet of **Job Card Timings Comparison.xlsx** is filled from the master by Power Query, one row per job number:

| Job Number | Customer | Cut Date | Programs | Plan Cut Time | 3030 | 1040 | TUBE | Waterjet | Cut Total | Variance Time | Variance % |
|---|---|---|---|---|---|---|---|---|---|---|---|

- All times are in **minutes**, like the rest of the Job Card workbook.
- **Job Number** is the number in the JN: `JN11609 PPC`, `JN11609 ECOAT` and `JN11609.2` all count as job 11609.
- **Plan Cut Time** is the planned cut time from SigmaNEST / TRUMPF. **3030 / 1040 / TUBE** are the actual times from the app.
- **Cut Date** is the last date the job was cut.
- **Waterjet** is left empty: the app doesn't time the waterjet.
- **Variance** = Plan − Actual, the same as the existing sheet.
- If one program is timed as a whole and carries several jobs, its minutes are shared between them by planned time (the master's `JN minutes` column).

## One-time setup

1. **Master workbook:** on each of the sheets 3030, 1040 and Tube 7000, type `JN minutes` in **W1** and `JN planned minutes` in **X1**. The table grows to take them in.
2. Once the columns are there, add the Netlify variable `MASTER_JN_COLUMNS` = `yes` (context: production, scope: functions) and redeploy. Until then the site leaves the two columns out, because Power Automate fails on a column the table doesn't have.
3. **Get the master's link:** open the master in the Excel desktop app, go to **File → Info → Copy path**, and delete `?web=1` from the end.
4. **Job Card workbook (desktop Excel):** go to **Data → Get Data → From Other Sources → Blank Query → Advanced Editor**. Paste [cut-summary.pq](cut-summary.pq) and put the link on the `MasterUrl` line. If Excel asks how to sign in, choose **Organizational account → Sign in**, then **Connect**.
5. Name the query `Cut Summary`, then **Close & Load To… → Table → New worksheet**.
6. To keep it fresh, go to **Data → Queries & Connections**, right-click **Cut Summary → Properties**, and tick **Refresh data when opening the file** (and **Refresh every 30 minutes** if you like).

Excel for the web can't refresh a query that reads another SharePoint file, so refresh it in desktop Excel (**Data → Refresh All**).
