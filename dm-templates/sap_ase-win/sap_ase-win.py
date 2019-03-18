
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

"""Creates a Compute Instance with the provided metadata."""

COMPUTE_URL_BASE = 'https://www.googleapis.com/compute/v1/'

def GlobalComputeUrl(project, collection, name):
  """Generate global compute URL."""
  return ''.join([COMPUTE_URL_BASE, 'projects/', project, '/global/', collection, '/', name])


def ZonalComputeUrl(project, zone, collection, name):
  """Generate zone compute URL."""
  return ''.join([COMPUTE_URL_BASE, 'projects/', project, '/zones/', zone, '/', collection, '/', name])


def RegionalComputeUrl(project, region, collection, name):
  """Generate regional compute URL."""
  return ''.join([COMPUTE_URL_BASE, 'projects/', project, '/regions/', region, '/', collection, '/', name])


def GenerateConfig(context):
  """Generate configuration."""

  # Get/generate variables from context
  zone = context.properties['zone']
  project = context.env['project']
  instance_name = context.properties['instanceName']
  instance_type = ZonalComputeUrl(project, zone, 'machineTypes', context.properties['instanceType'])
  region = context.properties['zone'][:context.properties['zone'].rfind('-')]
  windows_image_project = context.properties['windowsImageProject']
  windows_image = GlobalComputeUrl(windows_image_project, 'images', context.properties['windowsImage'])
  networkTag = str(context.properties.get('networkTag', ''))
  primary_startup_url = "https://storage.googleapis.com/sapdeploy/dm-templates/sap_ase-win/startup.ps1"
  network_tags = { "items": str(context.properties.get('networkTag', '')).split(',') if len(str(context.properties.get('networkTag', ''))) else [] }
  service_account = str(context.properties.get('serviceAccount', context.env['project_number'] + '-compute@developer.gserviceaccount.com'))

  ## Get deployment template specific variables from context
  asesid_size = context.properties['asesidSize']
  asesaptemp_size = context.properties['asesaptempSize']
  aselog_size = context.properties['aselogSize']
  aselog_ssd = str(context.properties['aselogSSD'])
  asesapdata_size = context.properties['asesapdataSize']
  asesapdata_ssd = str(context.properties['asesapdataSSD'])
  asebackup_size = context.properties['asebackupSize']
  usrsap_size = context.properties['usrsapSize']
  swap_size = context.properties['swapSize']

  # Subnetwork: with SharedVPC support
  if "/" in context.properties['subnetwork']:
      sharedvpc = context.properties['subnetwork'].split("/")
      subnetwork = RegionalComputeUrl(sharedvpc[0], region, 'subnetworks', sharedvpc[1])
  else:
      subnetwork = RegionalComputeUrl(project, region, 'subnetworks', context.properties['subnetwork'])

  # Public IP
  if str(context.properties['publicIP']) == "False":
      networking = [ ]
  else:
      networking = [{
        'name': 'external-nat',
        'type': 'ONE_TO_ONE_NAT'
      }]

  ## determine disk types
  if asesapdata_ssd == "True":
      asesapdata_type = "pd-ssd"
  else:
      asesapdata_type = "pd-standard"

  if aselog_ssd == "True":
      aselog_type = "pd-ssd"
  else:
      aselog_type = "pd-standard"

  # compile complete json
  sap_node = []
  disks = []

  # /
  disks.append({'deviceName': 'boot',
                'type': 'PERSISTENT',
                'boot': True,
                'autoDelete': True,
                'initializeParams': {
                      'diskName': instance_name + '-boot',
                      'sourceImage': windows_image,
                      'diskSizeGb': '64'
                }
               })

  # D:\ (ASE)
  sap_node.append({
          'name': instance_name + '-asesid',
          'type': 'compute.v1.disk',
          'properties': {
              'zone': zone,
              'sizeGb': asesid_size,
              'type': ZonalComputeUrl(project, zone, 'diskTypes','pd-standard')
          }
          })
  disks.append({'deviceName': instance_name + '-asesid',
              'type': 'PERSISTENT',
              'source': ''.join(['$(ref.', instance_name + '-asesid', '.selfLink)']),
              'autoDelete': True
               })

  # T:\ (Temp)
  sap_node.append({
          'name': instance_name + '-asesaptemp',
          'type': 'compute.v1.disk',
          'properties': {
              'zone': zone,
              'sizeGb': asesaptemp_size,
              'type': ZonalComputeUrl(project, zone, 'diskTypes','pd-standard')
          }
          })
  disks.append({'deviceName': instance_name + '-asesaptemp',
              'type': 'PERSISTENT',
              'source': ''.join(['$(ref.', instance_name + '-asesaptemp', '.selfLink)']),
              'autoDelete': True
               })

  # L:\ (Log)
  sap_node.append({
          'name': instance_name + '-aselog',
          'type': 'compute.v1.disk',
          'properties': {
              'zone': zone,
              'sizeGb': aselog_size,
              'type': ZonalComputeUrl(project, zone, 'diskTypes',aselog_type)
          }
          })
  disks.append({'deviceName': instance_name + '-aselog',
              'type': 'PERSISTENT',
              'source': ''.join(['$(ref.', instance_name + '-aselog', '.selfLink)']),
              'autoDelete': True
               })

  # E:\ (Data)
  sap_node.append({
          'name': instance_name + '-asesapdata',
          'type': 'compute.v1.disk',
          'properties': {
              'zone': zone,
              'sizeGb': asesapdata_size,
              'type': ZonalComputeUrl(project, zone, 'diskTypes',asesapdata_type)
          }
          })
  disks.append({'deviceName': instance_name + '-asesapdata',
              'type': 'PERSISTENT',
              'source': ''.join(['$(ref.', instance_name + '-asesapdata', '.selfLink)']),
              'autoDelete': True
               })

  # X:\ (Backup)
  sap_node.append({
          'name': instance_name + '-asebackup',
          'type': 'compute.v1.disk',
          'properties': {
              'zone': zone,
              'sizeGb': asebackup_size,
              'type': ZonalComputeUrl(project, zone, 'diskTypes','pd-standard')
          }
          })
  disks.append({'deviceName': instance_name + '-asebackup',
              'type': 'PERSISTENT',
              'source': ''.join(['$(ref.', instance_name + '-asebackup', '.selfLink)']),
              'autoDelete': True
               })

  # OPTIONAL - S:\ (SAP)
  if usrsap_size > 0:
      sap_node.append({
              'name': instance_name + '-usrsap',
              'type': 'compute.v1.disk',
              'properties': {
                  'zone': zone,
                  'sizeGb': usrsap_size,
                  'type': ZonalComputeUrl(project, zone, 'diskTypes','pd-standard')
              }
              })
      disks.append({'deviceName': instance_name + '-usrsap',
                  'type': 'PERSISTENT',
                  'source': ''.join(['$(ref.', instance_name + '-usrsap', '.selfLink)']),
                  'autoDelete': True
                   })

  # OPTIONAL - P:\ (Pagefile)
  if swap_size > 0:
      sap_node.append({
              'name': instance_name + '-swap',
              'type': 'compute.v1.disk',
              'properties': {
                  'zone': zone,
                  'sizeGb': swap_size,
                  'type': ZonalComputeUrl(project, zone, 'diskTypes','pd-standard')
              }
              })
      disks.append({'deviceName': instance_name + '-swap',
                  'type': 'PERSISTENT',
                  'source': ''.join(['$(ref.', instance_name + '-swap', '.selfLink)']),
                  'autoDelete': True
                   })

  # VM instance
  sap_node.append({
          'name': instance_name,
          'type': 'compute.v1.instance',
          'properties': {
              'zone': zone,
              'minCpuPlatform': 'Automatic',
              'machineType': instance_type,
              'metadata': {
                  'items': [{
                      'key': 'windows-startup-script-url',
                      'value': primary_startup_url
                  }]
              },
              'canIpForward': True,
              'serviceAccounts': [{
                  'email': service_account,
                  'scopes': [
                      'https://www.googleapis.com/auth/compute',
                      'https://www.googleapis.com/auth/servicecontrol',
                      'https://www.googleapis.com/auth/service.management.readonly',
                      'https://www.googleapis.com/auth/logging.write',
                      'https://www.googleapis.com/auth/monitoring.write',
                      'https://www.googleapis.com/auth/trace.append',
                      'https://www.googleapis.com/auth/devstorage.read_write'
                      ]
                  }],
              'networkInterfaces': [{
                  'accessConfigs': networking,
                    'subnetwork': subnetwork
                  }],
              "tags": network_tags,
              'disks': disks
              }
          })

  return {'resources': sap_node}
