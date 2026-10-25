param location string = resourceGroup().location

@minLength(3)
@maxLength(20)
param namePrefix string = 'xlsx-demo'

@description('Object ID of the operator who initializes the SQL schema.')
param sqlAdminObjectId string
param sqlAdminLogin string

@allowed(['User', 'Application'])
param sqlAdminPrincipalType string = 'User'

@description('The Office 365 connection is authorized separately after deployment.')
param workflowEnabled bool = false

@description('Mailbox the Function reads through Microsoft Graph.')
param mailboxAddress string

param subjectFilter string = 'Azure Functions showcase'
param mailFolder string = 'Inbox'

var suffix = uniqueString(resourceGroup().id, namePrefix)
var functionName = '${namePrefix}-${suffix}-func'

resource functionIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-function'
  location: location
}

resource workflowIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-workflow'
  location: location
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'xlsx${suffix}'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deployment'
  properties: { publicAccess: 'None' }
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource emailQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'email-imports'
}

resource poisonQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: '${emailQueue.name}-poison'
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource processedTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: 'processedattachments'
}

resource functionQueueAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionIdentity.id, 'queue-processing')
  scope: queueService
  properties: {
    principalId: functionIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  }
}

resource workflowQueueAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(emailQueue.id, workflowIdentity.id, 'enqueue')
  scope: emailQueue
  properties: {
    principalId: workflowIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'c6a89b2d-59bc-44d0-9896-0f6e12d7b80a')
  }
}

resource functionTableAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(processedTable.id, functionIdentity.id, 'processed-hashes')
  scope: processedTable
  properties: {
    principalId: functionIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  }
}

resource operatorQueueAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queueService.id, sqlAdminObjectId, 'inspect-and-retry-queues')
  scope: queueService
  properties: {
    principalId: sqlAdminObjectId
    principalType: sqlAdminPrincipalType == 'Application' ? 'ServicePrincipal' : 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  }
}

resource operatorTableAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(processedTable.id, sqlAdminObjectId, 'inspect-hashes')
  scope: processedTable
  properties: {
    principalId: sqlAdminObjectId
    principalType: sqlAdminPrincipalType == 'Application' ? 'ServicePrincipal' : 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '76199698-9eea-4c19-bc75-cec21354c6b6')
  }
}

// Covers host storage and reading/writing the deployment package.
resource storageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionIdentity.id, 'host-storage')
  scope: storage
  properties: {
    principalId: functionIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: json('0.1') }
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-insights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
  }
}

resource telemetryAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, functionIdentity.id, 'telemetry')
  scope: insights
  properties: {
    principalId: functionIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: '${namePrefix}-${suffix}-sql'
  location: location
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: sqlAdminPrincipalType
      login: sqlAdminLogin
      sid: sqlAdminObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sqlServer
  name: 'attachments'
  location: location
  sku: { name: 'S0', tier: 'Standard', capacity: 10 }
  properties: {
    collation: 'Latin1_General_100_CI_AS_SC'
    maxSizeBytes: 268435456000
    requestedBackupStorageRedundancy: 'Local'
  }
}

// Demo networking: allow Azure services, with Entra-only database authentication.
resource azureSqlAccess 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${namePrefix}-plan'
  location: location
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
  name: functionName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${functionIdentity.id}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: functionIdentity.id
          }
        }
      }
      runtime: { name: 'python', version: '3.12' }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: functionIdentity.properties.clientId }
        { name: 'AZURE_CLIENT_ID', value: functionIdentity.properties.clientId }
        { name: 'SQL_SERVER', value: sqlServer.properties.fullyQualifiedDomainName }
        { name: 'SQL_DATABASE', value: database.name }
        { name: 'MAILBOX', value: mailboxAddress }
        { name: 'IMPORT_QUEUE', value: emailQueue.name }
        { name: 'TABLE_ENDPOINT', value: storage.properties.primaryEndpoints.table }
        { name: 'PROCESSED_TABLE', value: processedTable.name }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'ClientId=${functionIdentity.properties.clientId};Authorization=AAD' }
      ]
    }
  }
  dependsOn: [storageAccess, telemetryAccess, functionQueueAccess, functionTableAccess]
}

// Disable HTTP authentication left by earlier deployments. There are no HTTP functions.
resource functionAuth 'Microsoft.Web/sites/config@2022-09-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: false }
  }
}

resource outlook 'Microsoft.Web/connections@2016-06-01' = {
  name: '${namePrefix}-outlook'
  location: location
  properties: {
    displayName: '${namePrefix} mailbox'
    api: { id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365') }
  }
}

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${namePrefix}-mail'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${workflowIdentity.id}': {} }
  }
  properties: {
    state: workflowEnabled ? 'Enabled' : 'Disabled'
    definition: loadJsonContent('workflow.json')
    parameters: {
      '$connections': {
        value: {
          office365: {
            id: outlook.properties.api.id
            connectionId: outlook.id
            connectionName: outlook.name
          }
        }
      }
      queueUrl: { value: '${storage.properties.primaryEndpoints.queue}${emailQueue.name}/messages?messagettl=-1' }
      workflowIdentity: { value: workflowIdentity.id }
      subjectFilter: { value: subjectFilter }
      mailFolder: { value: mailFolder }
    }
  }
  dependsOn: [workflowQueueAccess]
}

output functionAppName string = functionApp.name
output functionPrincipalId string = functionIdentity.properties.principalId
output functionClientId string = functionIdentity.properties.clientId
output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = database.name
output workflowName string = workflow.name
output workflowId string = workflow.id
output outlookConnectionId string = outlook.id
output storageAccountName string = storage.name
output queueEndpoint string = storage.properties.primaryEndpoints.queue
output importQueueName string = emailQueue.name
output poisonQueueName string = poisonQueue.name
output tableEndpoint string = storage.properties.primaryEndpoints.table
output processedTableName string = processedTable.name
