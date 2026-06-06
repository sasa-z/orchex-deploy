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

2. **Register client for deployment** — Add publish profile and SWA token as GitHub Secrets in `orchex-api` and `orchex` repos, add entry to `.github/clients.json` in each repo
3. **Create Static Web App** — In Azure Portal, create SWA with Source: **Other** (not GitHub), then get deployment token via `az staticwebapp secrets list`
4. **Link backend** — Azure Portal → SWA → APIs → Link backend → select Function App
5. **Add first admin** — Azure Portal → Static Web App → Role Management → Invite → Role: `SuperAdmin`
6. **Run Setup Wizard** — Log in to the portal, complete the setup wizard with your App Registration credentials

## Security hardening (recommended)

> **Scope — platform/infrastructure security, not tenant-facing features.** This section is about hardening *your own ORCHEX deployment* — the Azure resources that host the portal and who/what can reach the backend. It is **not** about the security capabilities ORCHEX provides for your managed customer tenants (CA health, secure score, anomalous sign-in alerting, etc.). In short: this protects the ORCHEX instance itself, not the tenants it manages.

When you **Link backend** (step 4), Azure automatically enables **App Service Authentication (Easy Auth)** on the Function App. This is the outermost protection: every direct request to the backend is rejected with `401` before any code runs, so only traffic coming through the Static Web App is accepted.

> ⚠️ **Do not disable App Service Authentication** on the Function App (do not switch the action for unauthenticated requests to "Allow") unless you replace it with equivalent network isolation (e.g. a private endpoint). Without it the backend would accept direct unauthenticated requests — the single most important protection for the portal.

To harden the configuration:

1. **Restrict Azure RBAC** — keep the number of people with `Contributor`/`Owner` on the Function App resource to a minimum. Anyone with that access can change the authentication settings.

2. **Alert on authentication config changes** — get notified immediately if Easy Auth is ever modified:
   - Azure Portal → **Monitor → Alerts → Create → Alert rule**
   - **Scope** → select your Function App resource
   - **Condition** → Signal type **Activity Log** → operation **`Microsoft.Web/sites/config/write`** ("Update Web Apps Configuration", category *Administrative*)
   - **Actions** → create/select an action group (email/SMS/webhook) to notify you
   - **Details** → name it e.g. `orchex-funcapp-config-changed` → Create
   - Note: this fires on any site-config change (incl. app settings), not only auth — that is intentionally broad for a security-critical app. Activity Log alerts are free.

3. **(Optional) Periodic verification** — confirm the backend still rejects forged direct calls. From any machine with internet access:
   ```bash
   FUNC="https://<your-funcapp-host>.azurewebsites.net"
   PRINC=$(printf '{"userId":"x","userRoles":["SuperAdmin"]}' | base64 -w0)
   curl -s -o /dev/null -w "%{http_code}\n" -X POST "$FUNC/api/GetPortalSettings" -H "x-ms-client-principal: $PRINC"
   # Expected: 401  (anything else → Easy Auth is not blocking → investigate)
   ```

### Key Vault

The Key Vault holds the app credentials, refresh token, and break-glass passwords — protecting it is as important as protecting the backend. The template already enables soft delete (90-day retention), scopes the Function App's managed identity to `get`/`list`/`set` on secrets only, and disables deployment/template/disk-encryption access.

4. **Purge protection** — new deployments set `enablePurgeProtection: true` automatically. For an **existing** vault, enable it manually: Azure Portal → Key Vault → **Settings → Properties → Purge protection → Enable**. Without it, anyone with access can permanently purge secrets within the soft-delete window. *(Note: purge protection is irreversible once enabled.)*

5. **Diagnostic logging** — Key Vault → **Monitoring → Diagnostic settings → Add** → select **`AuditEvent`** → send to a Log Analytics workspace. Then alert on dangerous operations (`SecretPurge`, `VaultDelete`, or `SecretGet` from an unexpected identity).

6. **Alert on access-policy / config changes** — Monitor → Alerts → Create → Alert rule, Scope = the Key Vault, Activity Log signal on operations **`Microsoft.KeyVault/vaults/write`** and **`Microsoft.KeyVault/vaults/accessPolicies/write`** → notifies you if someone grants themselves access to the vault.

7. **RBAC lockdown** — limit `Contributor`/`Owner` on the Key Vault resource. In the access-policy model, a Contributor can add an access policy for themselves and read every secret.

## Resource naming

All resources are prefixed with the `prefix` parameter. Default names:

| Resource         | Default name    |
| ---------------- | --------------- |
| Function App     | `orchex-api`    |
| Static Web App   | `orchex-portal` |
| Key Vault        | `orchex-kv`     |
| Storage Account  | `orchexstorage` |
| App Service Plan | `orchex-plan`   |
