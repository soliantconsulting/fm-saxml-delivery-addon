# fm-saxml-delivery-addon

Version 0.2.4

This add-on is a part of the SaXML delivery toolchain. It helps to automate the seamless generation of SaXML files for your FileMaker databases.

## Installation

Per developer workstation:

- Make the add-on available to FileMaker Pro.
  - If you haven't yet, download the .fmaddon file from the [https://github.com/soliantconsulting/fm-saxml-delivery-addon/releases] page.
  - Uncompress the downloaded zip file and locate the .fmaddon file in the "release" folder.
  - Double-click the .fmaddon file to make it available to FileMaker Pro.

Per FileMaker database file:

- Install add-on in the database file by going to layout mode (any layout) ➜ Add-ons tab ➜ Install Add-on (at bottom).
  - Installing the add-on will create:
    - ```SaXMLDelivery``` __table__ with ```xmlFile``` and other fields
    - ```SaXMLDeliveryExecutionContext``` __layout__ with ```xmlFile``` and other fields
      - This layout will be used by a git pipeline to generate SaXML.
      - The layout name must be SaXMLDeliveryExecutionContext.
      - The layout must contain an xmlFile field.
      - The layout table does not need to contain any records.
    - ```saxmlDelivery``` family of scripts
- Create a privilege set that can be used to call the ```saxmlDelivery_createXml``` script with the Data API
  - Suggested name: 'SaXML Delivery'
  - Custom record privileges
    - ```SaXMLDelivery``` table: View + Edit + 'modifiable' for ```xmlFile``` field; 'read only' for ```jobStatus``` and ```jobMessage``` ('no access' for all other fields)
    - Base tables that table occurrences in other files are based on: View 'limited' with the calculation `False` (Edit, Create and Delete no; field access none). See [Multi-file solutions](#multi-file-solutions).
    - All other tables: No access
  - Custom layout privileges
    - ```SaXMLDeliveryExecutionContext``` layout: View only (layout), Modifiable (records)
    - All other layouts: No access
  - Value lists
    - All no access
  - Custom script privileges
    - ```saxmlDelivery_createXml``` script: Executable only
    - ```saxmlDelivery_getVersion``` script: Executable only (optional; lets a client read the add-on version without starting an export)
    - All other scripts: No access
  - Extended privileges
    - fmrest
- Create an account that uses that privilege set
  - Suggested name: 'saxml'

### Multi-file solutions

`saxmlDelivery_createXml` runs with full access in its own file, but FileMaker opens the files that its external data sources point to with the pipeline account's own privilege set. If that set has no access to the records of a base table, the SaXML leaves out every table occurrence based on that table, and the relationships, layouts and value lists that use them point at table occurrences that are not there. The export reports no error.

So in every file the solution uses:

- The pipeline account must exist, with the same name and password, on a privilege set like the one above.
- That set needs View set to 'limited', with the calculation `False`, on each base table that table occurrences in other files are based on. Edit, Create and Delete stay no, field access stays none, and it needs no layout access.

With 'limited' and `False` the table counts as accessible, so its table occurrences stay in the SaXML, but the account can see no record of it. Plain View (yes) also works, but lets the account read those records if it is ever given a layout on them. A file that only references others, and is referenced by none, needs no extra table access.

The update script in `update/` finds these tables and sets them for you: give it every file of the solution with `--export-account=<the pipeline's account>`, and `--grant-privileges` to apply.

Per server:

- Install a valid SSL certificate (required by the Data API)
- Enable the Data API

## How it runs

The ```saxmlDelivery_createXml``` script is asynchronous when the file is hosted, because the Data API times out a request after 5 minutes:

- The script creates a job record and starts the export in a Perform Script on Server session that it does not wait for. It returns right away with ```{ errorCode, message, data { recordId, xmlFieldName, addonVersion, jobStatus } }``` where ```jobStatus``` is ```running```.
- The caller polls the record on the ```SaXMLDeliveryExecutionContext``` layout until ```jobStatus``` is ```done``` or ```error```. On ```error```, ```jobMessage``` holds the error code and text.
- The server session fills ```xmlFile```, ```timeToCreate``` and ```timeToUpload``` before it sets ```jobStatus``` to ```done```.
- If the file is not hosted, the export runs in the current session and the result also holds ```timeToCreate``` and ```timeToUpload```.
- If the pipeline account cannot view its own ```SaXMLDelivery``` record, the job never reports ```done``` and the caller polls until it times out.
- ```saxmlDelivery_getVersion``` is a read-only script that takes no parameter, creates no record and starts no export. It returns ```{ errorCode: 0, message: "", data: { addonVersion } }```. Call it over the Data API on the ```SaXMLDeliveryExecutionContext``` layout to read the installed add-on version.
- ```sizeInBytes_c``` is the size of the file in ```xmlFile```. It is empty when the container is empty, so to find records that still hold an xml file, search ```sizeInBytes_c``` for ```>0``` on the ```SaXMLDeliveryExecutionContext``` layout.

## Git Configuration

- Set up a repository with a pipeline that calls [fm-saxml-delivery](https://github.com/soliantconsulting/fm-saxml-delivery)
- You'll need to set up the appropriate repository variables in the repository
  - FM_HOST=https://fm.example.com
  - FM_USERNAME=user
  - FM_PASSWORD=password
  - FM_FILES=file,anotherFile,yetAnotherFile
- Run the pipeline on a schedule and/or ad hoc to have SaXML files created

## Upgrade Instructions

- Run the update script in `update/` (see its README). It updates installed files in place from any earlier version, without removing anything. With `--export-account` it also sets the pipeline account's privileges.
- Or, uninstall the add-on and install the new one
  - This will remove and re-add the table, layout, and scripts, which breaks any references to them
