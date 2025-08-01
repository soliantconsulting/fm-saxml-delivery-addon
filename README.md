# fm-saxml-delivery-addon

This add-on is a part of the SaXML delivery toolchain. It helps to automate the seamless generation of SaXML files for your FileMaker databases.

## Installation

Per file:

- Install add-on in the file
  - Note that you don't need to apply the add-on to any of the layouts in your file
  - Installing the add-on will create:
    - ```SaXMLDelivery``` __table__ with ```xmlFile``` and other fields
    - ```SaXMLDeliveryExecutionContext``` __layout__ with ```xmlFile``` and other fields
      - This layout will be used by a git pipeline to generate SaXML.
      - The layout name must be SaXMLDeliveryExecutionContext.
      - The layout must contain an xmlFile field.
      - The layout table does not need to contain any records.
    - ```saxmlDelivery``` family of scripts
- Create an account that can be used to call the ```saxmlDelivery_createXml``` script with the Data API ("fmrest" extended privilege)

Per server:

- Install a valid SSL certificate (required by the Data API)
- Enable the Data API

## Git configuration

- Set up a repository with a pipeline that calls [fm-saxml-delivery](https://github.com/soliantconsulting/fm-saxml-delivery)
- You'll need to set up the appropriate repository variables in the repository
  - FM_HOST=https://fm.example.com
  - FM_USERNAME=user
  - FM_PASSWORD=password
  - FM_FILES=file,anotherFile,yetAnotherFile
- Run the pipeline on a schedule and/or ad hoc to have SaXML files created

## Upgrade instructions

- Uninstall the add-on
  - This will remove the table, layout, and scripts
- Install the new add-on
  - This will add the necessary table, layout, and scripts
