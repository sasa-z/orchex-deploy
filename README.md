# Orchex — Deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsasa-z%2Forchex-deploy%2Fmain%2Fdeploy%2Fmain.bicep)

Orchex is a self-hosted MSP portal for managing Microsoft 365 tenants. Each MSP deploys their own independent instance to their own Azure subscription.

## What gets deployed

| Resource | Type | Notes |
|----------|------|-------|
| Function App | Consumption plan | PowerShell 7.4 backend |
| Static Web App | Standard tier | Vue 3 frontend |
| Key Vault | Standard | Stores credentials securely |
| Storage Account | Standard LRS | Tables for data & logs |

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

| Parameter | Description |
|-----------|-------------|
| `prefix` | Short name prefix for all resources (e.g. `orchex`) |
| `keyVaultName` | Globally unique Key Vault name |
| `storageAccountName` | Globally unique storage account name (lowercase, max 24 chars) |
| `functionAppName` | Globally unique Function App name |
| `staticWebAppName` | Globally unique Static Web App name |

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

1. **Upload backend code** — Deploy the Function App code from `msp-o365-portal-api`
2. **Deploy frontend** — Connect `msp-o365-portal` to the Static Web App via GitHub Actions
3. **Add first admin** — Azure Portal → Static Web App → Role Management → Invite → Role: `SuperAdmin`
4. **Run Setup Wizard** — Log in to the portal, complete the setup wizard with your App Registration credentials

## Resource naming

All resources are prefixed with the `prefix` parameter. Default names:

| Resource | Default name |
|----------|-------------|
| Function App | `orchex-api` |
| Static Web App | `orchex-portal` |
| Key Vault | `orchex-kv` |
| Storage Account | `orchexstorage` |
| App Service Plan | `orchex-plan` |
