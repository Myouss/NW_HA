#!/bin/bash
# ------------------------------------------------------------------------
# Copyright 2018 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Description:  Temporary SAP HANA on GCE & Intel Optane Deployment Script
# Build Date:   Fri Mar 15 13:25:46 GMT 2019
# ------------------------------------------------------------------------

ZONE="us-central1-f"

echo "
SAP HANA on GCE & Intel Optane Pilot - Deployment Script
---------------------------------------------------------
This deployment script is only intended to be used for the Intel Optane on Google
Cloud Platform pilot. Once the pilot moves into Beta, this script will be replaced
with a Google Cloud Deployment Manager template.

DEPLOYMENT LOG:
--------------"

#pre check on images
if [[ -z "${imageName}" ]]; then
  imageName="sles-15-sap-v20180816"
fi

if [[ -z "${imageProject}" ]]; then
  imageProject="suse-sap-cloud"
fi

if ! gcloud compute images describe "${imageName}" --project="${imageProject}" &>/dev/null; then
  echo "ERROR - Unable to find image:${imageName} in project ${imageProject}"
  return 1 2> /dev/null || exit 1
fi 

# Check key variables are filled in correctly
if [[ -z "${instanceName}" ]] || [[ -z "${subnet}" ]]; then 
  echo "ERROR - instanceName or subnet is undefined"
  return 1 2> /dev/null || exit 1
fi

# Check instanceType is valid and set the correct disk sizes 
case "${instanceType}" in
  "n1-highmem-96")
    datasize=7000
    backupsize=7248
    aepsize=2988
    ;;
  "n1-megamem-96-aep")
    datasize=12000
    backupsize=13866
    aepsize=5500
    ;;
  *)
    echo "ERROR - instanceType must be either n1-highmem-96 or n1-megamem-96-aep"
    return 1 2> /dev/null || exit 1
    ;;
esac

# Check SAP HANA related variables
if [[ -z "${sap_hana_deployment_bucket}" ]]; then
  echo "WARNING - sap_hana_deployment_bucket is undefined. This will result in a provisioned GCE instance ready for SAP HANA, but without SAP HANA installed."
elif ! gsutil ls gs://"${sap_hana_deployment_bucket}"/51*.exe &>/dev/null; then
  echo "WARNING - sap_hana_deployment_bucket doesn't contain SAP HANA installation media. This will result in a provisioned GCE instance ready for SAP HANA, but without SAP HANA installed."
fi 
if [[ -z "${sap_hana_sid}" ]] || [[ -z "${sap_hana_instance_number}" ]] || [[ -z "${sap_hana_sidadm_password}" ]] || [[ -z "${sap_hana_system_password}" ]]; then 
  echo "WARNING - Not all sap_hana variables are defined. This will result in a provisioned GCE instance ready for SAP HANA, but without SAP HANA installed."
fi

# Create disks
echo "INFO - Creating ${datasize}GB pd-ssd disk called ${instanceName}-pdssd in ${ZONE}"
if ! gcloud compute disks create "${instanceName}"-pdssd --size="${datasize}" --type=pd-ssd --zone="${ZONE}" -q &>/dev/null; then
  echo "ERROR - Failed to create disk data/log disk ${instanceName}-pdssd. Please check the disk doesn't already exist and ensure you have enough quota to provision a ${datasize}GB PD-SSD disk in ${ZONE}"
  return 1 2> /dev/null || exit 1
fi 

echo "INFO - Creating ${backupsize}GB pd-standard disk called ${instanceName}-backup in ${ZONE}"
if ! gcloud compute disks create "${instanceName}"-backup --size="${backupsize}" --type=pd-standard --zone="${ZONE}" -q &>/dev/null; then
  echo "ERROR - Failed to create disk data/log disk ${instanceName}-backup. Please check the disk doesn't already exist and ensure you have enough quota to provision a ${backupsize}GB PD-STANDARD disk in ${ZONE}"
  return 1 2> /dev/null || exit 1
