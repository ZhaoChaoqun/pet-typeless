// PetTypeless Azure Infrastructure — main deployment template.
//
// Deploys all Azure resources needed to run the PetTypeless relay server:
//   - Resource Group
//   - Azure Speech Services (ASR)
//   - Azure Container Registry (Docker images)
//   - Log Analytics Workspace (Container Apps logging)
//   - Container Apps Environment + Container App (the server itself)
//
// Usage:
//   az deployment sub create --location eastasia \
//     --template-file infra/main.bicep \
//     --parameters infra/main.bicepparam
//
// Note: Azure OpenAI is NOT deployed here — we reuse an existing instance.

targetScope = 'subscription'

// ── Parameters ──────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = 'eastasia'

@description('Azure OpenAI API key (from existing deployment).')
@secure()
param azureOpenAiApiKey string

@description('Client authentication token.')
@secure()
param apiToken string

// ── Resource Group ──────────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'pet-typeless'
  location: location
}

// ── Modules ─────────────────────────────────────────────────────

module speech 'modules/speech.bicep' = {
  name: 'speech'
  scope: rg
  params: {
    location: location
  }
}

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
    // Speech
    azureSpeechKey: speech.outputs.key
    azureSpeechRegion: speech.outputs.region
    // Azure OpenAI (reuse existing deployment)
    azureOpenAiApiKey: azureOpenAiApiKey
    azureOpenAiEndpoint: 'https://91313-m78jipbi-eastus2.cognitiveservices.azure.com/'
    azureOpenAiDeployment: 'gpt-5.4-mini'
    azureOpenAiApiVersion: '2024-10-21'
    // App auth
    apiToken: apiToken
  }
}

// ── Outputs ─────────────────────────────────────────────────────

@description('Container App FQDN for WebSocket connections.')
output appFqdn string = containerApps.outputs.fqdn

@description('ACR login server for docker push.')
output acrLoginServer string = acr.outputs.loginServer
