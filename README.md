# Orchex — Deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsasa-z%2Forchex-deploy%2Fmain%2Fdeploy%2Fmain.json)

Orchex is a self-hosted MSP portal for managing Microsoft 365 tenants. Each MSP deploys their own independent instance to their own Azure subscription

## What gets deployed

| Resource        | Type             | Notes                       |
| --------------- | ---------------- | --------------------------- |
| Function App    | Consumption plan | PowerShell 7.4 backend      |
| Static Web App  | Standard tier    | Vue 3 frontend              |
| Key Vault       | Standard         | Stores credentials securely |
| Storage Account | Standard LRS     | Tables for data & logs      |

The Function App is deployed with:

- System Assigned Managed Identity enabled
- Key Vault access policy configured automatically (Get, List, Set)
- App Settings pre-configured with Key Vault References

## Prerequisites

- Azure subscription
- Azure CLI installed (`az` command)
- Your own **App Registration** in your Microsoft Partner tenant

## Deploy

### Option A — Deploy to Azure button (recommended)

Click the **Deploy to Azure** button above. You will be prompted to fill in:

| Parameter            | Description                                                    |
| -------------------- | -------------------------------------------------------------- |
| `prefix`             | Short name prefix for all resources (e.g. `orchex`)            |
| `keyVaultName`       | Globally unique Key Vault name                                 |
| `storageAccountName` | Globally unique storage account name (lowercase, max 24 chars) |
| `functionAppName`    | Globally unique Function App name                              |
| `staticWebAppName`   | Globally unique Static Web App name                            |

### Option B — Azure CLI

```bash
# Login
az login

# Create resource group
az group create --name orchex-rg --location eastus

# Deploy
az deployment group create \
  --resource-group orchex-rg \
  --template-file deploy/main.bicep \
  --parameters deploy/main.parameters.json
```

## After deployment

1. **Create App Registration** — In your Microsoft Partner tenant (Entra ID → App registrations → New registration)
   - Name: `Orchex`
   - Supported account types: `Accounts in any organizational directory (Multitenant)`
   - Redirect URI: `https://login.microsoftonline.com/common/oauth2/nativeclient`
   - Manifest tab → replace contents with `OrchexManifestEntraID.json` from this repo → Save
   - **Expose an API → Application ID URI → Add → accept the default `api://{clientId}` → Save**
     (required for the MCP `McpAccess` scope to be valid; without it MCP OAuth tokens cannot be issued)
   - API permissions → Grant admin consent
   - Certificates & secrets → New client secret → save the value

2. **Link backend** — Azure Portal → Static Web App → APIs → Link backend → select the Function App deployed in step 1
3. **Add first admin** — Azure Portal → Static Web App → Role Management → Invite → enter your email → Role: `SuperAdmin`
4. **Run Setup Wizard** — Log in to the portal (URL shown in the deployment outputs as `staticWebAppHostname`), complete the setup wizard with your App Registration credentials from step 1

## Resource naming

All resources are prefixed with the `prefix` parameter. Default names:

| Resource         | Default name    |
| ---------------- | --------------- |
| Function App     | `orchex-api`    |
| Static Web App   | `orchex-portal` |
| Key Vault        | `orchex-kv`     |
| Storage Account  | `orchexstorage` |
| App Service Plan | `orchex-plan`   |
