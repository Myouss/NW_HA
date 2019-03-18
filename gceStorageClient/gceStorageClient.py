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
# Description:	Google Cloud Platform - SAP HANA Storage Connector
# Version:		1.0
# Date:			YYYY-MM-DD
# ------------------------------------------------------------------------

import sys

# add default python path and import python modules
sys.path.append("/usr/lib/python2.7/site-packages")
sys.path.append("/usr/lib64/python2.7/lib-dynload")

## Check to see if we are running in testmode
check=False
try:
    if len(sys.argv) > 1:
        if sys.argv[1] == "--check":
            check=True
except:
    check=False

## Load module list
module_list = ['os', 'time', 'ssl', 'requests', 'oauth2client', 'googleapiclient','googleapiclient.discovery']
for module in module_list:
    try:
        if check: print "Checking module " + module
        module_obj = __import__ (module)
        globals()[module] = module_obj
        if check: print " - SUCCESS"
    except Exception as err:
        if check:
            print " - FAIL: {}".format(str(err))
        else:
            raise Exception("Unable to load module: %s" % (err))

# constants
HOSTNAME = os.uname()[1]
PROJECT = requests.get("http://169.254.169.254/computeMetadata/v1/project/project-id", headers={'Metadata-Flavor': 'Google'}).text
COMPUTE_URL_BASE = 'https://www.googleapis.com/compute/v1/'

## if running in test mode, test connection to GCE
if check:
    try:
        print "Checking connection to GCE"
        credentials = None
        if tuple(googleapiclient.__version__) < tuple("1.6.0"):
            credentials = oauth2client.client.GoogleCredentials.get_application_default()
        conn = googleapiclient.discovery.build('compute', 'v1', credentials=credentials)
        print " - SUCCESS"
    except Exception as err:
    	print " - FAIL: {}".format(str(err))
    raise SystemExit()

#TODO Checking retrival of instance data from GCE API
#TODO Checking retrival of metadata from  metadata.google.internal (169.254.169.254)

# import modules SAP HANA related modules from HANA python dir
from hdb_ha.client import StorageConnectorClient, Helper


