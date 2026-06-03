/*
  Deploy a web app with a managed identity, diagnostic, and a private endpoint
*/

@description('This is the base name for each Azure resource name (6-12 chars)')
param baseName string

@description('The resource group location')
param location string = resourceGroup().location

@description('Optional. When true will deploy a cost-optimised environment for development purposes. Note that when this param is true, the deployment is not suitable or recommended for Production environments. Default = false.')
param developmentEnvironment bool

// existing resource name params 
@description('The name of the virtual network to deploy the private endpoint into')
param vnetName string

@description('The name of the subnet to deploy the app services into')
param appServicesSubnetName string

@description('The name of the subnet to deploy the private endpoint into')
param privateEndpointsSubnetName string

@description('The name of the storage account where the web deploy package is located')
param storageName string

@description('The name of the Key Vault containing SQL connection secrets')
param keyVaultName string

@description('The name of the Log Analytics workspace to send logs to')
param logWorkspaceName string

// variables
var appName = 'app-${baseName}'
var appServicePlanName = 'asp-${appName}${uniqueString(subscription().subscriptionId)}'
var appServiceManagedIdentityName = 'id-${appName}'
var appServicePrivateEndpointName = 'pep-${appName}'
var appInsightsName= 'appinsights-${appName}'
var keyVaultUri = 'https://${keyVaultName}${environment().suffixes.keyvaultDns}'

var appServicePlanBasicSku = {
  name: 'B1'
  capacity: 1
}

var appServicesDnsZoneName = 'privatelink.azurewebsites.net'

// ---- Existing resources ----
resource vnet 'Microsoft.Network/virtualNetworks@2024-10-01' existing =  {
  name: vnetName

  resource appServicesSubnet 'subnets' existing = {
    name: appServicesSubnetName
  }  
  resource privateEndpointsSubnet 'subnets' existing = {
    name: privateEndpointsSubnetName
  }    
}

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' existing =  {
  name: storageName
}

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logWorkspaceName
}

// Built-in Azure RBAC role that is applied to a Key storage to grant data reader permissions. 
resource blobDataReaderRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  name: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  scope: subscription()
}

// ---- Web App resources ----

// Managed Identity for App Service
resource appServiceManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2025-01-31-preview' = {
  name: appServiceManagedIdentityName
  location: location
}

// Grant the App Service managed identity storage data reader role permissions
resource blobDataReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(resourceGroup().id, appServiceManagedIdentity.name, blobDataReaderRole.id)
  properties: {
    roleDefinitionId: blobDataReaderRole.id
    principalType: 'ServicePrincipal'
    principalId: appServiceManagedIdentity.properties.principalId
  }
}

//App service plan - Linux required for Python 3.12
resource appServicePlan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: appServicePlanName
  location: location
  sku: appServicePlanBasicSku
  kind: 'linux'
  properties: {
    zoneRedundant: false
    reserved: true
  }
}

// Web App
resource webApp 'Microsoft.Web/sites@2024-11-01' = {
  name: appName
  location: location
  kind: 'app,linux'
  tags: {
    'azd-service-name': 'api'
    'deployment-environment': developmentEnvironment ? 'development' : 'production'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appServiceManagedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    virtualNetworkSubnetId: vnet::appServicesSubnet.id
    keyVaultReferenceIdentity: appServiceManagedIdentity.id
    httpsOnly: true
    hostNamesDisabled: false
    publicNetworkAccess: 'Disabled'
    siteConfig: {
      http20Enabled: true
      alwaysOn: true
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: 'gunicorn --bind=0.0.0.0:8000 --timeout 120 --chdir /home/site/wwwroot app:app'
    }
  }
  dependsOn: [
    blobDataReaderRoleAssignment
  ]
}

// App Settings
resource appsettings 'Microsoft.Web/sites/config@2024-11-01' = {
  name: 'appsettings'
  parent: webApp
  properties: {
    SCM_DO_BUILD_DURING_DEPLOYMENT: '1'
    WEBSITE_VNET_ROUTE_ALL: '1'
    AZURE_CLIENT_ID: appServiceManagedIdentity.properties.clientId
    AZURE_STORAGE_ACCOUNT: storageName
    SQL_SERVER: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}/secrets/sql-server/)'
    SQL_DATABASE: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}/secrets/sql-database/)'
    SQL_USERNAME: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}/secrets/sql-username/)'
    SQL_PASSWORD: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}/secrets/sql-password/)'
    APPINSIGHTS_INSTRUMENTATIONKEY: appInsights.properties.InstrumentationKey
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
    ApplicationInsightsAgent_EXTENSION_VERSION: '~2'
  }
}

resource scmPublishingPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  name: 'scm'
  parent: webApp
  properties: {
    allow: true
  }
}

resource ftpPublishingPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  name: 'ftp'
  parent: webApp
  properties: {
    allow: false
  }
}

resource appServicePrivateEndpointSites 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: '${appServicePrivateEndpointName}-sites'
  location: location
  properties: {
    subnet: {
      id: vnet::privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${appServicePrivateEndpointName}-sites'
        properties: {
          privateLinkServiceId: webApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource appServiceDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: appServicesDnsZoneName
  location: 'global'
  properties: {}
}

resource appServiceDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: appServiceDnsZone
  name: '${appServicesDnsZoneName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource appServiceDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-10-01' = {
  parent: appServicePrivateEndpointSites
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink.azurewebsites.net'
        properties: {
          privateDnsZoneId: appServiceDnsZone.id
        }
      }
    ]
  }
}

// App service plan diagnostic settings
resource appServicePlanDiagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${appServicePlan.name}-diagnosticSettings'
  scope: appServicePlan
  properties: {
    workspaceId: logWorkspace.id
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

//Web App diagnostic settings
resource webAppDiagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${webApp.name}-diagnosticSettings'
  scope: webApp
  properties: {
    workspaceId: logWorkspace.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        categoryGroup: null
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        categoryGroup: null
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        categoryGroup: null
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// App service plan auto scale settings
resource appServicePlanAutoScaleSettings 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: '${appServicePlan.name}-autoscale'
  location: location
  properties: {
    enabled: true
    targetResourceUri: appServicePlan.id
    profiles: [
      {
        name: 'Scale out condition'
        capacity: {
          maximum: '5'
          default: '1'
          minimum: '1'
        }
        rules: [
          {
            scaleAction: {
              type: 'ChangeCount'
              direction: 'Increase'
              cooldown: 'PT5M'
              value: '1'
            }
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricNamespace: 'microsoft.web/serverfarms'
              operator: 'GreaterThan'
              timeAggregation: 'Average'
              threshold: 70
              metricResourceUri: appServicePlan.id
              timeWindow: 'PT10M'
              timeGrain: 'PT1M'
              statistic: 'Average'
            }
          }
        ]
      }
    ]
  }
  dependsOn: [
    webApp
    appServicePlanDiagSettings
  ]
}

// create application insights resource
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logWorkspace.id
  }
}

@description('The name of the app service plan.')
output appServicePlanName string = appServicePlan.name

@description('The name of the web app.')
output appName string = webApp.name

@description('The principal ID of the web app managed identity.')
output appServiceManagedIdentityPrincipalId string = appServiceManagedIdentity.properties.principalId
