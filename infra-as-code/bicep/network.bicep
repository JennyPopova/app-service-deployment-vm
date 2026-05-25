/*
  Deploy vnet with subnets and NSGs
*/

@description('This is the base name for each Azure resource name (6-12 chars)')
param baseName string

@description('The resource group location')
param location string = resourceGroup().location

@description('Destination prefix for external database outbound traffic from the app subnet (for example: Internet, a Service Tag, or a specific CIDR).')
param externalDatabaseDestinationPrefix string

@description('Destination port for external database outbound traffic from the app subnet.')
@minValue(1)
@maxValue(65535)
param externalDatabasePort int

// variables
var vnetName = 'vnet-${baseName}'
var agentsNatGatewayName = 'nat-agents-${baseName}'
var agentsNatPublicIpName = 'pip-agents-nat-${baseName}'

var vnetAddressPrefix = '10.0.0.0/16'
var appServicesSubnetPrefix = '10.0.0.0/24'
var privateEndpointsSubnetPrefix = '10.0.2.0/27'
var agentsSubnetPrefix = '10.0.2.32/27'

// ---- Networking resources ----

resource agentsNatPublicIp 'Microsoft.Network/publicIPAddresses@2024-10-01' = {
  name: agentsNatPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource agentsNatGateway 'Microsoft.Network/natGateways@2024-10-01' = {
  name: agentsNatGatewayName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: agentsNatPublicIp.id
      }
    ]
    idleTimeoutInMinutes: 10
  }
}

//vnet and subnets
resource vnet 'Microsoft.Network/virtualNetworks@2024-10-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        //App services plan subnet
        name: 'snet-appServicePlan'
        properties: {
          addressPrefix: appServicesSubnetPrefix
          privateEndpointNetworkPolicies: 'Enabled'
          networkSecurityGroup: {
            id: appServiceSubnetNsg.id
          }
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        //Private endpoints subnet
        name: 'snet-privateEndpoints'
        properties: {
          addressPrefix: privateEndpointsSubnetPrefix
          privateEndpointNetworkPolicies: 'Enabled'
          networkSecurityGroup: {
            id: privateEndpointsSubnetNsg.id
          }
        }
      }
      {
        // Build agents subnet
        name: 'snet-agents'
        properties: {
          addressPrefix: agentsSubnetPrefix
          privateEndpointNetworkPolicies: 'Enabled'
          natGateway: {
            id: agentsNatGateway.id
          }
          networkSecurityGroup: {
            id: agentsSubnetNsg.id
          }
        }
      }
    ]
  }
  resource appServiceSubnet 'subnets' existing = {
    name: 'snet-appServicePlan'
  }

  resource privateEnpointsSubnet 'subnets' existing = {
    name: 'snet-privateEndpoints'
  }

  resource agentsSubnet 'subnets' existing = {
    name: 'snet-agents'
  }
}

//App service subnet nsg
resource appServiceSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-10-01' = {
  name: 'nsg-appServicesSubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AppPlan.In.Allow.UserIP.HTTP'
        properties: {
          description: 'Allow inbound HTTP traffic from user IP'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '80.216.25.146/32'
          destinationAddressPrefix: appServicesSubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'AppPlan.In.Allow.UserIP.HTTPS'
        properties: {
          description: 'Allow inbound HTTPS traffic from user IP'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '80.216.25.146/32'
          destinationAddressPrefix: appServicesSubnetPrefix
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'AppPlan.In.Deny.All'
        properties: {
          description: 'Deny all other inbound traffic'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: appServicesSubnetPrefix
          access: 'Deny'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'AppPlan.Out.Allow.PrivateEndpoints'
        properties: {
          description: 'Allow outbound traffic from the app service subnet to the private endpoints subnet'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: appServicesSubnetPrefix
          destinationAddressPrefix: privateEndpointsSubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'AppPlan.Out.Allow.AzureMonitor'
        properties: {
          description: 'Allow outbound traffic from App service to the AzureMonitor ServiceTag.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: appServicesSubnetPrefix
          destinationAddressPrefix: 'AzureMonitor'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
      {
        name: 'AppPlan.Out.Allow.ExternalDatabase'
        properties: {
          description: 'Allow outbound traffic from the app service subnet to an external database endpoint.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: string(externalDatabasePort)
          sourceAddressPrefix: appServicesSubnetPrefix
          destinationAddressPrefix: externalDatabaseDestinationPrefix
          access: 'Allow'
          priority: 120
          direction: 'Outbound'
        }
      }
    ]
  }
}

//Private endpoints subnets NSG
resource privateEndpointsSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-10-01' = {
  name: 'nsg-privateEndpointsSubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'PE.Out.Deny.All'
        properties: {
          description: 'Deny outbound traffic from the private endpoints subnet'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: privateEndpointsSubnetPrefix
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 100
          direction: 'Outbound'
        }
      }
    ]
  }
}

//Build agents subnets NSG
resource agentsSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-10-01' = {
  name: 'nsg-agentsSubnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Agents.Out.Allow.PrivateEndpoints.Https'
        properties: {
          description: 'Allow the runner subnet to reach private HTTPS endpoints.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: agentsSubnetPrefix
          destinationAddressPrefix: privateEndpointsSubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'Agents.Out.Allow.Internet.Http'
        properties: {
          description: 'Allow the runner subnet to download OS and driver packages over HTTP.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: agentsSubnetPrefix
          destinationAddressPrefix: 'Internet'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
      {
        name: 'Agents.Out.Allow.Internet.Https'
        properties: {
          description: 'Allow the runner subnet to download OS and driver packages over HTTPS.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: agentsSubnetPrefix
          destinationAddressPrefix: 'Internet'
          access: 'Allow'
          priority: 120
          direction: 'Outbound'
        }
      }
      {
        name: 'DenyAllOutBound'
        properties: {
          description: 'Deny outbound traffic from the build agents subnet. Note: adjust rules as needed after adding resources to the subnet'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: agentsSubnetPrefix
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
  }
}

// ---- Outputs ----
@description('The name of the vnet.')
output vnetName string = vnet.name

@description('The name of the app service plan subnet.')
output appServicesSubnetName string = vnet::appServiceSubnet.name

@description('The name of the private endpoints subnet.')
output privateEndpointsSubnetName string = vnet::privateEnpointsSubnet.name

@description('The name of the agents subnet.')
output agentsSubnetName string = vnet::agentsSubnet.name
