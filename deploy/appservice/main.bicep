// Linux App Service running the orchex container, replacing the Function App + Static Web App pair.
//
// Deployed alongside ../main.bicep rather than in place of it: the Functions deployment stays until
// cutover so there is somewhere to fall back to, and having both here makes the difference legible
// and the eventual deletion one commit.
//
// Storage, Key Vault, Log Analytics and Application Insights are shared with the existing
// deployment and referenced, not recreated. Orchestration state lands in new tables in the same
// account, so a run started under one host is visible to the other.

@description('Prefix for resource names. Must match the Functions deployment so the shared resources resolve.')
param prefix string = 'orchex'

// Not a parameter: the portal asks for a region above the parameter list, so exposing it again
// showed a raw template expression in a field it would not let anyone edit.
var location = resourceGroup().location

// Derived, not asked. Everything below follows the prefix the same way testenv.bicep does, so the
// two deployments agree without anyone copying values between them — which is where the storage
// account name used to come from, by hand, from the other deployment's outputs.
// Storage accounts, key vaults and app service hostnames all live in a global namespace, so a
// plain prefix collides with whoever took it first. uniqueString is derived from the resource group
// id, which makes it stable across redeployments and identical in both templates — so the two agree
// on every name without anyone copying a value between them.
var suffix = uniqueString(resourceGroup().id)
var webAppName = '${prefix}-${suffix}'

@description('Registry hosting the image.')
param containerRegistryHost string = 'orchexregistry-hkana5hacfdncphk.azurecr.io'

@description('Container image and tag within that registry.')
param containerImage string = 'orchex-api:latest'

@description('''
Registry token issued for this customer, from the vendor. A token per customer rather than one
shared credential, so it can be revoked on its own without touching any other installation.

Given here rather than through Key Vault: App Service reads these from its own configuration either
way, and a vault reference only added a manual step where someone had to type them in first.
Managed identity would avoid credentials entirely, but the registry is in the vendor's tenant and
this app in the customer's, and cross-tenant RBAC does not reach across that.
''')
param registryUsername string

@description('Password for that token. Readable only when it was generated.')
@secure()
param registryPassword string

var keyVaultName = take('${prefix}-${suffix}', 24)

var storageAccountName = toLower(take(replace('${prefix}${suffix}', '-', ''), 24))

// Off unless someone edits this. It bills by the gigabyte ingested and that bill lands on the
// customer, so it is not a question worth putting in front of every installation.
var appInsightsName = ''

// The full hostname, including the suffix Azure now assigns. A site created under the newer naming
// does not answer on the short name at all, so the old value failed as "name or service not known" —
// which reads as a network problem rather than as an address that no longer exists.
var licenceApiUrl = 'https://orchex-licence-api-v2-ebgtebbhgsa7dycz.westeurope-01.azurewebsites.net/api/ValidateLicence'

// Tuning, changeable afterwards as an app setting without redeploying — so not a question either.
var httpPoolSize = 4

var backgroundPoolSize = 8

// ============================================================================
// Storage and secrets
// ============================================================================
//
// Created here rather than expected to exist. They were separate because a customer migrating from
// the Functions deployment already has both — but a first installation has neither, and asking
// someone to run one template, wait, then run another is two chances to stop halfway.
//
// Existing resources of these names are left as they are: a deployment names them from the resource
// group, so a migrating installation that already has them reconciles rather than duplicates.

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

// Access policies rather than RBAC, because the app's managed identity is granted through one
// below, and a vault with enableRbacAuthorization set ignores those — it would deploy cleanly and
// then be unable to read a single secret.
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    accessPolicies: []
  }
}

// Optional. orchex is deployed into the customer's own subscription, so every per-instance cost is
// theirs and multiplies across installations — and Application Insights bills by the gigabyte
// ingested, which a verbose PowerShell workload reaches quickly. The runtime writes rotating files
// by default and reads them back through the portal, so a deployment without this is fully
// diagnosable; this is for operators who want KQL and alerting and accept the bill.
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = if (!empty(appInsightsName)) {
  name: appInsightsName
}

// ============================================================================
// App settings
// ============================================================================

// Built as a variable rather than inline so the optional Application Insights entry is a concat.
// Reading the site's own settings back to merge into them compiles, and then fails at deploy time
// because the resource is still being created.
var baseAppSettings = [
  // ── Container ────────────────────────────────────────────────────────────
  // The site's own ARM coordinates. Setup writes this site's authsettingsV2 through its managed
  // identity and has to address itself to do it — and a Linux container is not given the WEBSITE_*
  // variables a Windows host would use to work them out, which surfaces much later as an unparseable
  // address rather than as a missing value.
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
    // Otherwise App Service mounts persistent storage over /home, which shadows nothing here today
    // but makes the mount a silent hazard for anything later placed under it.
    name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
    value: 'false'
  }

  // ── Runtime sizing ───────────────────────────────────────────────────────
  // The background pool is the real ceiling on parallel activities: every dispatched operation
  // holds one for its duration. Sized against what Functions ran — 10 concurrent activities in a
  // single worker.
  {
    name: 'ORCHEX_HTTP_POOL_SIZE'
    value: string(httpPoolSize)
  }
  {
    name: 'ORCHEX_BG_POOL_SIZE'
    value: string(backgroundPoolSize)
  }
  {
    // Off until this deployment is the one that owns scheduled work. Two hosts both firing timers
    // run every nightly sweep twice.
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
    // Same app registration; MCP tokens are validated against it.
    name: 'McpClientId'
    value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=ApplicationId)'
  }
  {
    name: 'PublicClientApp'
    value: 'true'
  }
  {
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

// Absent unless an instance was named, and the runtime then logs to its rotating files only.
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

// Deliberately absent: WEBSITE_TIME_ZONE. Every timestamp is written and compared in UTC, and a
// local zone here would corrupt those comparisons rather than fail them.
//
// Also absent: WEBSITE_RUN_FROM_PACKAGE and WEBSITE_LOAD_USER_PROFILE. The first is a Functions
// zip-deploy mechanism with no container equivalent. The second existed so the Windows user profile
// held the CNG key store for certificate-based SharePoint auth; Linux has no such requirement.

// ============================================================================
// Permissions
// ============================================================================

// Key Vault references above are resolved by the platform using this identity, so without the
// policy the app starts and every secret reads as the literal '@Microsoft.KeyVault(...)' string
// rather than failing — which is how that mistake usually gets found, late.
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
