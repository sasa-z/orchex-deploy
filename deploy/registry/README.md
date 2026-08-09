# Container registry

Lives in the vendor's subscription, not the customer's — the only part of the product that does.
Images are built once here and pulled by every deployment.

Private, because the image carries `CAMPCore.bundle.ps1`: the backend in plain text.

## Create it

```bash
az group create --name orchex-registry --location westeurope

az deployment group create \
  --resource-group orchex-registry \
  --template-file deploy/registry/main.bicep \
  --parameters registryName=orchexregistry customers='["contoso","fabrikam"]'
```

Take `loginServer` from the outputs. It is not necessarily `<name>.azurecr.io` — with a secured
domain name label the FQDN carries a suffix, so read it rather than assuming it. That value is
`ACR_LOGIN_SERVER` in the three build pipelines.

## Issue a customer's credentials

Token passwords can only be read when they are generated, which is why the template does not
produce them — emitting one would either leak it into deployment history or hand back something
already unusable.

```bash
az acr token credential generate \
  --registry orchexregistry \
  --name pull-contoso \
  --password1 --expiration-in-days 365
```

Put the token name and password into that customer's Key Vault as `RegistryUsername` and
`RegistryPassword`. Their App Service reads them from there rather than holding them in plain app
settings.

## Withdraw one

```bash
az acr token update --registry orchexregistry --name pull-contoso --status disabled
```

Their running container keeps working; it simply stops receiving new versions. Every other customer
is untouched, which is the reason for a token each rather than one shared credential.

## What a customer token can reach

`orchex-api` only. That image already contains the runtime and frontend layers, so there is no need
for a customer credential to reach those repositories on their own — and good reason for it not to.
