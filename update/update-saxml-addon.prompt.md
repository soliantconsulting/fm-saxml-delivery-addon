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
3. Check how that set treats the fields of the `SaXMLDelivery` table. If it grants all fields, nothing is needed. If it lists fields individually, `jobStatus` and `jobMessage` need view only. Do not widen any other grant.
4. Show the plan per set. After the user confirms, run `update:privilegeSet` with only the fields that need it (`filemaker help privilegeSet update`), then read the set back in a fresh process to verify.

Report what was updated per file, what was already current, and anything skipped.
