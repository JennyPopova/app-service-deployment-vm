/*
  Deploy a private Linux runner VM for post-provision operations that require
  access to private endpoints.
*/

@description('This is the base name for each Azure resource name (6-12 chars)')
param baseName string

@description('The resource group location')
param location string = resourceGroup().location

@description('The name of the virtual network to deploy the runner into')
param vnetName string

@description('The name of the subnet to deploy the runner into')
param agentsSubnetName string

@description('The local admin username for the runner VM')
param runnerAdminUsername string

@description('The local admin password for the runner VM')
@secure()
param runnerAdminPassword string

var runnerVmName = 'vm-runner-${baseName}'
var runnerNicName = 'nic-${runnerVmName}'
var runnerVmSize = 'Standard_E2s_v5'
var runnerImageSku = '22_04-lts'
var cloudInit = '''#cloud-config
package_update: true
package_upgrade: false
runcmd:
  - apt-get update
  - apt-get install -y curl ca-certificates gnupg lsb-release python3-pip unixodbc-dev
  - install -d -m 0755 /etc/apt/keyrings
  - curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  - chmod a+r /etc/apt/keyrings/microsoft.gpg
  - bash -c "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main' > /etc/apt/sources.list.d/microsoft-prod.list"
  - bash -c "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ jammy main' > /etc/apt/sources.list.d/azure-cli.list"
  - apt-get update
  - ACCEPT_EULA=Y apt-get install -y msodbcsql18 azure-cli
  - python3 -m pip install --upgrade pip
  - python3 -m pip install pyodbc
'''

resource vnet 'Microsoft.Network/virtualNetworks@2024-10-01' existing = {
  name: vnetName

  resource agentsSubnet 'subnets' existing = {
    name: agentsSubnetName
  }
}

resource runnerNic 'Microsoft.Network/networkInterfaces@2024-10-01' = {
  name: runnerNicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet::agentsSubnet.id
          }
        }
      }
    ]
  }
}

resource runnerVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: runnerVmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: runnerVmSize
    }
    osProfile: {
      computerName: runnerVmName
      adminUsername: runnerAdminUsername
      adminPassword: runnerAdminPassword
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: false
        patchSettings: {
          patchMode: 'ImageDefault'
          assessmentMode: 'ImageDefault'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: runnerImageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: runnerNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

@description('The name of the runner VM.')
output runnerVmName string = runnerVm.name

@description('The private IP address of the runner VM.')
output runnerPrivateIpAddress string = runnerNic.properties.ipConfigurations[0].properties.privateIPAddress
