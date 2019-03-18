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
# Description:	Google Cloud Platform - DB2 Floating IP Address
# Build Date:   Tue Jan  8 16:13:09 GMT 2019
# ------------------------------------------------------------------------
#Global constants
readonly METADATA_URL="http://169.254.169.254/computeMetadata/v1"
#IP address used to avoid potential resolution issues with custom DNS / hosts files

get_metadata() {
  output=$(curl --fail -sH'Metadata-Flavor: Google' ${METADATA_URL}/instance/attributes/$1)
  echo $output
}

get_virtual_ip() {
  # Floating IP - input IPv4 address
  # Check if metadata key exists
  VIRTUAL_IP=$(get_metadata sap_ibm_db2_vip)
  if [[ -n ${VIRTUAL_IP} ]]; then
    VIRTUAL_IP=${VIRTUAL_IP}"/32"
  else
    log_error "IP alias not set in metadata. Aborting."
    # Pass empty IP back to calling segment
    VIRTUAL_VIP=""
  fi
}

get_alias_range() {
  # Get alias range name
  # Check if metadata key exists
  ALIAS_RANGE_NAME=$(get_metadata sap_ibm_db2_iprange)
  if [[ -z ${ALIAS_RANGE_NAME} ]]; then
    log_info "IP name range not set. This is optional."
    # Pass empty IP back to calling segment
    ALIAS_RANGE_NAME=""
  fi
}

get_route_name() {
  # Get route network name
  # Check if metadata key exists
  ROUTE_NAME=$(get_metadata sap_ibm_db2_routename)
  ROUTE_NETWORK=$(get_metadata sap_ibm_db2_routenet)
  if [[ (-z ROUTE_NAME) || (-z ROUTE_NETWORK) ]]; then
    log_error "IP route network or route name not set in metadata. This is required."
    #exit 1 will be triggered from main program
    ROUTE_NAME=""
    ROUTE_NETWORK=""
  fi
}

get_route() {
  ROUTE=$(${GCLOUDCMD} --quiet compute routes describe ${ROUTE_NAME} --verbosity=none -q | grep nextHop | grep -o '[^/]*$')
}

get_cluster_hosts() {
  # Retrieve nodes in cluster
  HOSTS=($(lsrpnode -d | awk -F ':' 'FNR>1 { print $1 }'))
}

get_zone() {
  ZONE=$(${GCLOUDCMD} --quiet compute instances list --filter="name=('${1}')" --format 'csv[no-heading](zone)')
}

get_ip() {
  IP=$(${GCLOUDCMD} --quiet compute instances describe ${1} --zone ${ZONE} --format text | grep aliasIpRanges | grep ${VIRTUAL_IP} | awk '{ print $2 }')
}

get_my_zone() {
  MYZONE=$(curl -sH'Metadata-Flavor: Google' "${METADATA_URL}/instance/zone" | cut -d'/' -f4)
}

get_my_ip() {
  if [[ $(curl -sH'Metadata-Flavor: Google' "${METADATA_URL}/instance/network-interfaces/0/ip-aliases/") ]]; then
    MYIP=$(curl -sH'Metadata-Flavor: Google' "${METADATA_URL}/instance/network-interfaces/0/ip-aliases/0")
  else
    unset MYIP
  fi
}

get_gcloud() {
  ## if gcloud command isn't set, default to the default path
  GCLOUDCMD="/usr/bin/gcloud"

  ## check gcloud command exists
  if [[ ! -f ${GCLOUDCMD} ]]; then
    log_error "gcloud command not found at ${GCLOUDCMD}"
    exit 1
  fi
}

assign_ip_host() {
  ##single device, primary and virtual IP on same device (shared gateway)
  /sbin/ip addr add ${VIRTUAL_IP} dev eth0 label eth0:0
  if [ $? == 0 ]
  then
    log_info "Successfully assigned alias to eth0"
  else
    log_error "Failed to assign alias to eth0"
    exit 1
  fi
}

check_gcloud_version() {
  ${GCLOUDCMD} --quiet beta compute instances network-interfaces --help >/dev/null
  if [[ $? -gt 0 ]]; then
    log_error "gcloud version does not support beta 'network-interfaces' function. Upgrade gcloud SDK or specifiy gcloud path to a newer version"
    exit 1
  fi
}

