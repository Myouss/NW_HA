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

gcp-get_settings() {
	main-errhandle_log_info 'Setting GCP Variables'

	## set bash mode
	set +e

	## set current zone as the default zone
	export CLOUDSDK_COMPUTE_ZONE=$(gcp-metadata "http://metadata.google.internal/computeMetadata/v1/instance/zone" | cut -d'/' -f4)
	main-errhandle_log_info "--- Instance determined to be running in $CLOUDSDK_COMPUTE_ZONE. Setting this as the default zone"

	export GCP_REGION=${CLOUDSDK_COMPUTE_ZONE::-2}
	## get instance type
	export GCP_INSTTYPE=$(gcp-metadata http://metadata.google.internal/computeMetadata/v1/instance/machine-type | cut -d'/' -f4)
	main-errhandle_log_info "--- Instance type determined to be $GCP_INSTTYPE"

	export GCP_CPUPLAT=$(gcp-metadata "http://metadata.google.internal/computeMetadata/v1/instance/cpu-platform")
	main-errhandle_log_info "--- Instance is determined to be part on CPU Platform $GCP_CPUPLAT"

	## get gcs bucket name
	export GCP_STARTUP=$(gcp-metadata startup-script)
	main-errhandle_log_info "--- Instance startup script determined to be: \"$GCP_STARTUP\""

	## get network name
	export GCP_NETWORK=$(gcp-metadata http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/network | cut -d'/' -f4)
	main-errhandle_log_info "--- Instance is determined to be part of network $GCP_NETWORK"

	export GCP_SUBNET=$(${GCLOUD_CMD} compute instances describe $HOSTNAME | grep "subnetwork:" | head -1 | grep -o 'subnetworks.*' | cut -f2- -d"/")
	main-errhandle_log_info "--- Instance is determined to be part of subnetwork $GCP_SUBNET"

	## get network name
	export GCP_IP=$(gcp-metadata http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
	main-errhandle_log_info "--- Instance IP is determined to be $GCP_IP"

	# determine GCP instance CPU count
	export GCP_CPUCOUNT=$(cat /proc/cpuinfo | grep processor | wc -l)
	main-errhandle_log_info "--- Instance determined to have $GCP_CPUCOUNT cores"

	# determine disk sizes from the amount of memory
  export GCP_MEMSIZE=$(free -g | grep Mem | awk '{ print $2 }')
	main-errhandle_log_info "--- Instance determined to have ${GCP_MEMSIZE}GB of memory"

	# determine disk sizes from the amount of memory
	export DEBUG_DEPLOYMENT=$(gcp-metadata sap_deployment_debug)
	if [ ${DEBUG_DEPLOYMENT} == "True" ]; then
    main-errhandle_log_info "--- Advanced debugging mode enabled"
  fi

	# remove startup script
	if [ -n "${GCP_STARTUP}" ]; then
		gcp-remove_metadata startup-script
	fi

}


gcp-create_static_ip() {
	main-errhandle_log_info "Creating static IP address ${GCP_IP} in subnetwork ${GCP_SUBNET}"
	${GCLOUD_CMD} compute addresses create ${HOSTNAME} --addresses ${GCP_IP} --region ${GCP_REGION} --subnet ${GCP_SUBNET}
}


gcp-remove_metadata() {
	${GCLOUD_CMD} compute instances remove-metadata $HOSTNAME --keys $1
}


gcp-install_gsdk() {
	if [ ! -d "${1}/google-cloud-sdk" ]; then
		bash <(curl -s https://dl.google.com/dl/cloudsdk/channels/rapid/install_google_cloud_sdk.bash) --disable-prompts --install-dir=${1} >/dev/null
		## run an instances list just to ensure the software is up to date
		${1}/google-cloud-sdk/bin/gcloud --quiet beta compute instances list >/dev/null
		if [[ "$LINUX_DISTRO" = "SLES" ]]; then
			update-alternatives --install /usr/bin/gsutil gsutil /usr/local/google-cloud-sdk/bin/gsutil 1 --force
			update-alternatives --install /usr/bin/gcloud gcloud /usr/local/google-cloud-sdk/bin/gcloud 1 --force
		fi
	fi

	# set GCLOUD variable
	if [[ -f /usr/local/google-cloud-sdk/bin/gcloud ]]; then
		GCLOUD_CMD="/usr/local/google-cloud-sdk/bin/gcloud"
		GSUTIL_CMD="/usr/local/google-cloud-sdk/bin/gsutil"
	elif [[ -f /usr/bin/gcloud ]]; then
		GCLOUD_CMD="/usr/bin/gloud"
		GSUTIL_CMD="/usr/bin/gsutil"
	fi
  main-errhandle_log_info "Installing Google SDK in $1"
}


gcp-metadata() {
	if [[ $1 = *"metadata.google.internal/computeMetadata"* ]]; then
  	output=$(curl --fail -sH'Metadata-Flavor: Google' $1)
	else
		output=$(curl --fail -sH'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1)
	fi
	echo $output
}
