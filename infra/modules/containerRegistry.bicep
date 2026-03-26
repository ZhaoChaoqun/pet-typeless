// Azure Container Registry — stores the pet-typeless-server Docker image.

param location string
param name string = 'pettypelessacr'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

@description('ACR login server (e.g. pettypelessacr.azurecr.io).')
output loginServer string = acr.properties.loginServer

@description('ACR admin username.')
output username string = acr.listCredentials().username

@description('ACR admin password.')
output password string = acr.listCredentials().passwords[0].value
