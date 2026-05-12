/*
  Deploy a SQL server with a sample database, a private endpoint and a private DNS zone
*/
@description('This is the base name for each Azure resource name (6-12 chars)')
param baseName string

@description('The resource group location')
param location string = resourceGroup().location

@description('The Microsoft Entra login name (UPN) to set as SQL Server Entra administrator.')
param sqlEntraAdministratorLogin string

@description('The Microsoft Entra object ID to set as SQL Server Entra administrator.')
param sqlEntraAdministratorObjectId string

@description('The name of the virtual network to deploy the private endpoint into')
param vnetName string

@description('The name of the subnet to deploy the private endpoint into')
param privateEndpointsSubnetName string

// variables
var sqlServerName = 'sql-${baseName}'
var sampleSqlDatabaseName = 'sqldb-adventureworks'
var sqlPrivateEndpointName = 'pep-${sqlServerName}'
var sqlDnsZoneName = 'privatelink${environment().suffixes.sqlServerHostname}'

// ---- Existing resources ----
resource vnet 'Microsoft.Network/virtualNetworks@2024-10-01' existing =  {
  name: vnetName

  resource privateEndpointsSubnet 'subnets' existing = {
    name: privateEndpointsSubnetName
  }  
}

// ---- Sql resources ----

// sql server
resource sqlServer 'Microsoft.Sql/servers@2024-11-01-preview' = {
  name: sqlServerName
  location: location
  tags: {
    SecurityControl: 'Ignore'
  }
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      login: sqlEntraAdministratorLogin
      sid: sqlEntraAdministratorObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

//database
resource sqlDatabase 'Microsoft.Sql/servers/databases@2024-11-01-preview' = {
  name: sampleSqlDatabaseName
  parent: sqlServer
  location: location

  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  tags: {
    displayName: sampleSqlDatabaseName
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 104857600
    sampleName: 'AdventureWorksLT'
  }
}

resource sqlServerPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: sqlPrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: vnet::privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: sqlPrivateEndpointName
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

resource sqlServerDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: sqlDnsZoneName
  location: 'global'
  properties: {}
}

resource sqlServerDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: sqlServerDnsZone
  name: '${sqlDnsZoneName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource sqlServerDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-10-01' = {
  parent: sqlServerPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: sqlDnsZoneName
        properties: {
          privateDnsZoneId: sqlServerDnsZone.id
        }
      }
    ]
  }
}

@description('The SQL Server name.')
output sqlServerName string = sqlServer.name

@description('The SQL database name.')
output sqlDatabaseName string = sqlDatabase.name