log_info() {
  echo "gcp:db2vip - INFO - ${1}"
}

log_error() {
  echo "gcp:db2vip - ERROR - ${1}"
}

#########################
## Main script segment ##
#########################
#Tivoli SA MP exit codes - applies to monitor action only
OPSTATE_UNKNOWN=0
OPSTATE_ONLINE=1
OPSTATE_OFFLINE=2
OPSTATE_FOFFLINE=3
OPSTATE_STUCKON=4
OPSTATE_PENDON=5
OPSTATE_PENDOFF=6
OPSTATE_INELIG=8

#Primary parameters
#Solution=alias (intra-zonal HA using IP alias) or routing (inter-zonal HA routing priority)
SOLUTION=$(get_metadata sap_ibm_vip_solution)
if [[ -z ${SOLUTION} ]]; then
  log_error "Virtual IP solution not defined. Cannot start resource."
  exit 1
fi

if [ ${SOLUTION} == 'route' ] || [ ${SOLUTION} == 'alias' ]; then
  log_info "IP solution '${SOLUTION}' used, proceeding"
else
  log_error "Valid solution not selected, choose either route / alias options"
  exit 1
fi

ACTION=${1}

case ${ACTION} in

  start)
    #Common functions regardless of solution chosen
    get_virtual_ip
    get_cluster_hosts
    get_gcloud
    check_gcloud_version
    get_my_zone
    get_my_ip
    
    ## ALIAS solution
    if [[ ${SOLUTION} == "alias" ]]; then
      #Use Google API to assign alias IP address to new primary host
      #Check if Virtual IP is defined at this point
      if [[ -z ${VIRTUAL_IP} ]]; then
        log_error "IP alias undefined. Cannot start resource."
        exit 1
      fi
      get_alias_range
      ## If I already have the IP, exit. If it has an alias IP that isn't the VIP, then remove it
      if [[ -n ${MYIP} ]]; then
        if [[ ${MYIP} == ${VIRTUAL_IP} ]]; then
          log_info "${HOSTNAME} already has ${MYIP} attached. No action required"
          # Set alias on eth0, since it may be allocated to the instance but not the device
          assign_ip_host
          exit 0
        else
          log_info "Removing ${MYIP} from ${HOSTNAME}"
          ${GCLOUDCMD} --quiet beta compute instances network-interfaces update ${HOSTNAME} --zone ${MYZONE} --aliases ""
        fi
      fi

      ## Loops through all hosts & remove the alias IP from the host that has it
      #May need to revise as this could wipe other valid alias assignments in complex scenarios
      IP="TBD"
      for HOST in "${HOSTS[@]}"; do
        get_zone ${HOST}
        get_ip ${HOST}
        log_info "Checking to see if ${HOST} owns ${VIRTUAL_IP}"
        ## keep trying to remove until it's not there anymore - Added due to the fingerprint bug
        while [[ -n ${IP} ]]; do
          log_info "${IP} is attached to ${HOST} - Removing all alias IP addresses from ${HOST}"
          ${GCLOUDCMD} --quiet beta compute instances network-interfaces update ${HOST} --zone ${ZONE} --aliases ""
          get_ip ${HOST}
          sleep 2
        done
      done

      ## add alias IP to localhost
      ## For testing since OCF_... variables undefined if Pacemaker not used. Retained in case used in conjunction with Pacemaker.
      ## Also accommodates named range
      if [[ -z ${OCF_RESKEY_alias_range_name} ]]; then
        log_info "Adding ${VIRTUAL_IP} to ${HOSTNAME}"
        ${GCLOUDCMD} --quiet beta compute instances network-interfaces update ${HOSTNAME} --zone ${MYZONE} --aliases ${VIRTUAL_IP}
        log_info "Assigning alias to eth0:0"
        assign_ip_host
      else
        # If IP Range Name defined, use it
        # Note that alias assignment assumes same subnet
        log_info "Adding ${VIRTUAL_IP} in secondary range ${ALIAS_RANGE_NAME} to ${HOSTNAME}"
        ${GCLOUDCMD} --quiet beta compute instances network-interfaces update ${HOSTNAME} --zone ${MYZONE} --aliases ${ALIAS_RANGE_NAME}:${VIRTUAL_IP}
        assign_ip_host
      fi
      RC=0 #Edit: RC determined by IP reallocation
    fi
    
    ## ROUTE solution
    if [[ ${SOLUTION} == "route" ]]; then
      get_route_name
      if [[ (-z ${ROUTE_NAME}) || (-z ${ROUTE_NETWORK}) ]]; then
        log_error "Route variables not set. Please check metadata"
        # No route provided, aborting
        exit 1
      fi
      get_route
      ## If I already have the IP, exit. If it has next hop that isn't this host then remove it
      if [ "${ROUTE}" = "${HOSTNAME}" ]; then
        log_info "${ROUTE_NAME} is already routed to ${HOSTNAME}. No action required"
        assign_ip_host
        exit 0
      fi
      ## delete the current route
      log_info "Deleting route '${ROUTE_NAME}'"
      ${GCLOUDCMD} --quiet compute routes delete ${ROUTE_NAME} --verbosity=none
  
      ## add a new route
      log_info "Creating route '${ROUTE_NAME}' pointing to host ${HOSTNAME}"
      ${GCLOUDCMD} --quiet compute routes create ${ROUTE_NAME} --priority=1000 --network=${ROUTE_NETWORK} --destination-range=${VIRTUAL_IP} --next-hop-instance=${HOSTNAME} --next-hop-instance-zone=${MYZONE}
      assign_ip_host
      exit 0
    fi
    ;;

  stop)
    #Use Google API to remove IP address from old primary host - no need to enter anything here as the start already checks and removes the allocation
    #To cover scenarios where the stop event isn't graceful, remove the alias assignment, which also removes the routing (for IP alias)
    /sbin/ifconfig eth0:0 down
    get_gcloud
    if [[ ${SOLUTION} == "route" ]]; then
      #Adding route removal to accommodate manual stop
      get_route_name
      ${GCLOUDCMD} --quiet compute routes delete ${ROUTE_NAME} --verbosity=none
      log_info "Route solution used, route removed. If you ran this manually you may need to restart the resource on the active node"
    else
      #Remove alias allocation to this particular host. It will not affect the second node.
      get_my_zone
      ${GCLOUDCMD} --quiet beta compute instances network-interfaces update ${HOSTNAME} --zone ${MYZONE} --aliases ""
    fi
    RC=0 #Edit: RC determined by IP reallocation
    ;;

  status|monitor)
    #Note RC here need to match SA MP monitoring exit codes
    #Check assignment of IP address
    get_virtual_ip
    get_gcloud
    
    if [[ ${SOLUTION} == "alias" ]]; then
      get_my_ip
      if [[ -n ${MYIP} ]]; then
        if [[ ${MYIP} == ${VIRTUAL_IP} ]]; then
          log_info "${HOSTNAME} has the correct IP address attached"
          ping -c 1 ${VIRTUAL_IP%%/*}
          if [ $? == 0 ]; then
            RC=${OPSTATE_ONLINE}
            log_info "Connected to ${VIRTUAL_IP} OK"
          else
            RC=${OPSTATE_OFFLINE}
            log_error "Failed to connect to ${VIRTUAL_IP}"
          fi
        else
          RC=${OPSTATE_OFFLINE}
        fi
      else
        #IP not allocated
        log_info "IP not allocated to this host. Are you expecting something different?"
        RC=${OPSTATE_OFFLINE}
      fi
    else # Route solution
      get_route_name
      if [[ (-z ${ROUTE_NAME}) || (-z ${ROUTE_NETWORK}) ]]; then
        log_error "Route variables not set. Please check metadata"
        # Pass empty IP back to calling segment
        exit ${OPSTATE_INELIG}
      fi
      get_route
      if [ "${ROUTE}" = "${HOSTNAME}" ]; then
        log_info "Route '${ROUTE_NAME}' is correctly pointing to ${HOSTNAME}"
        log_info "Checking connection to ${VIRTUAL_IP}"
        ping -c 1 ${VIRTUAL_IP%%/*}
        if [ $? == 0 ]; then
          RC=${OPSTATE_ONLINE}
          log_info "Connected to ${VIRTUAL_IP} OK"
        else
          RC=${OPSTATE_OFFLINE}
          log_error "Failed to connect to ${VIRTUAL_IP}"
        fi
        exit $RC
      else
        RC=${OPSTATE_OFFLINE}
      fi
    fi
    ;;

esac

exit $RC