fi 

## Create VM using Cascadelake
echo "INFO - Creating VM ${instanceName} in ${ZONE} with ${aepsize}GB of Intel Optane DC"
gcloud alpha compute instances create "${instanceName}" --machine-type="${instanceType}" --local-nvdimm size="${aepsize}" \
--zone=${ZONE} --subnet "${subnet}" --min-cpu-platform="Intel Cascadelake" --image=${imageName} \
--image-project=${imageProject} --boot-disk-size "32" --boot-disk-type "pd-standard" \
--metadata "sap_hana_deployment_bucket=${sap_hana_deployment_bucket},sap_hana_sid=${sap_hana_sid},sap_hana_instance_number=${sap_hana_instance_number},sap_hana_sidadm_password=${sap_hana_sidadm_password},sap_hana_system_password=${sap_hana_system_password},startup-script=curl https://storage.googleapis.com/sapdeploy/dm-templates/sap_hana_optane_pilot/startup.sh | bash -x" \
--scopes "https://www.googleapis.com/auth/compute","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring.write","https://www.googleapis.com/auth/trace.append","https://www.googleapis.com/auth/devstorage.read_write" \
--verbosity=error --no-user-output-enabled

## If Cascadelake fails, try Skylake
if [[ "$?" -ne 0 ]]; then
  echo "INFO - Retrying creation of VM ${instanceName} in ${ZONE} with ${aepsize}GB of Intel Optane DC"
  gcloud alpha compute instances create "${instanceName}" --machine-type="${instanceType}" --local-nvdimm size="${aepsize}" \
  --zone=${ZONE} --subnet "${subnet}" --min-cpu-platform="Intel Skylake" --image=${imageName} \
  --image-project=${imageProject} --boot-disk-size "32" --boot-disk-type "pd-standard" \
  --metadata "sap_hana_deployment_bucket=${sap_hana_deployment_bucket},sap_hana_sid=${sap_hana_sid},sap_hana_instance_number=${sap_hana_instance_number},sap_hana_sidadm_password=${sap_hana_sidadm_password},sap_hana_system_password=${sap_hana_system_password},startup-script=curl https://storage.googleapis.com/sapdeploy/dm-templates/sap_hana_optane_pilot/startup.sh | bash -x" \
  --scopes "https://www.googleapis.com/auth/compute","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring.write","https://www.googleapis.com/auth/trace.append","https://www.googleapis.com/auth/devstorage.read_write" \
  --verbosity=error --no-user-output-enabled
fi

## If Skylake fails, the project probably isn't whitelisted. Command is too long so ignoring SC2181
if [[ "$?" -ne 0 ]]; then
  echo "ERROR - Failed to create VM. Is your project whitelisted for the Optane DC pilot? Aborting deployment"
  return 1 2> /dev/null || exit 1
fi
 
## Attach disks
echo "INFO - Attaching disk ${instanceName}-pdssd to ${instanceName}"
if ! gcloud alpha compute instances attach-disk "${instanceName}" --disk="${instanceName}"-pdssd --zone="${ZONE}" --quiet &>/dev/null; then
  echo "ERROR - Failed to attach"
fi

echo "INFO - Attaching disk ${instanceName}-backup to ${instanceName}"
if ! gcloud alpha compute instances attach-disk "${instanceName}" --disk="${instanceName}"-backup --zone="${ZONE}" --quiet &>/dev/null; then
  echo "ERROR - Failed to attach"
fi 

echo "DEPLOYMENT COMPLETE - It may take up to 20minutes for the operating system configuration and 
SAP HANA configuration to complete. Please check stackdriver logging under Global for realtime logs
of the post deployment tasks"

gcloud compute instances list --filter=name:"${instanceName}" --format="table[box,title='INSTANCE DETAILS'](name:label='VM NAME', networkInterfaces[0].networkIP:label='INTERNAL IP', networkInterfaces[0].accessConfigs[0].natIP:label='EXTERNAL IP')"

