#!/bin/bash
# ------------------------------------------------------------------------
# Copyright 2016 Google Inc.
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
# Description:	Google Cloud Platform - Deployment Functions
# Version:			3.4
# Date:					YYYY-MM-DD
# ------------------------------------------------------------------------

ase-create_filesystems() {
  main-errhandle_log_info "Creating file systems for SAP ASE"
  main-create_filesystem /ase/${ASE_SID} asesid ext3
  main-create_filesystem /ase/${ASE_SID}/sapdata_1 asesapdata ext3
  main-create_filesystem /ase/${ASE_SID}/loglog_1 aselog ext3
  main-create_filesystem /ase/${ASE_SID}/saptemp asesaptemp ext3
  main-create_filesystem /ase/${ASE_SID}/sapdiag asesapdiag ext3
  main-create_filesystem /sybasebackup asebackup ext3
}


ase-get_settings() {
  main-errhandle_log_info "Determining SAP ASE specific settings"
  ASE_SID=$(gcp-metadata sap_ase_sid)
  main-errhandle_log_info "--- ase SID is ${ASE_SID}"
}
