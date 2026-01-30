# fm-saxml-delivery-addon

Version 0.1.10

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
    - ```SaXMLDelivery``` table: View + Edit + 'modifiable' for ```xmlFile``` field ('no access' for all other fields)
    - All other tables: No access
  - Custom layout privileges
    - ```SaXMLDeliveryExecutionContext``` layout: View only (layout), Modifiable (records)
    - All other layouts: No access
  - Value lists
    - All no access
  - Custom script privileges
    - ```saxmlDelivery_createXml``` script: Executable only
    - All other scripts: No access
  - Extended privileges
    - fmrest
- Create an account that uses that privilege set
  - Suggested name: 'saxml'

Per server:

- Install a valid SSL certificate (required by the Data API)
- Enable the Data API

## Git Configuration

- Set up a repository with a pipeline that calls [fm-saxml-delivery](https://github.com/soliantconsulting/fm-saxml-delivery)
- You'll need to set up the appropriate repository variables in the repository
  - FM_HOST=https://fm.example.com
  - FM_USERNAME=user
  - FM_PASSWORD=password
  - FM_FILES=file,anotherFile,yetAnotherFile
- Run the pipeline on a schedule and/or ad hoc to have SaXML files created

## Upgrade Instructions

- Uninstall the add-on
  - This will remove the table, layout, and scripts
- Install the new add-on
  - This will add the necessary table, layout, and scripts
