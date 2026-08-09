// The container registry, in the vendor's own subscription — the one piece of this product that
// does not live at the customer.
//
// Images are built once and pulled by every customer deployment. A registry per customer would mean
// pushing the same image into every subscription, which is both harder and pointless.
//
// Private because the image carries CAMPCore.bundle.ps1: the backend in plain text. Publishing it
// publicly would publish the source with it.

@description('Registry name. Alphanumeric only — no hyphens — and globally unique.')
@minLength(5)
@maxLength(50)
param registryName string = 'orchexregistry'

@description('Azure region.')
param location string = resourceGroup().location

@description('''
Customers to issue pull tokens for. Each gets its own credentials, scoped to the application image
only, so access can be withdrawn from one deployment without rotating anything for the others.
''')
param customers array = []

// Basic is enough: a handful of repositories, tens of gigabytes at most, and pulls that happen on
// deploy and restart rather than continuously. Premium buys geo-replication and private endpoints,
// neither of which a vendor registry pulled from customer subscriptions can use.
resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    // Scoped tokens authenticate with a username and password, which is what a customer's App
    // Service can use. Managed identity would be better, but the registry is in this tenant and
    // each app is in the customer's, and cross-tenant RBAC does not reach across that.
    adminUserEnabled: false
  }
}

// Customers pull the application image and nothing else. It already contains the runtime and
// frontend layers, so there is no reason for a customer credential to reach those repositories
// separately — and every reason not to.
resource customerScope 'Microsoft.ContainerRegistry/registries/scopeMaps@2023-11-01-preview' = {
  parent: registry
  name: 'customer-pull'
  properties: {
    description: 'Pull the application image only'
    actions: [
      'repositories/orchex-api/content/read'
      'repositories/orchex-api/metadata/read'
    ]
  }
}

// One token per customer, each with its own password, so revoking one leaves the rest working.
resource customerTokens 'Microsoft.ContainerRegistry/registries/tokens@2023-11-01-preview' = [
  for customer in customers: {
    parent: registry
    name: 'pull-${customer}'
    properties: {
      scopeMapId: customerScope.id
      status: 'enabled'
    }
  }
]

// Passwords are deliberately not generated here. A token password can only be read at the moment it
// is created, so emitting it from a template would either leak it into deployment history or be
// unusable. Generate them with:
//
//   az acr token credential generate --registry <name> --name pull-<customer> \
//     --password1 --expiration-in-days 365
//
// and put the result straight into that customer's Key Vault as RegistryUsername/RegistryPassword.

output loginServer string = registry.properties.loginServer
output registryName string = registry.name
