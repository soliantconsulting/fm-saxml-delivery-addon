# Update the SaXML delivery add-on in installed files

Instructions for Claude Code (or another AI agent with the ADK `filemaker` command). Use them to update installed copies of the add-on to the latest version, from whatever version each is on, including the privileges of the account the pipeline uses.

Needs an account on [Full Access] in each file. Never delete and re-create anything.

1. Ask which solution to update: every file in it, the host, the [Full Access] account name, and the export account (the account the pipeline calls the add-on with, `FM_USERNAME` in its pipeline). Never ask for a password; the script uses the keychain, or shows a window that asks the user. If the user doesn't know the export account, look for accounts with the `fmrest` extended privilege (`filemaker help account read`) and ask which one it is. Never guess.
2. Run a dry run and show the plan to the user: `update/update-saxml-addon.sh --username=<account> --host=<host> --export-account=<export account> <file>,<file>,...`. List every file of the solution, so the script can find the base tables that other files' table occurrences use.
3. Point out the grants of View limited by `False` on tables outside the add-on separately: they change access to the solution's own tables, although no record becomes visible. Ask whether to apply them.
4. After the user confirms (and has backed the files up and closed Manage Database and the script editor), run it again with `--apply`, plus `--grant-privileges` if the user said yes to the grants. It reports "updated and verified" or "privileges applied" per file, and checks the privileges again at the end.
5. Report what was updated per file, what was already current, and every PROBLEM, NOTE and WARNING line it printed (a missing account, a missing `fmrest`, a file of the solution that wasn't in the run).