class gceStorageClient(StorageConnectorClient):
    apiVersion = 2
    interval = 1
    retries = 20

    def __init__(self, *args, **kwargs):
        # delegate construction to base class
        super(gceStorageClient, self).__init__(*args, **kwargs)

    def about(self):
        return {
                "provider_company": "Google",
                "provider_name": "Google Cloud Storage Client",
                "provider_description": "Persistent Disk Mapping",
                "provider_version": "1.0"
        }

    def attach(self, storages):
        """Attaches storages on this host."""
        self.tracer.info("%s.attach method called" % self.__class__.__name__)

        # reload global.ini
        self._cfg.reload()

        # connect to Google API
        conn = self.api_conn()

        # fetch the GCE zone for this host
        zone = self.get_zone(conn, HOSTNAME)

        for storage in storages:
            # fetch pd & dev variables from global.ini for specified partition & usage
            connectionData = self._getConnectionDataForLun(storage.get("partition"), storage.get("usage_type"))
            try:
                pd = connectionData["pd"]
                dev = connectionData["dev"]
            except:
                raise Exception("pd or dev not set in global.ini")

            # fetch mount options from global.ini
            try:
                mount_options = connectionData["mountoptions"]
            except:
                mount_options = ""

            # fetch fencing options from global.ini
            try:
                fencing = connectionData["fencing"]
            except:
                fencing = ""

            # fetch the host which currently owns the disk & the file path
            pdhost = self.get_pd_host(conn, pd, zone)
            path = storage.get("path")

            # check if the require disk is already attached somewhere. If it is, detach it and fence the old host
            if pdhost == HOSTNAME:
                self.tracer.info("disk %s is already attached to %s(%s)" % (pd, HOSTNAME, zone))
                self.mount(dev, path, mount_options)
                continue
            elif pdhost != "":
                self.tracer.info("unable to attach %s to %s(%s) as it is still attached to %s" % (pd, HOSTNAME, zone, pdhost))
                self.detach_pd(conn, pdhost, pd)
                if fencing.lower() == "enabled" or fencing.lower() == "true" or fencing.lower() == "yes":
                    self.fence(conn, pdhost)

            # prepare payload for API call
            pdurl = self.zonal_url(zone, "disks", pd)
            body = {
                "deviceName": pd,
                "source": pdurl
            }

            # send API call to disconnect disks
            self.tracer.info("attempting to attach %s to %s(%s)" % (pd, HOSTNAME, zone))
            operation = conn.instances().attachDisk(project=PROJECT, zone=zone, instance=HOSTNAME, body=body).execute()
            self.wait_for_operation(conn, operation, zone)

            # check if disk is attached and if so, mount the volumes
            if self.get_pd_host(conn, pd, zone) == HOSTNAME:
                self.tracer.info("successfully attached %s to %s(%s)" % (pd, HOSTNAME, zone))
                self.mount(dev, path, mount_options)
            else:
                raise Exception("failed to attached %s to %s(%s)" % (pd, HOSTNAME, zone))

        # tell HANA is all good and to continue the load process
        return 0

    def detach(self, storages):
        """detach storages from this host."""
        self.tracer.info("%s.attach method called" % self.__class__.__name__)

        # init variables & arrays
        all_pds = []
        all_vgs = []
        unmount_err = 0

        # reload global.ini
        self._cfg.reload()

        # connect to Google API
        conn = self.api_conn()

        # fetch the GCE zone for this host
        zone = self.get_zone(conn, HOSTNAME)

        for storage in storages:
            # fetch pd & dev variables for specified partition & usage
            connectionData = self._getConnectionDataForLun(storage.get("partition"), storage.get("usage_type"))
            try:
                pd = connectionData["pd"]
                dev = connectionData["dev"]
            except:
                raise Exception("pd or dev not set in global.ini")

            # fetch the host which currently owns the disk & the file path
            path = storage.get("path")

            # try to unmount the file system twice
            self._forcedUnmount(dev, path, 2)

            # if it's still mounted, try killing blocking processes and umount again
            if os.path.ismount(path):
                self._lsof_and_kill(path)
                self._forcedUnmount(dev, path, 2)

            # if still mounted, raise exception. The taking over node will stonith this host
            if os.path.ismount(path):
                self.tracer.warning("A PID belonging to someone other than SIDADM is blocking the unmount. This node will be fenced")
                self._umount(path, lazy=True)
                mount_err = 1

            # add to list of devices.
            all_pds.append(pd)

            # check to see if the device is a VG. If so, add it to the list of VG's
            all_vgs.append(self.get_vg(dev))

        # Stop each unique VG
        all_vgs = list(set(all_vgs))
        for vg in all_vgs:
            Helper._runOsCommand("sudo /sbin/vgchange -an %s" % vg, self.tracer)
            self.tracer.info("stopping volume group %s" % (vg))

        # for each unique disk detected, detach it using Google API's
        all_pds = list(set(all_pds))
        for pd_member in all_pds:
            self.detach_pd(conn, HOSTNAME, pd_member)

        # if there was an error unmounting, self fence
        if unmount_err == 1:
            self.fence(conn, pdhost)

        # tell HANA we successfully detached
        return 0

    def info(self, paths):
        """Return info about mounted file systems."""
        self.tracer.info("%s.info method called" % self.__class__.__name__)

        mounts = []

        for path in paths:
            # determine real OS path without symlinks and retrieve the mounted devices
            path = os.path.realpath(path)

            # if path isn't mounted, skip this entry
            if not os.path.ismount(path):
                continue

            ## get fstype and device from /proc/mounts
            (code, output) = Helper._run2PipedOsCommand("cat /proc/mounts", "grep -w %s" % path)
            if not code == 0:
                self.tracer.warning("error running cat /proc/mounts: code %s: %s" % (code, output))
                dev = "?"
                fstype = "?"
            else:
                dev = output.split()[0]
                fstype = output.split()[2]

            # combine all extracted information
            mounts.append({
                "path" : path,
                "OS Filesystem Type" : fstype,
                "OS Device" : dev,
                })

        return mounts

    @staticmethod
    def sudoers():
        """Validate required commands are in /etc/sudoes"""
        return """ALL=NOPASSWD: /sbin/multipath, /sbin/multipathd, /etc/init.d/multipathd, /usr/bin/sg_persist, /bin/mount, /bin/umount, /bin/kill, /usr/bin/lsof, /usr/bin/systemctl, /usr/sbin/lsof, /usr/sbin/xfs_repair, /usr/bin/mkdir, /sbin/vgscan, /sbin/pvscan, /sbin/lvscan, /sbin/vgchange, /sbin/lvdisplay"""


