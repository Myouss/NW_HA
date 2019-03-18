# SAP Deployment Templates & Functions -  CHANGELOG
All notable changes to this project will be documented in this file.

Note that all items listed are for all functions deployed in 'sapdeploy' unless specified by
putting the name of the function affected in brackets at the end of the line.

Functionality currently live:

SAP ASE Linux Template (sap_ase)
SAP ASE Windows Template (sap_ase-win)
SAP HANA Template - Scaleup & Scaleout (sap_hana)
SAP HANA HA Template (sap_hana_ha)
SAP HANA Scaleout with Standby node support (sap_hana_scaleout)
SAP MaxDB Linux Template (sap_maxdb)
SAP MaxDB Windows Template (sap_maxdb-win)
SAP NetWeaver Linux Template (sap_nw)
SAP NetWeaver Windows Template (sap_nw-win)
Pacemaker GCP Addons (pacemaker-gcp)

## [3.4] 2018-09-12
### Added
- Bug fixes
- Released sap_maxdb Linux template & associated functions
- Released sap_maxdb Windows template & associated functions


### Changed
- Removed workarounds which are no long required.

---

## [3.3] 2018-06-12
### Added
- Released sap_nw Linux template & associated functions
- Released sap_nw-win Windows template & associated functions
- Added code to ignore unexpected errors from Google API, which could cause problems with STONITH (sap_hana_ha)

---

## [3.2] 2018-06-11
### Fixed
- Fixed SLES HA cluster secondary node join when using older versions of SLES (sap_hana_ha)
- Added code to ignore unexpected errors from Google API, which could cause problems with STONITH (sap_hana_ha)

### Changed
- Improved deployment time (sap_hana_ha)
- Added a check to see if the VIP is already in use before assigning (sap_hana_ha)

----

## [3.1] 2018-06-05
### Added
- Added an option in all templates to customise the UID/GID
- Added an option in all templates to add a network tag to the instances
- Added an option in all templates to deploy without a public IP (assuming network-tag is present and configured properly - Otherwise the deployment will fail due to licensing & repositories)

### Changed
- Added some protection from those that deploy incorrectly by not calling the web version of the python script. Some additional work is required to make it work without a schema file but correctly supplied values.

### Fixed
- Fixed UID/GID issue which came in with new SuSE image on May 23rd by changing the default UID to 900. UID remains automatic unless specified
- Changed the order of the deployment to fix bugs introduced by GSDK being removed from the SLES images on May 23rd
- Added '-quiet' flag to logging functions so the deployments won't fail if there is a problem writing the logs (e.g, Stackdriver Logging API isn't enabled)

----

## [3.0] 2018-06-04
### Added
- Released sap_hana_ha Linux template & associated functions.
- Released sap_ase Windows template & associated functions
- Released sap_ase Linux template & associated functions
