@description('A short name used to prefix all resources. Lowercase letters and numbers only. Max 10 characters.')
@minLength(3)
@maxLength(10)
param prefix string = 'orchex'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the Key Vault. Must be globally unique.')
param keyVaultName string = '${prefix}-kv'

@description('Name of the Storage Account. Must be globally unique, lowercase, max 24 chars.')
param storageAccountName string = '${prefix}${take(uniqueString(resourceGroup().id), 8)}str'

@description('Name of the Function App. Must be globally unique.')
param functionAppName string = '${prefix}-api'

@description('Name of the Static Web App. Must be globally unique.')
param staticWebAppName string = '${prefix}-portal'

@description('Name of the Log Analytics Workspace.')
param logAnalyticsName string = '${prefix}-logs'

@description('Name of the Application Insights instance.')
param appInsightsName string = '${prefix}-insights'

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

// Lifecycle policy: auto-delete orchex-results blobs after 1 day
resource blobLifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'delete-orchex-results'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [ 'blockBlob' ]
              prefixMatch: [ 'orchex-results/' ]
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 1
                }
              }
            }
          }
        }
      ]
    }
  }
}

// ============================================
// LOG ANALYTICS WORKSPACE
// ============================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ============================================
// APPLICATION INSIGHTS
// ============================================

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
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
    // Prevents permanent purge of secrets/vault within the retention window.
    // IRREVERSIBLE once enabled — the vault cannot be force-deleted until retention expires.
    enablePurgeProtection: true
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
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'StorageConnectionString'
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
          // Max PowerShell runspaces per worker — lets ONE warm worker serve this many
          // concurrent HTTP invocations instead of the host spinning up a cold worker per
          // request (the post-deploy 500 burst). CIPP uses 10; this is the value the portal's
          // refresh burst is sized for. Each invocation gets its own runspace (isolated state;
          // shared cache is AppDomain, thread-safe).
          name: 'PSWorkerInProcConcurrencyUpperBound'
          value: '10'
        }
        {
          // In-process concurrency (above) instead of multiple worker processes.
          name: 'FUNCTIONS_WORKER_PROCESS_COUNT'
          value: '1'
        }
        {
          // Run from the deployed zip mounted read-only (atomic deploy + faster cold start)
          // instead of extracting hundreds of files onto the Azure Files content share. CIPP
          // uses this. Setting it makes the functions-action zipdeploy store+mount the package.
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          // Load the Windows user profile so a CNG key-store path exists for the worker. Without it,
          // loading the SAM certificate PFX (private key, for SharePoint cert-based app-only auth)
          // fails on the Windows Consumption plan with the misleading
          // "The system cannot find the file specified" — both EphemeralKeySet and Exportable throw.
          name: 'WEBSITE_LOAD_USER_PROFILE'
          value: '1'
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
          value: 'https://orchex-licence-api-v2-ebgtebbhgsa7dycz.westeurope-01.azurewebsites.net/api/ValidateLicence'
        }
        {
          // Same app registration as ApplicationId — used by MCP OAuth JWT validation
          name: 'McpClientId'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=ApplicationId)'
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
// MCP CLIENT MANAGEMENT — function MI can write its own Easy Auth (authsettingsV2)
// ============================================
// The "MCP Clients" portal feature adds each new client's appId to the function's
// App Service Authentication via the function's managed identity. Writing authsettingsV2
// is an ARM operation, so the MI needs Contributor on this site (scoped to the site only).

resource mcpEasyAuthRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionApp.id, 'Contributor', 'mcp-easyauth')
  scope: functionApp
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    // Contributor
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
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
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
