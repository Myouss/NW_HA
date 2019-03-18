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

db2-fix_services() {
  main-errhandle_log_info "Updating /etc/services"
  cat /etc/services | grep -v '5912/tcp\|5912/udp\|5912/stcp' >/etc/services.new
  mv /etc/services.new /etc/services
}


db2-create_filesystems() {
  main-errhandle_log_info "Creating file systems for IBM DB2"
  main-create_filesystem /db2/${DB2_SID}/db2dump db2dump ext3
  main-create_filesystem /db2/${DB2_SID}/sapdata db2sapdata ext3
  main-create_filesystem /db2/${DB2_SID}/saptmp db2saptmp ext3
  main-create_filesystem /db2/${DB2_SID}/log_dir db2log ext3
  main-create_filesystem /db2/db2${DB2_SID,,} db2sid ext3
  main-create_filesystem /db2backup db2backup ext3
}


db2-get_settings() {
  main-errhandle_log_info "Determining IBM DB2 specific settings"
  DB2_SID=$(gcp-metadata sap_ibm_db2_sid)
  main-errhandle_log_info "--- DB2 SID is ${DB2_SID}"
}
