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
