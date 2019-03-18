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

maxdb::create_filesystems() {
  main::errhandle_log_info "Creating filesytems for MaxDB"
  main::create_filesystem /sapdb/"${VM_METADATA[sap_maxdb_sid]}" maxdbroot xfs
  main::create_filesystem /sapdb/"${VM_METADATA[sap_maxdb_sid]}"/sapdata maxdbdata xfs
  main::create_filesystem /sapdb/"${VM_METADATA[sap_maxdb_sid]}"/saplog maxdblog xfs
  main::create_filesystem /maxdbbackup maxdbbackup xfs
}
