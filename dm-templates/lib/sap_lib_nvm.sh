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

nvm::set_boot_parameters() {
	main::errhandle_log_info 'Checking boot paramaters'

	## disable selinux
	if [[ -e /etc/sysconfig/selinux ]]; then
	  main::errhandle_log_info "--- Disabling SELinux"
		sed -ie 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
	fi

	if [[ -e /etc/selinux/config ]]; then
		main::errhandle_log_info "--- Disabling SELinux"
		sed -ie 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
	fi
	## work around for LVM boot where LVM volues are not started on certain SLES/RHEL versions
  if [[ -e /etc/sysconfig/lvm ]]; then
    sed -ie 's/LVM_ACTIVATED_ON_DISCOVERED="disable"/LVM_ACTIVATED_ON_DISCOVERED="enable"/g' /etc/sysconfig/lvm
  fi

	## Configure cstates and huge pages
	if ! grep -q cstate /etc/default/grub ; then
		main::errhandle_log_info "--- Update grub"

    # backup existing commandline
		cmdline=$(grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub | head -1 | sed 's/GRUB_CMDLINE_LINUX_DEFAULT=//g' | sed 's/\"//g')
		cp /etc/default/grub /etc/default/grub.bak
		grep -v GRUBLINE_LINUX_DEFAULT /etc/default/grub.bak >/etc/default/grub

    local VM_INSTTYPE
    VM_INSTTYPE=$(main::get_metadata http://169.254.169.254/computeMetadata/v1/instance/machine-type | cut -d'/' -f4)

    # build new cmdline - If megamem-96-aep update the command line with memmap, else, just normal update
    printf \\nGRUB_CMDLINE_LINUX_DEFAULT='\x27' >>/etc/default/grub
    echo -n "${cmdline}" >>/etc/default/grub
    echo -n ' transparent_hugepage=never intel_idle.max_cstate=1 processor.max_cstate=1 intel_iommu=off' >>/etc/default/grub
    if [[ ${VM_INSTTYPE} = "n1-megamem-96-aep" ]]; then
      echo -n ' memmap=32M\$1300992M,2750G!1301024M,2750G!4117024M' >>/etc/default/grub      
    elif [[ ${VM_INSTTYPE} = "n1-highmem-96" ]]; then
      echo -n ' memmap=1494G!640000M,1494G!2169856M' >>/etc/default/grub      
    fi 
    printf '\x27'\\n >>/etc/default/grub

    #update grub
    grub2-mkconfig -o /boot/grub2/grub.cfg

		echo "${HOSTNAME}" >/etc/hostname
		main::errhandle_log_info '--- Parameters updated. Rebooting'
	  reboot
		exit 0
	fi
}


nvm::calculate_volume_sizes() {
  hana_shared_size=1024
  hana_log_size=512
  hana_data_size=$(((VM_MEMSIZE*15)/10))
}

nvm::create_pmem_volumes() {
  local count=0
  for pmemdev in $(find /dev -name pmem*); do
    mkfs -t xfs "${pmemdev}"
    mkdir -p /hana/pmem"${count}"
    echo "/dev/pmem${count} /hana/pmem${count} xfs defaults,dax,nofail 0 2" >>/etc/fstab
    count=$((count +1))
  done
  mount -a
}

nvm::config_hana() {
  local pmem_devices
  local pmem_dev_list=""
  local count=0

  pmem_devices=$(find /dev -name pmem* | wc -l)

  for count in $(seq 0 $((pmem_devices -1))); do
    pmem_dev_list=${pmem_dev_list}"/hana/pmem${count}/${VM_METADATA[sap_hana_sid]}"
    mkdir /hana/pmem"${count}"/"${VM_METADATA[sap_hana_sid]}"
    chown -R "${VM_METADATA[sap_hana_sid],,}"adm:sapsys /hana/pmem"${count}"
    chmod -R g+wrx,u=wrx /hana/pmem"${count}"
    if [[ ${count} -ne $((pmem_devices -1)) ]]; then
       pmem_dev_list=${pmem_dev_list}";"
    fi 
  done

  hdb::set_parameters global.ini persistence basepath_persistent_memory_volumes "${pmem_dev_list}"
  hdb::set_parameters global.ini memorymanager persistent_memory_disable_linux_numa_mapping true

  hdb::stop
  hdb::start
}
