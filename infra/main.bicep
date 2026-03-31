// PetTypeless Azure Infrastructure — main deployment template.
//
// Deploys all Azure resources needed to run the PetTypeless relay server:
//   - Resource Group
//   - Azure Container Registry (Docker images)
//   - Log Analytics Workspace (Container Apps logging)
//   - Container Apps Environment + Container App (the server itself)
//
// The server proxies audio to 豆包 (Doubao) bigmodel_async ASR via WebSocket.
//
// Usage:
//   az deployment sub create --location eastasia \
//     --template-file infra/main.bicep \
//     --parameters infra/main.bicepparam

targetScope = 'subscription'

// ── Parameters ──────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = 'eastasia'

@description('豆包 ASR App Key.')
@secure()
param doubaoAppKey string

@description('豆包 ASR Access Key.')
@secure()
param doubaoAccessKey string

@description('Client authentication token.')
@secure()
param apiToken string

// ── Resource Group ──────────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'pet-typeless'
  location: location
}

// ── Modules ─────────────────────────────────────────────────────

module acr 'modules/containerRegistry.bicep' = {
  name: 'containerRegistry'
  scope: rg
  params: {
    location: location
  }
}

module logs 'modules/logAnalytics.bicep' = {
  name: 'logAnalytics'
  scope: rg
  params: {
    location: location
  }
}

module containerApps 'modules/containerApps.bicep' = {
  name: 'containerApps'
  scope: rg
  params: {
    location: location
    // Log Analytics
    logAnalyticsCustomerId: logs.outputs.customerId
    logAnalyticsSharedKey: logs.outputs.sharedKey
    // ACR
    acrLoginServer: acr.outputs.loginServer
    acrUsername: acr.outputs.username
    acrPassword: acr.outputs.password
    // 豆包 ASR
    doubaoAppKey: doubaoAppKey
    doubaoAccessKey: doubaoAccessKey
    // App auth
    apiToken: apiToken
  }
}

// ── Outputs ─────────────────────────────────────────────────────

@description('Container App FQDN for WebSocket connections.')
output appFqdn string = containerApps.outputs.fqdn

@description('ACR login server for docker push.')
output acrLoginServer string = acr.outputs.loginServer
