// Log Analytics Workspace — required by Container Apps Environment for logging.

param location string
param name string = 'pet-typeless-logs'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

@description('Log Analytics customer ID (workspace ID).')
output customerId string = workspace.properties.customerId

@description('Log Analytics shared key for Container Apps.')
output sharedKey string = workspace.listKeys().primarySharedKey
