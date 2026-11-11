# CASC Cut Times

A tablet app for the laser operators. It lists every program nested in SigmaNEST for the flat lasers (TruLaser 3030 / 1040), and every production package saved for the TruLaser Tube 7000 under `S:\TruLaser7000`. The operator times each one with a stopwatch (Start / Pause / Resume / Stop) or types the start and end times, for the whole program or split per customer/JN (flat) or per tube type (tube). Each submission is added to the master Excel sheet on SharePoint through Power Automate.

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

Copy the `sync-agent` folder to the PC (for example `Documents\CASC Cut Times sync`) and follow its `READ ME.txt`:

1. `1 - Set up and test.bat` asks for the SQL Server (default `CASC-APPSRV-02\SIGMANEST`), the database (`SNDBase`), the website and the sync key. The key is saved encrypted for your Windows user. It then tests both connections without sending anything.
2. `2 - Send programs now.bat` sends everything once. The first run goes back to 1 Jan, a month at a time.
3. `3 - Turn on automatic sync.bat` runs it every 2 minutes, 06:00-18:00, Monday to Friday. It runs hidden, wakes the PC from sleep and runs on battery.

`Check cut times sync.bat` shows whether it's running, and `Stop cut times sync.bat` switches it off. Each run writes a line to `sync_log.txt`. The sync only reads SigmaNEST, without locking its tables, and only sends when something has changed (plus a small "still here" every 8 minutes). If the PC is off, the tablet still works, but new programs won't appear until it's back on. The tablet header shows when the list was last updated.

### 5. Tablet

Open the Netlify address in Chrome, then tap **⋮ → Add to Home screen**. The icon opens full-screen.

### 6. First test

Pick one program, enter times, submit, and check:
- the tablet shows **In SharePoint** within a few seconds
- the rows appear in the `CutTimes` table

## How the data works

- **Tube laser packages** come from the `.TPP` files under the tube folder. One `.TPP` = one entry. The JN comes from the job folder (for example `JN11460-B`). Tubes, parts and TRUMPF's machine time per part come from inside the file. The customer comes from the drawing path saved in the file (`…\Customers v2\<customer>\…`), or from SigmaNEST by JN.
- **Stopwatch:** the timer is kept on the server (store `timers`), so it carries on when the tablet sleeps, reloads or another tablet opens the program. The minutes count running time only, and the paused time is recorded separately.
- **Programs** come from `dbo.Program` (waiting) and `dbo.ProgArchive` with TransType `SN102` (completed). Parts come from `dbo.PIP` / `dbo.PIPArchive`, the customer from `dbo.Wo` / `dbo.WOArchive`, and next op from `Part.Data1`.
- A program is identified by its **program number**. Repeats (the same nest cut several times) are one program with a sheet count, and get one entry.
- **One entry per program.** Once submitted, the program is locked, and a second tablet trying the same program is refused.
- **Master sheet rows:** one row per customer/JN line. With a split entry every row has its own times. With a whole-program entry, the times and minutes go on the first row only and the other rows are left empty, so the Minutes column adds up correctly.
- A permanent copy of every submission is kept in Netlify Blobs (store `submissions`, key `sub-<program>`).

## Local check

`npm run check` checks the JavaScript syntax. There is no build step.
