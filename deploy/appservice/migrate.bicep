// Adds the App Service to an installation whose storage and Key Vault predate the naming scheme
// in main.bicep.
//
// main.bicep derives every name from a prefix and uniqueString(resourceGroup().id), which lets a
// migrating installation reconcile with the resources the Functions deployment already created —
// but only if those were created from deploy/main.bicep. The original installation was not: its
// vault is 'orchex' with no suffix, and its storage account carries an older prefix entirely. Run
// main.bicep there and it creates an empty storage account and an empty vault beside the real ones,
// and the portal comes up looking at nothing.
//
// So the shared resources are parameters here, and referenced rather than declared. That also
// removes a sharper hazard: main.bicep declares the vault with accessPolicies set to an empty
// array, and a full ARM PUT over a live vault replaces that list. Against the running installation
// it would revoke the Function App's access to the SAM certificate — while the Function App is
// still the fallback.
//
// Temporary. Once the Static Web App and Function App are deleted, no installation needs this and
// it should go with them; leaving it behind makes an obsolete path look like a supported one.

@description('Name for the App Service and its plan. The plan is this plus "-plan".')
param webAppName string

@description('Existing storage account shared with the Functions deployment. Orchestration state lands in new tables in the same account, so a run started under one host is visible to the other.')
param storageAccountName string

@description('Existing Key Vault holding the application secrets.')
param keyVaultName string

@description('Existing Application Insights instance. Empty leaves telemetry off, and the runtime logs to its rotating files only — it bills by the gigabyte ingested, which a verbose PowerShell workload reaches quickly.')
param appInsightsName string = ''

@description('Region for the App Service and its plan. Set it to the region the storage account is in, not the resource group\'s: a group carries a location of its own that need not match what is in it, and on the original installation it does not — the group is centralus while the storage account, the vault and the Function App are all eastus. Taking the group\'s location would put the App Service a region away from its own tables, on every read. Required rather than defaulted, because the wrong answer is silent.')
param location string

@description('Registry hosting the image.')
param containerRegistryHost string = 'orchexregistry-hkana5hacfdncphk.azurecr.io'

@description('Container image and tag within that registry.')
param containerImage string = 'orchex-api:latest'

@description('Registry token issued for this installation.')
param registryUsername string

@description('Password for that token. Readable only when it was generated.')
@secure()
param registryPassword string

var licenceApiUrl = 'https://orchex-licence-api-v2-ebgtebbhgsa7dycz.westeurope-01.azurewebsites.net/api/ValidateLicence'

var httpPoolSize = 4
var backgroundPoolSize = 8

// ============================================================================
// Shared resources — referenced, never declared
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = if (!empty(appInsightsName)) {
  name: appInsightsName
}

// ============================================================================
// App settings
// ============================================================================

