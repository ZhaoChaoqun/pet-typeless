using './main.bicep'

// Secure parameters — provide at deployment time:
//   az deployment sub create ... \
//     --parameters doubaoAppKey='<key>' doubaoAccessKey='<key>' apiToken='<token>'

param doubaoAppKey = ''
param doubaoAccessKey = ''
param apiToken = ''
