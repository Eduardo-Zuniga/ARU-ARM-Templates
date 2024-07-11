<#
.SYNOPSIS
Takes an existing keyvault and re-creates it in a different resource group.

.DESCRIPTION
This script utilizes REST API calls and an existing storage account to re-create a key vault in a new resource group,
the current configuration is obtained with a REST call which is then added to a pre-existing 'base' template stored
in a blob container. All properties and templates are also saved on the storage account used.

.PARAMETER subID
Specifies the subscription ID where the resources and resource groups exist.

.PARAMETER OriginRG
Specifies the resource group where the key vault to re-create currently exists.

.PARAMETER OriginKeyvaultName
Specifies the name of the keyvault to re-create.

.PARAMETER KVrestAPIVersion
Optionally specifies the API version to use when making the REST call to the Key Vault if not default used is "2022-07-01".

.PARAMETER TargetRG
Specifies the resource group where the key vault should be re-created.

.PARAMETER NameIFTooLong
Specifies which name should be used in case the current Key vault name is over 20 characters, this because the naming convention of the new re-created keyvault will be the next: 
'<Name-of-Keyvault>-mvd'. 

.PARAMETER KVApiVersion
Optionally specifies the API version to use when creating the key vault if not default used is "2019-09-01".

.PARAMETER storageAccountName
Specifies the name of the storage account where the blob that contains the "base" template exists.

.PARAMETER storageAccountSASKey
Specifies the storage account SAS key to connect and operate the templates.

.PARAMETER baseTemplateContainerName
Specifies the blob container's name where the base template is located. This same container may be used to store all created templates too, for this reference parameter OperationsContainerName.

.PARAMETER OperationsContainerName
Optionally specify a separate container to store the original key vault properties and the templates used to re-create the key vault. Default if not set will be 
the same value as parameter 'baseTemplateContainerName'

.PARAMETER baseTemplateName
Specify the name of the base template located in the storage account's container set with parameters storageAccountName / baseTemplateContainerName.
Note this should be a .json file and the extension should be added.


#>


[Cmdletbinding()]
param
(
    [Parameter(Mandatory=$true)]
        [string] $subID,

    [Parameter(Mandatory=$true)]
        [string] $OriginRG,

    [Parameter(Mandatory=$true)]
        [string] $OriginKeyvaultName,

    [Parameter(Mandatory=$false)]
        [string] $KVrestAPIVersion = "2022-07-01",

    [Parameter(Mandatory=$true)]
        [string] $TargetRG,

    [Parameter(Mandatory=$false)]
        [string] $NameIFTooLong,

    [Parameter(Mandatory=$false)]
        [string] $KVApiVersion = "2019-09-01",

    [Parameter(Mandatory=$true)]
        [string] $storageAccountName,

    [Parameter(Mandatory=$true)]
        [string] $storageAccountSASKey,

    [Parameter(Mandatory=$true)]
        [string] $baseTemplateContainerName,

    [Parameter(Mandatory=$false)]
        [string] $OperationsContainerName = $baseTemplateContainerName,

    [Parameter(Mandatory=$true)]
        [string] $baseTemplateName

)







#Getting context and profile to request a token for ARM
$Gtoken = get-azaccessToken -Resourcetypename Arm

#Headers for the API request to keyvault
$authHeader = @{
    'Content-Type'='application/json'
    'Authorization'='Bearer ' + $Gtoken.Token
}

#Setting URI and making the call saving the response in a variable
$restUri = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.KeyVault/vaults/{2}?api-version={3}" -f $subID, $OriginRG, $OriginKeyvaultName, $KVrestAPIVersion
$content = Invoke-RestMethod -Uri $restUri -Method Get -Headers $authHeader

#Original properties are saved to be uploaded to a blob, also the next
#Saving accesspolicies to prevent type mismatch after multiple conversions to and from Json
$OriginalProperties = $content

#updating tags for the json file
#Creation date
$content.update | Foreach-object {
    $item = $content.tags.createdOn
    $date = (Get-Date -Format "| yyyy-MM-dd |").ToString()
    if ($item.ToString() -ine $date) {
        $content.tags.createdon = $date
    }
}

#Kusto time
$content.update | Foreach-object {
    $item = $content.tags.kustoTime
    $date = (Get-Date -Format "| HH:mm:ss |").ToString()
    if ($item.ToString() -ine $date) {
        $content.tags.kustoTime = $date
    }
}

$vault = $content.name
#resource group
$content.update | Foreach-object {
    $item = $content.tags.ResourceGroupName
    if ($item.ToString() -ine $TargetRG) {
        $content.tags.ResourceGroupName = $TargetRG
    }
}

$content.update | Foreach-object {
    $item = $content.name
    if ($content.name.length -lt 19){
        $content.name = $item+"-mvd"
    }
    else {
        $content.name = $NameIFTooLong 
    }
    
}

$newName = $content.name

#remove ID property from json
$content.psobject.properties.remove("id")
$content.psobject.properties.remove("systemData") 
$propRM = @("vaultUri","provisioningState")
foreach($str in $propRM){$content.properties.psobject.properties.remove($str)}



#Add ApiVersion property and SKU values
$content | add-member -MemberType NoteProperty -Name "apiVersion" -Value $KVApiVersion -Force 
$content.properties.sku | add-member -MemberType NoteProperty -Name "family" -value "A" -force
$content.properties.sku | add-member -MemberType NoteProperty -Name "name" -value "standard" -force

#Setting storage context and getting base template from blob
$Context = New-AzureStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountSASKey
$template =  Get-AzStorageBlobContent -Container $baseTemplateContainerName -Blob $baseTemplateName -Context $context -Force

#This variable contains the base template and is converted to psobject to edit
$newTemplate = get-content $template.name
$newTemplate = $newTemplate | convertFrom-Json

#Converting the vault declaration to a hash table
$ht2 = @{}
$content.psobject.properties | ForEach-Object {
    $ht2[$_.Name] = $_.Value
}

#Adding the vault to the template resources
$newtemplate.resources.vaultARU | add-member -NotePropertyMembers $ht2

#Adding the accesspolicies back to the template to ensure no curruption of data type has happened to the array
$newtemplate.resources.vaultARU.properties.accesspolicies = $OriginalProperties.properties.accessPolicies

#Converting template back to Json format
$deploy = $newTemplate | convertTo-Json -depth 100

# "URL" contains the final template used for deployment
# "URL2" contains the 

$url = "newAzureDeploy.json"
set-content -path $url -value $deploy             
set-content -path $url2 -value $originalproperties.properties.accessPolicies              
Set-AzureStorageBlobContent -Context $Context -Container $OperationsContainerName -File $url -Force

#getting the value of the template itself on a variable and downloading to current context
$end =  Get-AzStorageBlobContent -Container $OperationsContainerName -Blob "newAzureDeploy.json" -Context $context -Force

#Permanently deleting previous KeyVault
Remove-AzKeyVault -Name $vault.ToString() -ResourceGroupName $OriginRG -Force
Remove-AzKeyVault -Name $vault.ToString() -ResourceGroupName $OriginRG -Force

#Deploy on the new resource group
New-AzResourceGroupDeployment -Resourcegroupname v-eduardoz -templatefile $end.name -Force

#Outputs
$output = "The Key vault '{0}' in resource group '{1}' was moved and can now be found under name '{2}' in resource group '{3}'. Make sure to check the original vault was Purged completely." -f $OriginKeyvaultName, $OriginRG, $newName.ToString(), $TargetRG
Write-Output $output
$DeploymentScriptOutputs = @{}
$DeploymentScriptOutputs['text'] = $output

