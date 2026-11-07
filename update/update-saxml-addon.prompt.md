# Update the SaXML delivery add-on in installed files

Instructions for Claude Code (or another AI agent with the ADK `filemaker` command). Use them to update installed copies of the add-on to the latest version, from whatever version each is on, including the privilege sets the pipeline's account uses.

Needs an account on [Full Access] in each file. Never delete and re-create anything: update scripts, fields, layouts and privilege sets in place so references to them keep working.

## 1. Schema and scripts

1. Ask which files to update and the account name. Never ask for a password; the script uses the keychain, or shows a window that asks the user.
2. Run a dry run and show the plan to the user: `update/update-saxml-addon.sh --username=<account> [--host=<host>] <file>,<file>`
3. After the user confirms (and has backed the files up and closed Manage Database and the script editor), run it again with `--apply`. It reports "updated and verified" per file.

## 2. Privilege sets

The script does not touch privilege sets, because the one the pipeline uses has no fixed name. For each updated file:

1. Find the account the pipeline logs in with. Ask the user for its name; if they don't know, look for accounts that have the `fmrest` extended privilege (`filemaker help account read`) and ask which one it is. Never guess.
2. Read that account's privilege set (`filemaker help privilegeSet read`, with `"detail":true`) and use only that set. Most custom sets can execute `saxmlDelivery_createXml`, so executing it does not identify the pipeline's set.
3. Check what that set grants, and propose only what is missing:
   - Fields of the `SaXMLDelivery` table. If the set grants all fields, nothing is needed. If it lists fields individually, `jobStatus` and `jobMessage` need view only.
   - The script `saxmlDelivery_getVersion`, which clients use to read the add-on version without starting an export. A set gets it from its entry for that script, or else from its grant for scripts without an entry (`newScripts` in the read). If that is `noAccess`, the script needs executable only (`scripts: [{"name":"saxmlDelivery_getVersion","access":"executableOnly"}]`). A set that grants all scripts needs nothing.
   - Record access to base tables that table occurrences in other files are based on (see "Multi-file solutions" in the README). Read the table occurrences of every file in the solution (`filemaker help tableOccurrence read`) and collect the base tables that other files' table occurrences point to in this file. Each needs View on records; Edit, Create and Delete stay no, and field access stays none. Without it the SaXML of the referring file leaves those table occurrences out, with no error. This widens what the account can read, so list these grants apart from the others and apply them only if the user explicitly says yes to them.
   - Do not widen any other grant.
4. Show the plan per set. After the user confirms, run `update:privilegeSet` with only the grants that are missing (`filemaker help privilegeSet update`), then read the set back in a fresh process and check each grant: the fields, the script's effective access as in step 3, and the record access to the referenced base tables.

Report what was updated per file, what was already current, and anything skipped.
