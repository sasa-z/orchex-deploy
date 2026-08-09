# Compiled templates, for deploying from the portal

The portal's "Deploy a custom template" editor takes ARM JSON and does not compile Bicep, so these
are the same two templates in the form it accepts. The Bicep files a directory up remain the source
— regenerate rather than edit:

    az bicep build --file ../testenv.bicep --outfile testenv.json
    az bicep build --file ../main.bicep    --outfile main.json

## Deploying

Portal → *Deploy a custom template* → *Build your own template in the editor* → *Load file*.

`testenv.json` first: it creates the storage account and key vault that `main.json` expects to exist.
Its `operatorObjectId` is your own user object id, from Entra ID → Users → your account → Object ID.
Leaving it empty deploys, but nobody gets access to the vault and the secrets cannot be added.

Then the two registry secrets, by hand, before `main.json` — the app cannot start without them.

`main.json` last. Take `storageAccountName` from the first deployment's outputs.
