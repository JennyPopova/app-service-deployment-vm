@description('The location in which all resources should be deployed.')
param location string = resourceGroup().location

@description('This is the base name for each Azure resource name (3-12 chars, lowercase letters, numbers, and hyphens).')
@minLength(3)
@maxLength(12)
param baseName string

@description('Optional. When true will deploy a cost-optimised environment for development purposes. Note that when this param is true, the deployment is not suitable or recommended for Production environments. Default = false.')
param developmentEnvironment bool = false

@description('Destination prefix for external database outbound traffic from the app subnet (for example: Internet, a Service Tag, or a specific CIDR).')
param externalDatabaseDestinationPrefix string = 'Internet'

@description('Destination port for external database outbound traffic from the app subnet.')
@minValue(1)
@maxValue(65535)
param externalDatabasePort int = 1433

@description('The local admin username for the private runner VM.')
param runnerAdminUsername string = 'azureuser'

@description('The local admin password for the private runner VM.')
@secure()
param runnerAdminPassword string

@description('Database server hostname or FQDN to store in Key Vault.')
param sqlServer string = 'sql-server-jn'

@description('Database name to store in Key Vault.')
param sqlDatabase string = 'alfa-db'

@description('Database username to store in Key Vault.')
param sqlUsername string = 'alfa_read_user'

@description('Database password to store in Key Vault.')
@secure()
param sqlPassword string

var keyVaultSecretsUserRoleDefinitionId = '4633458b-17de-408a-b874-0445c86b69e6'

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
    externalDatabaseDestinationPrefix: externalDatabaseDestinationPrefix
    externalDatabasePort: externalDatabasePort
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

// Deploy a Key Vault with a private endpoint and DNS zone
module secretsModule 'secrets.bicep' = {
  name: 'secretsDeploy'
  params: {
    location: location
    baseName: baseName
    vnetName: networkModule.outputs.vnetName
    privateEndpointsSubnetName: networkModule.outputs.privateEndpointsSubnetName
    sqlServer: sqlServer
    sqlDatabase: sqlDatabase
    sqlUsername: sqlUsername
    sqlPassword: sqlPassword
  }
}

module keyVaultSecretsUserRoleAssignmentModule 'modules/keyvaultRoleAssignment.bicep' = {
  name: 'keyVaultSecretsUserRoleAssignmentDeploy'
  params: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleDefinitionId)
    principalId: webappModule.outputs.appServiceManagedIdentityPrincipalId
    keyVaultName: secretsModule.outputs.keyVaultName
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
    keyVaultName: secretsModule.outputs.keyVaultName
    vnetName: networkModule.outputs.vnetName
    appServicesSubnetName: networkModule.outputs.appServicesSubnetName
    privateEndpointsSubnetName: networkModule.outputs.privateEndpointsSubnetName
    logWorkspaceName: logWorkspace.name
   }
}


