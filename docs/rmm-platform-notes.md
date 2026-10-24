# Deploying on common RMM platforms

The scripts are vendor-neutral PowerShell. The notes below cover what usually needs
attention on each platform. Menus and features change between versions, so check your
platform's current documentation.

## General

- Run as **SYSTEM** (the default for most RMM agents). The scripts don't need a logged-on user.
- Most agents run **Windows PowerShell 5.1**. All scripts are compatible with it, and
  PSScriptAnalyzer checks 5.1 syntax compatibility in CI.
- Pass parameters as script arguments. If your RMM only supports environment variables,
  map them at the top of a wrapper, for example `$Threshold = $env:threshold`.
- Alert on the exit code (see [exit-codes.md](exit-codes.md)), and keep the output as the
  script result so technicians can see the `RESULT:` line.

## NinjaOne (NinjaRMM)

- Add the script under Automation library, then run it ad hoc, from a policy schedule, or
  as a condition-based remediation.
- Use a **script result condition** on exit code ≠ 0 to raise alerts.
- If you want the result in a custom field, add `Ninja-Property-Set <field> <value>` in a
  wrapper (the cmdlet only exists on Ninja agents).

## Syncro

- Upload the script under Scripts, and set the run-as user to System.
- Syncro's PowerShell module (`Import-Module $env:SyncroModule`) provides helpers such as
  `Rmm-Alert` and `Log-Activity`. Call them from a small wrapper based on the exit code if
  you want alerts or asset activity entries.

## Datto RMM

- Create a **Component** (PowerShell), and declare parameters as component variables. These
  arrive as environment variables.
- For a **monitor component**, Datto RMM expects the result between
  `<-Start Result->` and `<-End Result->` markers, with a non-zero exit to alert. A wrapper
  can print the `RESULT:` line between those markers.

## ConnectWise RMM / Automate

- Add the script to the script library, or call it from an Automate script with
  *Execute Script (PowerShell)*. Use the exit code or output in a condition step to open a ticket.

## Testing before rollout

1. Run the script locally with `-WhatIf` (where supported) and `-Verbose`.
2. Deploy it to one test device as SYSTEM and confirm the exit code and output.
3. Roll out to a pilot group before the whole fleet.
