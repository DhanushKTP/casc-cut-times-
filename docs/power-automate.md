# Power Automate flows

You need two flows. Both start with **When an HTTP request is received**, which is a Premium trigger. In each trigger, set **Who can trigger the flow** to **Anyone**: the address contains its own secret key, and only Netlify knows it.

---

## Flow 1: "CASC Cut Times – add rows" (main)

Netlify calls this when an operator submits. It adds the rows to the master sheet and then reports back to the app.

### Trigger: When an HTTP request is received

Method: **POST**. Request Body JSON Schema:

```json
{
  "type": "object",
  "properties": {
    "submissionId": { "type": "string" },
    "program": { "type": "string" },
    "machine": { "type": "string" },
    "operator": { "type": "string" },
    "confirmUrl": { "type": "string" },
    "confirmToken": { "type": "string" },
    "rows": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "Submission ID": { "type": "string" },
          "Line": { "type": "integer" },
          "Machine": { "type": "string" },
          "Program": { "type": "string" },
          "JN": { "type": "string" },
          "Customer": { "type": "string" },
          "Item": { "type": "string" },
          "Material": { "type": "string" },
          "Thickness (mm)": {},
          "Sheet / profile": { "type": "string" },
          "Sheets / tubes": { "type": "integer" },
          "Posted": { "type": "string" },
          "Operator": { "type": "string" },
          "Cut date": { "type": "string" },
          "Start": { "type": "string" },
          "End": { "type": "string" },
          "Minutes": {},
          "Paused minutes": {},
          "Planned minutes": {},
          "Entry": { "type": "string" },
          "Timing": { "type": "string" },
          "Entered at": { "type": "string" }
        }
      }
    }
  },
  "required": ["submissionId", "program", "rows", "confirmUrl", "confirmToken"]
}
```

Don't add a **Response** action. Without one, the flow answers Netlify straight away with 202 and carries on in the background.

### Scope: "Try"

Inside it:

1. **Switch** on `machine` (from the trigger). There's one sheet and one table per machine in the master workbook:

   | Case equals | Table |
   |---|---|
   | `3030` | `Laser3030` (sheet "3030") |
   | `1040` | `Laser1040` (sheet "1040") |
   | `Tube 7000` | `Tube7000` (sheet "Tube 7000") |

   In **each case**, add **Apply to each** over `rows` (from the trigger). In its **Settings**, turn on **Concurrency control** and set it to **1**, so the rows go in in order.
   - Inside it: **Excel Online (Business) → Add a row into a table**
     - Location: your SharePoint site
     - Document Library: where the workbook is
     - File: the master workbook
     - Table: that case's table
     - Map each column to the field with the same name. If the designer doesn't offer them, use expressions such as `items('Apply_to_each')?['Customer']`. Names with spaces work the same way: `items('Apply_to_each')?['Cut date']`.
   - **Default case** (a machine the workbook doesn't know yet): add a **Terminate** action with status **Failed**. That sends the run to "Catch", so you get an email instead of losing the rows.
2. **HTTP** (after the Switch)
   - Method: `POST`
   - URI: `confirmUrl` (from the trigger)
   - Headers: `Content-Type` = `application/json`
   - Body:
     ```
     {
       "submissionId": "@{triggerBody()?['submissionId']}",
       "program": "@{triggerBody()?['program']}",
       "confirmToken": "@{triggerBody()?['confirmToken']}",
       "status": "synced"
     }
     ```

### Scope: "Catch"

Add it after "Try". On its **⋯ → Settings → Run after**, tick only **has failed** and **has timed out** for "Try".

1. **Office 365 Outlook → Send an email (V2)**
   - To: `dhanush@casconline.com`
   - Subject: `Cut times NOT added: program @{triggerBody()?['program']}`
   - Body: program, operator and submission ID, plus a link to the run. The expression `concat('https://make.powerautomate.com/environments/', workflow()?['tags']?['environmentName'], '/flows/', workflow()?['name'], '/runs/', workflow()?['run']?['name'])` builds the link.
2. **HTTP**: same as above, but with `"status": "failed"` and `"message": "Power Automate could not add the rows"`. The tablet then shows **Not sent** instead of **Waiting**.

Save the flow, open the trigger and copy the **HTTP URL**. That goes in **`FLOW_SUBMIT_URL`** in Netlify.

---

## Flow 2: "CASC Cut Times – notify"

This flow only sends emails. Netlify calls it when a submission couldn't be handed to the main flow, and every 10 minutes if anything has gone 30 minutes without being confirmed. It's kept separate so it still works when the main flow is the problem.

### Trigger: When an HTTP request is received

```json
{
  "type": "object",
  "properties": {
    "to": { "type": "string" },
    "subject": { "type": "string" },
    "text": { "type": "string" },
    "html": { "type": "string" }
  }
}
```

### Action: Office 365 Outlook → Send an email (V2)

- To: `to` (from the trigger). That's `NOTIFY_EMAIL` from Netlify, so you can change the address without touching the flow.
- Subject: `subject`
- Body: `html`

Copy this flow's HTTP URL into **`FLOW_NOTIFY_URL`** in Netlify.

---

## Testing the flows before the tablet

In PowerShell (replace the URL with the main flow's):

```powershell
$body = @{
  submissionId = 'test-1'; program = 'TEST'; machine = '3030'; operator = 'Test'; confirmUrl = 'https://example.com'; confirmToken = 'x'
  rows = @(@{ 'Submission ID'='test-1'; Line=1; Machine='3030'; Program='TEST'; Customer='Test'; JN='JN0'; Item='JN0'; Operator='Test'; 'Cut date'='10/11/2026'; Start='09:00'; End='09:10'; Minutes=10; 'Paused minutes'=0; Entry='Whole'; Timing='Typed' })
} | ConvertTo-Json -Depth 4
Invoke-RestMethod -Method Post -Uri '<FLOW_SUBMIT_URL>' -ContentType 'application/json' -Body $body
```

The row should appear on the `3030` sheet. The confirm step fails, because example.com isn't the app, and that triggers the Catch email, which tests that branch too. Delete the test row afterwards.
