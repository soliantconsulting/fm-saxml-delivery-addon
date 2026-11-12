# Update the SaXMLDelivery add-on

Brings installed copies of the add-on up to date from whatever version they are on, and, if you ask it to, gives the pipeline's account the privileges it needs. The latest definitions come from `src/SaXMLDelivery.fmp12` in this repo, so check out the tag of the release you want first.

For each file it creates missing fields and puts them on the layout, creates missing scripts, and replaces the body of existing scripts in place, so the scripts keep their ids and names and references to them keep working. It only ever adds, and never deletes anything.

## What you need

- ADK installed
- An account in each file that is on the [Full Access] privilege set
- For the privileges: the name of the account the pipeline calls the add-on with (the export account, `FM_USERNAME` in the pipeline)

## Run it

Give every file of the solution, so it can see which files' table occurrences use which tables. Without `--apply` it does a dry run and changes nothing:

```bash
./update-saxml-addon.sh --username=<full access account> --host=<host> --export-account=<export account> FileOne,FileTwo,FileThree
```

Then apply. `--grant-privileges` applies the privilege grants; leave it out to update only the schema and scripts:

```bash
./update-saxml-addon.sh --username=<full access account> --host=<host> --export-account=<export account> FileOne,FileTwo,FileThree --apply --grant-privileges
```

If every file uses the same [Full Access] account and password, add `--credentials-from=fmnet://<host>/<one of the files>`. Every file then uses the password stored in the keychain for that one file, so you store it once instead of once per file.

A file without the add-on is skipped. Add `--install` to install it there instead, with no need for FileMaker Pro's Install Add-on: the script creates the `SaXMLDelivery` table and its table occurrence, the `SaXMLDelivery` script and layout folders, the `SaXMLDeliveryExecutionContext` layout and the base directory for `xmlFile`, and then the fields, layout objects and scripts as for an update. With `--export-account` the planned grants then include the add-on's own. It stops with a reason, and changes nothing in that file, when a table occurrence named `SaXMLDelivery` already uses another table, or the table is there without that table occurrence.

Hosted files are opened and worked on three at a time. `--jobs=<n>` changes that; lower it if a busy host answers some opens with error 802.

## What the privilege grants are

In the export account's privilege set, only where it lacks them:

- In a file with the add-on: View and Edit on `SaXMLDelivery` records, view only on its job fields and modifiable on `xmlFile`, executable only on `saxmlDelivery_createXml` and `saxmlDelivery_getVersion`, and records modifiable through the `SaXMLDeliveryExecutionContext` layout.
- In every file: View limited by the calculation `False`, with field access all, on each base table that another file's table occurrences use. Without it the SaXML of the other file silently leaves those table occurrences out; with `False` the account still sees no record. See "Multi-file solutions" in the main README.

With `--grant-field-access` as well, it also gives field access all on each of those base tables where the account's View is already yes or limited by something other than `False`. Without it, those tables only get a NOTE, because on a table with View yes field access all lets the account read every field.

It never lowers a grant. After the apply it reads every file again and reports anything still missing. It does not add the `fmrest` extended privilege or create a missing account; it names them for you to fix by hand.