var baseAppSettings = [
  // ── Container ────────────────────────────────────────────────────────────
  // The site's own ARM coordinates. Setup writes this site's authsettingsV2 through its managed
  // identity and has to address itself to do it — and a Linux container is not given the WEBSITE_*
  // variables a Windows host would use to work them out.
  {
    name: 'ORCHEX_SUBSCRIPTION_ID'
    value: subscription().subscriptionId
  }
  {
    name: 'ORCHEX_RESOURCE_GROUP'
    value: resourceGroup().name
  }
  {
    name: 'ORCHEX_SITE_NAME'
    value: webAppName
  }
  {
    name: 'DOCKER_REGISTRY_SERVER_URL'
    value: 'https://${containerRegistryHost}'
  }
  {
    // Plain values, not Key Vault references. The platform pulls the image before the site runs,
    // and a reference is only resolved once it does — so the password reads as empty at exactly the
    // moment it is needed, and the pull fails with "unauthorized" while the vault holds the right
    // value all along.
    name: 'DOCKER_REGISTRY_SERVER_USERNAME'
    value: registryUsername
  }
  {
    name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
    value: registryPassword
  }
  {
    // The container listens here; without this App Service probes port 80 and the app looks dead
    // however healthy it is.
    name: 'WEBSITES_PORT'
    value: '8080'
  }
  {
    name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
    value: 'false'
  }

  // ── Runtime sizing ───────────────────────────────────────────────────────
  {
    name: 'ORCHEX_HTTP_POOL_SIZE'
    value: string(httpPoolSize)
  }
  {
    name: 'ORCHEX_BG_POOL_SIZE'
    value: string(backgroundPoolSize)
  }
  {
    // Off, and it has to stay off until the Functions timer is disabled in the same sitting. Two
    // hosts both firing timers run every nightly sweep twice — CPV, standards enforcement, the
    // alert engine — against the same live data. Program.cs compares this to the exact string
    // 'true', so 'True' and '1' read as off.
    name: 'ORCHEX_SCHEDULER_ENABLED'
    value: 'false'
  }

  // ── Application ──────────────────────────────────────────────────────────
  // Spelling matters: environment variable names are case-sensitive on Linux and orchex-api reads
  // exactly these. A mismatch does not fail loudly — the tenant check reads "if ($mspTenantId)", so
  // an empty read skips it and admits principals from other tenants.
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
    // Shared with the Functions deployment, and where orchestration state is written too.
    name: 'StorageConnectionString'
    value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  }
  {
    name: 'KeyVaultName'
    value: keyVaultName
  }
  {
    name: 'LicenceApiUrl'
    value: licenceApiUrl
  }
  {
    // Empty on purpose. This is the MCP resource application, which does not exist until someone
    // runs Set up MCP — so there is no id to write at deployment time. Seeding it with the SAM
    // application's id was worse than leaving it unset: never correct, and non-empty, so the portal
    // reported MCP as already provisioned and hid the button that would have provisioned it.
    // Setup writes the real id into portal settings; Get-McpResourceAppId reads that first and
    // falls back to this only for deployments made before it did.
    name: 'McpClientId'
    value: ''
  }
  {
    name: 'PublicClientApp'
    value: 'true'
  }
  {
    // Already true on the installation this template is for: it has been running for months, the
    // wizard is long done, and the user table is not empty. Setting it here keeps the new host
    // agreeing with the old one rather than offering setup to an installation that has it.
    name: 'SetupComplete'
    value: 'true'
  }
  {
    // The heartbeat chain relit itself so scheduled work survived the host being evicted overnight.
    // Nothing evicts this one. Also set in the image; repeated here so the reason is visible to
    // anyone reading the deployment.
    name: 'CAMPHeartbeatDisabled'
    value: 'true'
  }
]

var telemetryAppSettings = empty(appInsightsName) ? [] : [
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsights.properties.ConnectionString
  }
]

// ============================================================================
// Plan and app
// ============================================================================

// B2 rather than B1: the PowerShell modules are memory-hungry, and measured at roughly 40 MB per
// runspace over a ~550 MB base, twelve runspaces come to about 1 GB. B1's 1.75 GB leaves no room.
// Basic is always-on, which is the whole point — Consumption's idle eviction is what this replaces.
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${webAppName}-plan'
  location: location
  kind: 'linux'
  sku: {
    name: 'B2'
    tier: 'Basic'
  }
  properties: {
    reserved: true // required for Linux
  }
}

resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: webAppName
  location: location
  kind: 'app,linux,container'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|${containerRegistryHost}/${containerImage}'
      alwaysOn: true
      http20Enabled: true
      // Answered without touching PowerShell, so it stays truthful while the pool is saturated.
      healthCheckPath: '/health'
      appSettings: concat(baseAppSettings, telemetryAppSettings)
    }
  }
}

// ============================================================================
// Permissions
// ============================================================================

// Additive: a vaults/accessPolicies child named 'add' appends, where setting accessPolicies on the
// vault itself would replace the list. That distinction is why the vault above is referenced and
// not declared — the Function App's own policy has to survive this, since it is the fallback until
// the last phase.
//
// Key Vault references in the settings above are resolved by the platform using this identity, so
// without the policy the app starts and every secret reads as the literal '@Microsoft.KeyVault(...)'
// string rather than failing — which is how that mistake usually gets found, late.
resource keyVaultAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  parent: keyVault
  name: 'add'
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: webApp.identity.principalId
        permissions: {
          secrets: ['get', 'list', 'set']
        }
      }
    ]
  }
}

// The portal's MCP client management writes this site's own authsettingsV2 when a client is
// registered, which is an ARM operation. Scoped to the site, not the resource group.
resource mcpEasyAuthRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(webApp.id, 'Contributor', 'mcp-easyauth')
  scope: webApp
  properties: {
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
    // Contributor
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  }
}

output webAppName string = webApp.name
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output principalId string = webApp.identity.principalId
output location string = location
