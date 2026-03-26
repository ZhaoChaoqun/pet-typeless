// Azure Speech Services — used for ASR (continuous speech recognition).

param location string
param name string = 'pet-typeless-speech'

resource speech 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  kind: 'SpeechServices'
  sku: {
    name: 'S0'
  }
  properties: {}
}

@description('Primary access key for the Speech service.')
output key string = speech.listKeys().key1

@description('Region where the Speech service is deployed.')
output region string = location
