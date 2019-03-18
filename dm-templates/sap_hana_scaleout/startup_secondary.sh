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
# Description:  Google Cloud Platform - SAP Deployment Functions
# Build Date:   Fri Mar 15 13:25:46 GMT 2019
# ------------------------------------------------------------------------

## Check to see if a custom script path was provieded by the template
if [[ "${1}" ]]; then
  readonly DEPLOY_URL="${1}"
else
  readonly DEPLOY_URL="https://storage.googleapis.com/sapdeploy/dm-templates"
fi

## Import includes
source /dev/stdin <<< "$(curl -s ${DEPLOY_URL}/lib/sap_lib_main.sh)"
source /dev/stdin <<< "$(curl -s ${DEPLOY_URL}/lib/sap_lib_hdb.sh)"
source /dev/stdin <<< "$(curl -s ${DEPLOY_URL}/lib/sap_lib_hdbso.sh)"

### Base GCP and OS Configuration
main::get_os_version
main::install_gsdk /usr/local
main::set_boot_parameters
main::install_packages
main::config_ssh
main::get_settings
main::create_static_ip

## prepare for SAP HANA
hdb::check_settings
hdb::set_kernel_parameters
hdbso::mount_nfs_vols
hdbso::calculate_volume_sizes
hdbso::create_data_log_volumes
hdbso::update_sudoers

## Post deployment & installation cleanup
main::complete
