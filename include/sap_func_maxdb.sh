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
# Date:					12/September/2018
# ------------------------------------------------------------------------

maxdb-get_settings() {
  main-errhandle_log_info "Determining SAP MaxDB specific settings"
  MAXDB_SID=$(gcp-metadata sap_maxdb_sid)
  main-errhandle_log_info "--- MaxDB SID is ${MAXDB_SID}"
}

maxdb-create_filesystems() {
  main-errhandle_log_info "Creating filesytems for MaxDB"
  main-create_filesystem /sapdb/${MAXDB_SID} maxdbroot xfs
  main-create_filesystem /sapdb/${MAXDB_SID}/sapdata maxdbdata xfs
  main-create_filesystem /sapdb/${MAXDB_SID}/saplog maxdblog xfs
  main-create_filesystem /maxdbbackup maxdbbackup xfs
}
