using './main.bicep'

// Secure parameters — provide at deployment time:
//   az deployment sub create ... \
//     --parameters azureOpenAiApiKey='<key>' apiToken='<token>'

param azureOpenAiApiKey = ''
param apiToken = ''
