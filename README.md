# CASC Cut Times

A tablet app for the laser operators. It lists every program nested in SigmaNEST, and the operator types the cut start and end times (for the whole program, or split per customer/JN). Each submission is added to the master Excel sheet on SharePoint through Power Automate.

```
SigmaNEST SQL ──▶ Sync script on the office PC (every 2 min, read-only, outbound only)
                        │  POST /api/sync
                        ▼
Tablet (Chrome) ◀──▶ Netlify site + functions ──▶ Netlify Blobs (programs, submissions)
                        │  POST to Power Automate (Submit)
                        ▼
                 Power Automate "main" flow ──▶ Master Excel table on SharePoint
                        │  POST /api/confirm  ("In SharePoint")
                        └─ on failure: emails you
Netlify, every 10 min: anything not confirmed after 30 min ──▶ "notify" flow ──▶ emails you
```

Nothing is resent automatically. If something doesn't reach the sheet you get an email and fix it yourself.

## What's in this repo

| Folder | What it is |
|---|---|
| `public/` | The tablet app (plain HTML/CSS/JS, no build step) |
| `netlify/functions/` | The server side: login, program list, submit, confirm, sync, the 10-minute check |
| `netlify/shared/core.mjs` | Shared helpers (settings, storage, time maths) |
| `sync-agent/` | The PowerShell script that runs on the office PC and reads SigmaNEST |
| `docs/` | Power Automate flows and the master sheet layout |

## Setup, in order

### 1. Netlify site

1. In Netlify: **Add new site → Import an existing project → GitHub → `casc-cut-times`**.
2. Build settings: leave the build command empty. The publish directory is `public` (read from `netlify.toml`).
3. **Site configuration → Environment variables**, add:

| Variable | Example | What it does |
|---|---|---|
| `SITE_PIN` | `482913` | The PIN operators type on the tablet. Use 6 digits or more. |
| `OPERATORS` | `Nathan McCorry,David Pollack,Evan Kennedy,Jonny Oliver` | Names on the "Who's cutting?" screen, comma separated |
| `SESSION_SECRET` | long random text | Signs tablet logins |
| `CONFIRM_SECRET` | long random text | Signs the "rows added" call from Power Automate |
| `SYNC_KEY` | long random text | Password the sync script uses. The same value goes in `sync-agent/config.json` |
| `FLOW_SUBMIT_URL` | from step 3 | The main flow's HTTP trigger URL |
| `FLOW_NOTIFY_URL` | from step 3 | The notify flow's HTTP trigger URL |
| `NOTIFY_EMAIL` | `dhanush@casconline.com` | Who gets the "not confirmed" emails |
| `START_DATE` | `2026-01-01` | Programs before this date aren't shown |
| `NOTIFY_AFTER_MINUTES` | `30` | Optional, default 30 |
| `SESSION_HOURS` | `12` | Optional: how long a tablet stays logged in |

For long random text, run this in PowerShell and copy the result: `[guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')`

4. Deploy. The site opens on the PIN screen, but the program list stays empty until the sync script runs (step 4).

### 2. Master Excel sheet

Create the workbook on SharePoint with a table named **`CutTimes`** and exactly these column headers. See [docs/master-sheet.md](docs/master-sheet.md).

### 3. Power Automate

Build two flows, **main** and **notify**, following [docs/power-automate.md](docs/power-automate.md). Copy each flow's HTTP URL into `FLOW_SUBMIT_URL` and `FLOW_NOTIFY_URL` in Netlify, then redeploy (**Deploys → Trigger deploy**).

### 4. Sync script on the office PC

1. Copy the `sync-agent` folder to the PC, for example `C:\CASC\CutTimesSync`.
2. Copy `config.example.json` to `config.json` and fill it in:
   - `SqlServer`: the SigmaNEST SQL instance, as in SQL Server Management Studio
   - `Database`: `SNDBase`
   - `UseWindowsAuth`: `true` to connect as your Windows login. Set it to `false` and fill in `SqlUser` and `SqlPassword` to use a read-only SQL login (recommended).
   - `SiteUrl`: your Netlify address
   - `SyncKey`: the same value as `SYNC_KEY` in Netlify
   - `StartDate`: `2026-01-01`
3. Test it: `powershell -ExecutionPolicy Bypass -File CascCutTimeSync.ps1 -Test`
4. Run it once by hand without `-Test`. The first run uploads every program completed since `StartDate`, a month at a time, so it takes a few minutes.
5. Install the 2-minute schedule: `powershell -ExecutionPolicy Bypass -File install-task.ps1`

Logs are written to `sync-agent\logs\`. If the PC is off, the tablet still works and times can still be entered, but new programs won't appear until the PC is back on. The header on the tablet shows when the list was last updated.

### 5. Tablet

Open the Netlify address in Chrome, then tap **⋮ → Add to Home screen**. The icon opens full-screen.

### 6. First test

Pick one program, enter times, submit, and check:
- the tablet shows **In SharePoint** within a few seconds
- the rows appear in the `CutTimes` table

## How the data works

- **Programs** come from `dbo.Program` (waiting) and `dbo.ProgArchive` with TransType `SN102` (completed). Parts come from `dbo.PIP` / `dbo.PIPArchive`, the customer from `dbo.Wo` / `dbo.WOArchive`, and next op from `Part.Data1`.
- A program is identified by its **program number**. Repeats (the same nest cut several times) are one program with a sheet count, and get one entry.
- **One entry per program.** Once submitted, the program is locked, and a second tablet trying the same program is refused.
- **Master sheet rows:** one row per customer/JN line. With a split entry every row has its own times. With a whole-program entry, the times and minutes go on the first row only and the other rows are left empty, so the Minutes column adds up correctly.
- A permanent copy of every submission is kept in Netlify Blobs (store `submissions`, key `sub-<program>`).

## Local check

`npm run check` checks the JavaScript syntax. There is no build step.
