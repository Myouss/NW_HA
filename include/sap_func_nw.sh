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

nw-create_filesystems() {
    main-errhandle_log_info "Creating filesytems for NetWeaver"
    main-create_filesystem /sapmnt sapmnt xfs
    main-create_filesystem /usr/sap usrsap xfs
    main-create_filesystem swap swap swap
}

nw-install_agent() {
  main-errhandle_log_info "Installing SAP NetWeaver monitoring agent"
  curl -s https://storage.googleapis.com/sap-netweaver-on-gcp/setupagent_linux.sh >/dev/null | bash || :
  set +e
}
