# Orchex — Deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsasa-z%2Forchex-deploy%2Fmain%2Fdeploy%2Fappservice%2Farm%2Fmain.json)

Orchex is a self-hosted MSP portal for managing Microsoft 365 tenants. Each MSP deploys their own independent instance to their own Azure subscription.

## What gets deployed

| Resource         | Type                        | Notes                                          |
| ----------------- | --------------------------- | ----------------------------------------------- |
| App Service       | Linux, container, Basic B2  | Runs the Orchex backend and frontend together, in one container |
| App Service Plan  | Basic B2                    | Always-on — no idle eviction between requests   |
| Key Vault         | Standard                    | Stores credentials securely                     |
| Storage Account   | Standard LRS                | Tables for data & logs                          |

The App Service is deployed with:

- System Assigned Managed Identity
- Key Vault access policy configured automatically (Get, List, Set)
- Contributor on itself, scoped to the site — the portal's own MCP client management needs it to write the site's `authsettingsV2` (Easy Auth configuration) via ARM
- Container registry credentials pre-configured as app settings (plain values, not Key Vault references — the platform pulls the image before the site runs, before any reference would have resolved)

Application Insights is not created by default — it bills per gigabyte ingested, so that cost is opt-in rather than assumed. Set `appInsightsName` in `deploy/appservice/main.bicep` if you want it.

## Prerequisites

- Azure subscription
- Azure CLI installed (`az` command) — only needed for Option B below
- Container registry credentials for this installation, issued by Orchex

An **App Registration** in your Microsoft Partner tenant is also required, but you do not need to create it yourself beforehand — the Setup Wizard can register it for you (see "After deployment"). Create it by hand instead only if you would rather control that step directly.

## Deploy

### Option A — Deploy to Azure button (recommended)

Click the **Deploy to Azure** button above. It asks for five things; three arrive pre-filled:

| Parameter               | Description                                                              |
| ------------------------ | ------------------------------------------------------------------------ |
| `prefix`                 | Name prefix for all resources (e.g. `orchex`). Actual names are derived from this plus a suffix from the resource group, so you do not have to hand-pick globally unique names. |
| `containerRegistryHost`  | Pre-filled — the registry the image is pulled from.                      |
| `containerImage`         | Pre-filled (`orchex-api:latest` for a real installation).                |
| `registryUsername`       | The registry token issued for this installation.                         |
| `registryPassword`       | Its password — readable only when it was issued; store it somewhere safe. |

### Option B — Azure CLI

```bash
# Login
az login

# Create resource group
az group create --name orchex-rg --location eastus

# Deploy
az deployment group create \
  --resource-group orchex-rg \
  --template-file deploy/appservice/main.bicep \
  --parameters prefix=orchex \
               registryUsername=<issued-username> \
               registryPassword=<issued-password>
```

## After deployment

1. **First sign-in** — open the site's URL (deployment output `webAppUrl`). Sign-in is not configured yet, so the first request lands on `/setup`: enter the email of the first administrator, click **Start**, and sign in as a Global Administrator of your own tenant via a device code. Orchex registers a sign-in application in your tenant, configures Easy Auth with it, and restarts.
2. **Run the Setup Wizard** — your first real sign-in goes straight here. Choose **Set up the application for me** to have Orchex register the application that manages customer tenants and grant it its permissions automatically (recommended), or bring credentials for one you registered yourself. Finishes with Save & Validate and, for a newly created application, a link to grant admin consent — a step only a Global Administrator can complete, since Microsoft requires it to happen interactively.
3. **Add tenants via CPV** — Tenants → CPV, to grant the app access to each customer tenant through your GDAP relationships.

The in-portal Help (**Getting Started** / **Initial Setup**) covers the full walkthrough, including GDAP security groups, the service account, and the one-time SharePoint certificate step.

## Resource naming

Names are derived from `prefix` and a `uniqueString` of the resource group, so two installations never collide without anyone having to hand-pick unique names:

| Resource          | Name                                              |
| ------------------ | -------------------------------------------------- |
| App Service        | `<prefix>-<suffix>`                                |
| App Service Plan   | `<prefix>-<suffix>-plan`                           |
| Key Vault          | `<prefix>-<suffix>` (truncated to 24 characters)   |
| Storage Account    | `<prefix><suffix>` (lowercase, no dashes, truncated to 24 characters) |

## Migrating from Function App + Static Web App

Existing installations on the earlier two-resource deployment (`deploy/main.bicep`) are unaffected by any of the above — that template stays in place until cutover completes, as somewhere to fall back to. See `orchex-runtime/docs/cutover.md` for the migration plan, and `deploy/appservice/README.md` for running both deployments side by side while migrating one.
