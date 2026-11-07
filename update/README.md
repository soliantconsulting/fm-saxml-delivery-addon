# Update the SaXMLDelivery add-on

Brings installed copies of the add-on up to date from whatever version they are on. The latest definitions come from `src/SaXMLDelivery.fmp12` in this repo, so check out the tag of the release you want first.

For each file it creates missing fields and puts them on the layout, creates missing scripts, and replaces the body of existing scripts in place, so the scripts keep their ids and names and references to them keep working. It never deletes anything.

## What you need

- ADK installed
- An account in each file that is on the [Full Access] privilege set

## Part 1: Run the update script

Without `--apply` it does a dry run:

```bash
./update-saxml-addon.sh --username=<account> --host=<host> FileOne,FileTwo,FileThree --apply
```

## Part 2: Complete the update using an AI agent

The script does not update privilege sets. To update those too, ask your AI agent from this repo: "Follow update/update-saxml-addon.prompt.md to update the SaXML add-on in <files>". It runs this script, then finds the privilege sets the pipeline's account uses and grants access to the new fields after you confirm. It also checks that the account can view the records of base tables that other files' table occurrences are based on (see "Multi-file solutions" in the main README), and asks separately before granting that.
