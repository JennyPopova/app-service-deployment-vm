@description('The location in which all resources should be deployed.')
param location string = resourceGroup().location

@description('This is the base name for each Azure resource name (3-12 chars, lowercase letters, numbers, and hyphens).')
@minLength(3)
@maxLength(12)
param baseName string

@description('The Microsoft Entra login name (UPN) to set as SQL Server Entra administrator.')
param sqlEntraAdministratorLogin string

@description('The Microsoft Entra object ID to set as SQL Server Entra administrator.')
param sqlEntraAdministratorObjectId string

@description('Optional. When true will deploy a cost-optimised environment for development purposes. Note that when this param is true, the deployment is not suitable or recommended for Production environments. Default = false.')
param developmentEnvironment bool = false

@description('The local admin username for the private runner VM.')
param runnerAdminUsername string = 'azureuser'

@description('The local admin password for the private runner VM.')
@secure()
param runnerAdminPassword string

var logWorkspaceName = 'log-${baseName}'


// ---- Log Analytics workspace ----
resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Deploy vnet with subnets and NSGs
module networkModule 'network.bicep' = {
  name: 'networkDeploy'
  params: {
    location: location
    baseName: baseName
  }
}

// Deploy a private runner VM for post-provision steps that require private access
module runnerModule 'runner.bicep' = {
  name: 'runnerDeploy'
  params: {
    location: location
    baseName: baseName
    vnetName: networkModule.outputs.vnetName
    agentsSubnetName: networkModule.outputs.agentsSubnetName
    runnerAdminUsername: runnerAdminUsername
    runnerAdminPassword: runnerAdminPassword
  }
}

// Deploy storage account with private endpoint and private DNS zone
module storageModule 'storage.bicep' = {
  name: 'storageDeploy'
  params: {
    location: location
    baseName: baseName
    vnetName: networkModule.outputs.vnetName
    privateEndpointsSubnetName: networkModule.outputs.privateEndpointsSubnetName
  }
}

// Deploy a SQL server with a sample database, a private endpoint and a DNS zone
module databaseModule 'database.bicep' = {
  name: 'databaseDeploy'
  params: {
    location: location
    baseName: baseName
    sqlEntraAdministratorLogin: sqlEntraAdministratorLogin
    sqlEntraAdministratorObjectId: sqlEntraAdministratorObjectId
    vnetName: networkModule.outputs.vnetName
    privateEndpointsSubnetName: networkModule.outputs.privateEndpointsSubnetName
  }
}

// Deploy a Key Vault with a private endpoint and DNS zone
module secretsModule 'secrets.bicep' = {
  name: 'secretsDeploy'
  params: {
    location: location
    baseName: baseName
    vnetName: networkModule.outputs.vnetName
    privateEndpointsSubnetName: networkModule.outputs.privateEndpointsSubnetName
  }
}

// Deploy a web app
module webappModule 'webapp.bicep' = {
  name: 'webappDeploy'
  params: {
    location: location
    baseName: baseName
    developmentEnvironment: developmentEnvironment
    storageName: storageModule.outputs.storageName
    sqlServerName: databaseModule.outputs.sqlServerName
    sqlDatabaseName: databaseModule.outputs.sqlDatabaseName
    vnetName: networkModule.outputs.vnetName
    appServicesSubnetName: networkModule.outputs.appServicesSubnetName
    privateEndpointsSubnetName: networkModule.outputs.privateEndpointsSubnetName
    logWorkspaceName: logWorkspace.name
   }
}


