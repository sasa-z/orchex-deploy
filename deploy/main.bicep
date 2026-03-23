@description('A short name used to prefix all resources. Lowercase letters and numbers only. Max 10 characters.')
@minLength(3)
@maxLength(10)
param prefix string = 'orchex'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the Key Vault. Must be globally unique.')
param keyVaultName string = '${prefix}-kv'

@description('Name of the Storage Account. Must be globally unique, lowercase, max 24 chars.')
param storageAccountName string = '${prefix}storage'

@description('Name of the Function App. Must be globally unique.')
param functionAppName string = '${prefix}-api'

@description('Name of the Static Web App. Must be globally unique.')
param staticWebAppName string = '${prefix}-portal'

// ============================================
// STORAGE ACCOUNT
// ============================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

// ============================================
// KEY VAULT
// ============================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    accessPolicies: []
  }
}

// ============================================
// APP SERVICE PLAN (Consumption)
// ============================================

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${prefix}-plan'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {}
}

// ============================================
// FUNCTION APP
// ============================================

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      cors: {
        allowedOrigins: [
          'https://${staticWebAppName}.azurestaticapps.net'
        ]
        supportCredentials: false
      }
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'KeyVaultName'
          value: keyVaultName
        }
        {
          name: 'SetupComplete'
          value: 'false'
        }
        {
          name: 'PublicClientApp'
          value: 'true'
        }
        {
          name: 'StaticWebAppName'
          value: staticWebAppName
        }
        {
          name: 'TenantId'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=TenantId)'
        }
        {
          name: 'ApplicationId'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=ApplicationId)'
        }
        {
          name: 'ApplicationSecret'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=ApplicationSecret)'
        }
        {
          name: 'RefreshToken'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=RefreshToken)'
        }
        {
          name: 'LicenceKey'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=LicenceKey)'
        }
        {
          name: 'LicenceApiUrl'
          value: 'https://orchex-licence-api.azurewebsites.net/api/ValidateLicence'
        }
      ]
    }
  }
  dependsOn: [
    keyVault
  ]
}

// ============================================
// KEY VAULT ACCESS POLICY — FUNCTION APP MI
// ============================================

resource keyVaultAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  name: 'add'
  parent: keyVault
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: functionApp.identity.principalId
        permissions: {
          secrets: [
            'get'
            'list'
            'set'
          ]
        }
      }
    ]
  }
}

// ============================================
// STATIC WEB APP
// ============================================

resource staticWebApp 'Microsoft.Web/staticSites@2023-01-01' = {
  name: staticWebAppName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    buildProperties: {
      skipGithubActionWorkflowGeneration: true
    }
  }
}

// ============================================
// OUTPUTS
// ============================================

output functionAppName string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output staticWebAppName string = staticWebApp.name
output staticWebAppHostname string = staticWebApp.properties.defaultHostname
output keyVaultName string = keyVault.name
output storageAccountName string = storageAccount.name
output functionAppPrincipalId string = functionApp.identity.principalId
