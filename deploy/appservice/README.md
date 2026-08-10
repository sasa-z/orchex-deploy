# App Service deployment

The container deployment that replaces the Function App and Static Web App in `../main.bicep`.

Both exist at once on purpose. The Functions deployment stays until cutover so there is somewhere
to fall back to, and keeping them side by side makes the difference legible and the eventual
deletion one commit.

## What it creates

A Basic B2 Linux App Service plan and a container app on it, with a system-assigned identity, a
Key Vault access policy so secret references resolve, and Contributor on itself so the portal's MCP
client management can write its own `authsettingsV2`.

## What it reuses

Storage, Key Vault, Log Analytics and Application Insights are referenced, not recreated —
`storageAccountName` has no default because it carries a `uniqueString` and must be passed.

Orchestration state goes into new tables in the same storage account, so a run is visible to both
hosts during the transition.

## Deploy

```bash
az deployment group create \
  --resource-group MSP-O365-Portal \
  --template-file deploy/appservice/main.bicep \
  --parameters storageAccountName=<existing>
```

## Not done by this template

EasyAuth. It is a platform feature of `Microsoft.Web/sites` and works the same here as on the
Function App, but `authsettingsV2` is not declared as infrastructure — the running app writes it
when MCP clients are registered, so the template would fight it. Configure it on the new app the
way the Functions one was, and grant the same app registration.

The scheduler ships disabled. Turn `ORCHEX_SCHEDULER_ENABLED` on only when this deployment is the
one that owns scheduled work: two hosts both firing timers run every nightly sweep twice.

## Testing side by side

The customer's Functions deployment keeps running untouched. The container goes into a resource
group of its own, with its own storage and key vault, so nothing is shared and nothing is
duplicated:

```bash
az group create -n orchex-test -l westeurope

# Storage and key vault, which main.bicep expects to exist already.
az deployment group create -g orchex-test -f deploy/appservice/testenv.bicep \
  -p yourUserObjectId=$(az ad signed-in-user show --query id -o tsv)

# Registry credentials for this deployment. A token password is readable only when generated.
az acr token credential generate --registry orchexregistry --name pull-test \
  --password1 --expiration-in-days 90
az keyvault secret set --vault-name orchextest-kv --name RegistryUsername --value pull-test
az keyvault secret set --vault-name orchextest-kv --name RegistryPassword --value '<password1>'

az deployment group create -g orchex-test -f deploy/appservice/main.bicep \
  -p containerRegistryHost=orchexregistry-<suffix>.azurecr.io \
     containerImage=orchex-api:develop \
     keyVaultName=orchextest-kv \
     storageAccountName=<from the previous output>
```

`orchex-api:develop` rather than `:latest` — `latest` is what customer deployments pull, and only
main moves it.

Then set the repository variable `APP_SERVICE_NAME` so pushes to develop deploy here.

### Two things to get right before opening it

**Timers stay off.** Leave `ORCHEX_SCHEDULER_ENABLED` unset. Most timers do nothing without
configuration, and fresh tables have none — but `Start-TokenRenewal` writes a new refresh token
obtained from the same application the customer's deployment uses, which is shared state outside
this resource group. Turn the scheduler on later, deliberately, once the rest is known to work.

**It is reachable before it can authenticate.** Sign-in cannot be configured until the site is
running (see the runtime's `docs/easyauth-setup.md`), so there is a window where the portal answers
anyone who finds the URL. Nothing is configured yet, so there is little to take, but the window
should not be left open:

```bash
az webapp config access-restriction add -g orchex-test -n <app> \
  --rule-name operator --action Allow --ip-address <your-ip>/32 --priority 100
```

### Do not run CPV from the test deployment

Both deployments authenticate as the same Orchex-SAM application, and Partner Center consent is
recorded against the application rather than against whoever asked for it. So the consent the
customer's deployment relies on already covers the test one — there is nothing to grant.

Running it anyway is not a no-op. `Set-CAMPCPVConsent` deletes the existing `applicationconsents`
entry before creating the replacement, so a CPV run from the test deployment removes the consent
production is working through, and leaves it removed if the recreate fails.

Read-only checks against customer tenants are safe. It is the CPV consent path specifically, and the
scheduler that can reach it, that must stay untouched while both deployments are alive.


## Deploying from the portal

One button. The portal fetches the template from GitHub and draws the form itself.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsasa-z%2Forchex-deploy%2Fmain%2Fdeploy%2Fappservice%2Farm%2Fmain.json)

It asks for five things, and three arrive filled in:

- **Prefix** — how the resources are named. Everything else follows it, with a suffix derived from
  the resource group so the names are unique without anyone inventing them.
- **Container Registry Host** and **Container Image** — prefilled. Use `orchex-api:latest` for a
  real installation and `orchex-api:develop` to test an unreleased build.
- **Registry Username** and **Registry Password** — the token issued for this installation, from the
  vendor. One per installation, so it can be revoked without touching any other.

Everything else is created: the storage account, the key vault, the plan and the app, its managed
identity, and that identity's access to both the vault and its own configuration.

Nothing is written into the vault here — the setup wizard does that itself, through the identity
this grants.

### If the site starts and cannot pull its image

The symptom is `ImagePullUnauthorizedFailure` in the container log, and the site never answering.

Note first that `DOCKER_REGISTRY_SERVER_PASSWORD` always reads back as null through the app settings
API and the portal, however it was set — so an empty-looking value proves nothing, and is not
evidence the password is missing.

The reliable way to correct it is to set it directly rather than redeploy:

```bash
az acr token credential generate --registry orchexregistry --name pull-<customer> \
  --password1 --expiration-in-days 365 --query "passwords[0].value" -o tsv

az webapp config appsettings set -g <group> -n <app> \
  --settings DOCKER_REGISTRY_SERVER_PASSWORD='<value>'
```

Two things that produce this and are easy to miss: generating a token password invalidates the
previous one, so an installation using the old value stops being able to pull; and the value is 84
characters, long enough that a UI showing it truncated will hand over something that looks right and
is not.
