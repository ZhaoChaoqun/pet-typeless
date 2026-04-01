// Container Apps Environment + Container App for pet-typeless-server.
//
// Runs the relay server with WebSocket support, scaled 0–1 replicas.
// All sensitive values are injected via Container Apps secrets.

param location string

// Log Analytics (for Container Apps Environment)
param logAnalyticsCustomerId string
param logAnalyticsSharedKey string

// ACR credentials
param acrLoginServer string
param acrUsername string
@secure()
param acrPassword string

// 豆包 ASR
@secure()
param doubaoAppKey string
@secure()
param doubaoAccessKey string
param doubaoResourceId string

// App auth
@secure()
param apiToken string

// ── Container Apps Environment ──────────────────────────────────

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'pet-typeless-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
  }
}

// ── Container App ───────────────────────────────────────────────

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'pet-typeless-server'
  location: location
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: acrLoginServer
          username: acrUsername
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        { name: 'acr-password', value: acrPassword }
        { name: 'doubao-app-key', value: doubaoAppKey }
        { name: 'doubao-access-key', value: doubaoAccessKey }
        { name: 'api-token', value: apiToken }
      ]
    }
    template: {
      containers: [
        {
          name: 'pet-typeless-server'
          image: '${acrLoginServer}/pet-typeless-server:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'DOUBAO_APP_KEY', secretRef: 'doubao-app-key' }
            { name: 'DOUBAO_ACCESS_KEY', secretRef: 'doubao-access-key' }
            { name: 'DOUBAO_RESOURCE_ID', value: doubaoResourceId }
            { name: 'API_TOKEN', secretRef: 'api-token' }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

@description('Container App FQDN (e.g. pet-typeless-server.<hash>.eastasia.azurecontainerapps.io).')
output fqdn string = app.properties.configuration.ingress.fqdn
