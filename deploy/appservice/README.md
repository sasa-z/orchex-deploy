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

Two buttons, in this order. The portal fetches each template from GitHub and draws the form itself —
nothing to download, nothing to paste.

**1. Storage and key vault** — what `main` expects to already exist.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsasa-z%2Forchex-deploy%2Fmain%2Fdeploy%2Fappservice%2Farm%2Ftestenv.json)

`yourUserObjectId` is your own object id, from Entra ID → Users → your account. Left empty the
deployment still succeeds, but nobody can add secrets to the vault afterwards.

**2. Add the registry credentials** to that vault, as `RegistryUsername` and `RegistryPassword`.
Generate the password in your own subscription under Container registry → Tokens → `pull-test` →
Generate password; it is readable only at that moment. The app cannot start without these.

**3. The application.**

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsasa-z%2Forchex-deploy%2Fmain%2Fdeploy%2Fappservice%2Farm%2Fmain.json)

`containerImage` is `orchex-api:develop` for a test deployment and `orchex-api:latest` for a real
one. `storageAccountName` comes from the first deployment's outputs.

Both buttons read from `main`, so a template still only on a branch will not appear there until it
is merged.
