// CASC Cut Summary: one row per job number, in the same layout as the "Cut" sheet of Job Card Timings Comparison.
// Reads the three tables of the CASC Cut Times master on SharePoint (Laser3030, Laser1040, Tube7000).
// All times are in minutes. Paste the master's link on the next line (File > Info > Copy path, without "?web=1").
let
    MasterUrl = "PASTE THE MASTER LINK HERE",

    Book = Excel.Workbook(Web.Contents(MasterUrl), true),
    Machines = Table.SelectRows(Book, each [Kind] = "Table" and List.Contains({"Laser3030", "Laser1040", "Tube7000"}, [Name])),
    Wanted = {"Machine", "Program", "JN", "Customer", "Cut date", "Minutes", "Planned minutes", "JN minutes", "JN planned minutes"},
    Rows = Table.Combine(List.Transform(Machines[Data], each Table.SelectColumns(_, Wanted, MissingField.UseNull))),

    ToNum = (x) => if x = null or x = "" then null else try Number.From(x, "en-GB") otherwise null,
    ToDate = (x) =>
        if x = null or x = "" then null
        else if x is date then x
        else if x is datetime then Date.From(x)
        else if x is number then Date.From(x)
        else try Date.FromText(Text.From(x), [Format = "dd/MM/yyyy", Culture = "en-GB"]) otherwise null,
    // "JN11609 PPC" -> 11609, "JN11826.2" -> 11826, "JN11460-B" -> 11460
    JobNo = (jn) =>
        let
            t = Text.Upper(Text.Trim(Text.From(jn ?? ""))),
            rest = Text.TrimStart(if Text.StartsWith(t, "JN") then Text.Middle(t, 2) else t),
            digits = Text.Combine(List.FirstN(Text.ToList(rest), each Text.Contains("0123456789", _)))
        in
            if digits = "" then null else Number.From(digits),

    Clean = Table.FromRecords(List.Transform(Table.ToRecords(Rows), (r) => [
        Job = JobNo(r[JN]),
        Customer = if r[Customer] = null then "" else Text.Trim(Text.From(r[Customer])),
        Program = Text.From(r[Program] ?? ""),
        Machine = Text.From(r[Machine] ?? ""),
        Date = ToDate(r[#"Cut date"]),
        // Older rows (before the JN columns existed) fall back to Minutes / Planned minutes
        Actual = (if ToNum(r[#"JN minutes"]) <> null then ToNum(r[#"JN minutes"]) else ToNum(r[Minutes])) ?? 0,
        Plan = (if ToNum(r[#"JN planned minutes"]) <> null then ToNum(r[#"JN planned minutes"]) else ToNum(r[#"Planned minutes"])) ?? 0
    ])),

    MachineSum = (t, m) => List.Sum(Table.SelectRows(t, each [Machine] = m)[Actual]) ?? 0,
    Grouped = Table.Group(Clean, {"Job"}, {
        {"Customer", each List.First(List.Select([Customer], each _ <> ""), ""), type text},
        {"Cut Date", each List.Max([Date]), type date},
        {"Programs", each List.Count(List.Distinct([Program])), Int64.Type},
        {"Plan Cut Time", each Number.Round(List.Sum([Plan]) ?? 0, 1), type number},
        {"3030", each Number.Round(MachineSum(_, "3030"), 1), type number},
        {"1040", each Number.Round(MachineSum(_, "1040"), 1), type number},
        {"TUBE", each Number.Round(MachineSum(_, "Tube 7000"), 1), type number}
    }),
    WithWaterjet = Table.AddColumn(Grouped, "Waterjet", each null, type number),
    WithTotal = Table.AddColumn(WithWaterjet, "Cut Total", each Number.Round([#"3030"] + [#"1040"] + [TUBE] + ([Waterjet] ?? 0), 1), type number),
    WithVar = Table.AddColumn(WithTotal, "Variance Time", each Number.Round([Plan Cut Time] - [Cut Total], 1), type number),
    WithPct = Table.AddColumn(WithVar, "Variance %", each if [Plan Cut Time] = 0 then null else [Variance Time] / [Plan Cut Time], Percentage.Type),
    Renamed = Table.RenameColumns(WithPct, {{"Job", "Job Number"}}),
    Typed = Table.TransformColumnTypes(Renamed, {{"Job Number", Int64.Type}}),
    Sorted = Table.Sort(Typed, {{"Cut Date", Order.Descending}, {"Job Number", Order.Descending}})
in
    Sorted
