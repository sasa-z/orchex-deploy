// The storage account and key vault a side-by-side test deployment needs.
//
// main.bicep expects both to exist already, because at a customer they do — the Functions
// deployment created them. A test environment in its own resource group starts empty, and this
// fills that gap.
//
// Deliberately separate from the customer's own resources. Fresh tables mean the setup wizard runs
// from the beginning, which is the point of the exercise; sharing them would mean two deployments
// writing the same rows.

@description('Prefix for resource names.')
param prefix string = 'orchextest'

// Not a parameter: the portal already asks for a region above the parameter list, and asking twice
// produced a field showing a raw template expression that it would not let anyone edit.
var location = resourceGroup().location

@description('''
Your own user object id, from Entra ID > Users > your account > Object ID. It grants you access to
add the registry credentials to the vault. Leaving it empty deploys, but then nobody can.
''')
param operatorObjectId string = ''

// Storage accounts, key vaults and app service hostnames all live in a global namespace, so a
// plain prefix collides with whoever took it first. uniqueString is derived from the resource group
// id, which makes it stable across redeployments and identical in both templates — so the two agree
// on every name without anyone copying a value between them.
var suffix = uniqueString(resourceGroup().id)
var storageName = toLower(take(replace('${prefix}${suffix}', '-', ''), 24))
var vaultName = take('${prefix}-${suffix}', 24)

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
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

// Access policies rather than RBAC, because main.bicep grants the app's managed identity through
// an access policy and a vault with `enableRbacAuthorization` set ignores those — the deployment
// succeeds and the app then cannot read a single secret. The customer's own vault, created by the
// Functions deployment, works the same way, so matching it keeps the two environments comparable.
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: false
    enableSoftDelete: true
    // Short, because a test vault gets torn down and recreated under the same name, and the
    // default retention makes the name unavailable for ninety days.
    softDeleteRetentionInDays: 7
    accessPolicies: empty(operatorObjectId) ? [] : [
      {
        tenantId: subscription().tenantId
        objectId: operatorObjectId
        permissions: {
          secrets: ['get', 'list', 'set', 'delete']
        }
      }
    ]
  }
}

output storageAccountName string = storage.name
output keyVaultName string = vault.name
output connectionStringHint string = 'az storage account show-connection-string -n ${storage.name} -g ${resourceGroup().name} --query connectionString -o tsv'