# --- GCE storage connector specific methods
    def get_vg(self, lvname):
        """Returns the volume group for the specified logical volume."""
        (code, output) = Helper._runOsCommand("sudo /sbin/lvdisplay %s -c" % lvname, self.tracer)
        if not code == 0:
            return 0
        else:
            vg = output.split(":")
            return vg[1]

    def api_conn(self):
        """Connect to GCE API"""
        try:
            credentials = None
            if tuple(googleapiclient.__version__) < tuple("1.6.0"):
                import oauth2client.client
                credentials = oauth2client.client.GoogleCredentials.get_application_default()
            conn = googleapiclient.discovery.build('compute', 'v1', credentials=credentials)
        except Exception as err:
            raise Exception("Unable to connect to Google Cloud API: %s" % (err))
        return conn

    def fence(self, conn, hostname):
        """Fences a failed host."""
        self.tracer.info("%s.fencing method called" % self.__class__.__name__)
        zone = self.get_zone(conn, hostname)
        self.tracer.info("fencing host %s(%s)" % (hostname, zone))
        try:
            request = conn.instances().reset(project=PROJECT, zone=zone, instance=hostname).execute()
        except Exception as err:
            self.tracer.warning("Unable to fence %s. Error: %s" % (hostname, err))
        return 0

    def detach_pd(self, conn, host, pd):
        """Detaches a PD from a host using Google Cloud APIs."""
        zone = self.get_zone(conn, host)
        pdhost = self.get_pd_host(conn, pd, zone)
        if pdhost == "":
            self.tracer.info(
                "disk %s is already attached to %s(%s)" % (pd, host, zone))
        elif pdhost == host:
            self.tracer.info("attempting to detach %s from %s(%s)" % (pd, host, zone))
            operation = conn.instances().detachDisk(project=PROJECT, zone=zone, instance=host, deviceName=pd).execute()
            self.wait_for_operation(conn, operation, zone)
            if self.get_pd_host(conn, pd, zone) == "":
                self.tracer.info("successfully detached %s from %s(%s)" % (pd, host, zone))

    def mount(self, dev, path, mount_options):
        """Mounts a device to a mount point."""
        # if directory is not a mount point, mount it
        if not os.path.ismount(path):
            # check to see if dev is LVM. If so, activate it's associated volume group
            vg = self.get_vg(dev)
            if len(vg) > 0:
                Helper._runOsCommand("sudo /sbin/pvscan && sudo /sbin/vgscan && sudo /sbin/lvscan && sudo /sbin/vgchange -ay %s" % vg, self.tracer)
            # check / create mount point and mount device
            self._checkAndCreatePath(path)
            self._mount(dev, path, mount_options)
        else:
            self.tracer.info("device %s is already mounted to %s" % (dev, path))

    def get_zone(self, conn, host):
        """Fetch the GCE zone for the supplied host."""
        fl = 'name="%s"' % host
        request = conn.instances().aggregatedList(project=PROJECT, filter=fl)
    	while request is not None:
    		response = request.execute()
    		zones = response.get('items', {})
    		for zone in zones.values():
    			for inst in zone.get('instances', []):
    				if inst['name'] == host:
    					return inst['zone'].split("/")[-1]
    		request = conn.instances().aggregatedList_next(previous_request=request, previous_response=response)
    	raise Exception("Unable to determin the zone for instance  %s" % (host))

    def get_pd_host(self, conn, pd, zone):
        """Fetch the GCE instance for which the supplied disk is attached to."""
        response = conn.disks().get(project=PROJECT, zone=zone, disk=pd).execute()
        owner = response.get('users', '')
        if len(owner) > 0:
            return owner[0].split("/")[-1]
        else:
            return ""

    def wait_for_operation(self, conn, operation, zone):
        """Wait for a GCE API operation to finish"""
        while True:
            result = conn.zoneOperations().get(
                project=PROJECT, zone=zone, operation=operation['name']).execute()
            if result['status'] == 'DONE':
                if 'error' in result:
                    raise Exception(result['error'])
                return
            time.sleep(1)

    def zonal_url(self, zone, collection, name):
        """Build the zonal URL for a specific collection & name"""
        return ''.join([COMPUTE_URL_BASE, 'projects/', PROJECT, '/zones/', zone, '/', collection, '/', name])
