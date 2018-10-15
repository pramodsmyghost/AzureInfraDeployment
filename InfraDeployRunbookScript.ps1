<#
    .SYNOPSIS
        This script will Deploy the complete Infrastructure in one go.
    
    .DESCRIPTION
        This script is used in MI-POC Subscription to deploy various resources like Resource Groups, VNETs, Storage Accounts, Virtual Machines at once using a parameter csv file. If the resource already exists, it will skip and proceed with the rest of the deployment.
     
    .NOTES
        File          :    InfraDeployment.ps1
        Author        :    P V Pramod Reddy
        Company       :    LTI
        Email         :    pramodreddy.p.v@lntinfotech.com
        Created       :    18-09-2018
        Last Updated  :    03-10-2018
        Version       :    1.0

    .INPUTS
        Parameter CSV file (Infra-Parameters.csv)
        JSON Template File (*.json)
        The inputs files are modified and uploaded to the location "https://use2host02mivmstrg001.blob.core.windows.net/infradeployment-inputs"
#>

Param(

    [Parameter(Mandatory= $true)]  
    [PSCredential]$AzureOrgIdCredential,

    [Parameter(Mandatory= $true)]
    [string]$ParameterFileName = "Infra-Parameters.csv",

    [Parameter(Mandatory= $true)]
    [string]$SubcriptionID = "bb3d0ed0-bf9b-442d-83d5-3b059843dd52",

    [Parameter(Mandatory= $true)]
    [string]$adminPassword,

    [Parameter(Mandatory= $true)]
    [string]$RootPassword
)

Get-ChildItem -Path C:\Temp -Include Infra-Parameters.csv | foreach { $_.Delete()}
Get-ChildItem -Path C:\Temp -Include *.json | foreach { $_.Delete()}

$Null = Login-AzureRMAccount -Credential $AzureOrgIdCredential  
$Null = Get-AzureRmSubscription -SubscriptionID $SubcriptionID | Select-AzureRMSubscription

$ContextStorageName = "use2host02mivmstrg001"
$ContextStorageRG = (Get-AzureRmStorageAccount | where {$_.StorageAccountName -eq "$ContextStorageName"}).ResourceGroupName
$ContextStorageKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $ContextStorageRG -Name $ContextStorageName).Value[0]
$Context = New-AzureStorageContext -StorageAccountName $ContextStorageName -StorageAccountKey $ContextStorageKey
$Null = Get-AzureStorageBlobContent -Context $Context -Blob $ParameterFileName -Container "infradeployment-inputs" -Destination 'C:\Temp\' -Force

$CSVPath = Join-Path -Path 'C:\Temp\' -ChildPath $ParameterFileName

$ErrorActionPreference = "Stop"

$VMDetails = Import-Csv "$CSVPath"
    
foreach($Template in $VMDetails)
{
    $Null = Get-AzureStorageBlobContent -Context $Context -Blob $Template.Templatename -Container "infradeployment-inputs" -Destination 'C:\Temp\' -Force
    $JSONPath = Join-Path -Path 'C:\Temp\' -ChildPath $Template.Templatename
    if(!(Test-Path $JSONPath ))
    {
        throw "$($Template.Templatename) does not exist in C:\Temp\"
    }
}
        
foreach($Line in $VMDetails)
{
    $RGName=$Line.virtualMachineResourceGroup

    # Resource Group Check
    if((Get-AzureRmResourceGroup | Where ResourceGroupName -eq $RGName) -eq $null)
    {
        New-AzureRmResourceGroup -Name $RGName -Location $Line.location
    }
    if((Get-AzureRmResourceGroup | Where ResourceGroupName -eq $Line.diagnosticsStorageResourceGroup) -eq $null)
    {
        New-AzureRmResourceGroup -Name $Line.diagnosticsStorageResourceGroup -Location $Line.location
    }
    if((Get-AzureRmResourceGroup | Where ResourceGroupName -eq $Line.vNetResourceGroup) -eq $null)
    {
        New-AzureRmResourceGroup -Name $Line.vNetResourceGroup -Location $Line.location
    }
        
    # Diagnostic Storage Account Check
    $diagsaname = $Line.diagnosticsStorageAccountName
    if((Get-AzureRmStorageAccount | where StorageAccountName -EQ $diagsaname) -eq $null) 
    {
        New-AzureRmStorageAccount -Name $diagsaname -ResourceGroupName $Line.diagnosticsStorageResourceGroup -Location $Line.location -SkuName Standard_LRS -Kind StorageV2
    }      
         
    # Virtual Network and Subnet Check       
    $VNETName = $Line.virtualNetworkName
    $VNETCIDR = $Line.vnetCIDR
    $SubnetName = $Line.subnetName
    $SubnetCIDR = $Line.subnetCIDR

    if((Get-AzureRmVirtualNetwork | where Name -EQ $VNETName) -eq $null) 
    {
        $subnetConfig = New-AzureRmVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetCIDR
        $VirtualNetwork = New-AzureRmVirtualNetwork -Name $VNETName -ResourceGroupName $Line.vNetResourceGroup -Location $Line.location -AddressPrefix $VNETCIDR -Subnet $subnetConfig
        $VirtualNetwork | Set-AzureRmVirtualNetwork
    }
    elseif((Get-AzureRmVirtualNetwork -Name $VNETName -ResourceGroupName $Line.vNetResourceGroup | Get-AzureRmVirtualNetworkSubnetConfig | where Name -EQ $SubnetName) -eq $null)
    {
        $virtualNetwork = Get-AzureRmVirtualNetwork -Name $VNETName -ResourceGroupName $Line.vNetResourceGroup
        Add-AzureRmVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetCIDR -VirtualNetwork $virtualNetwork
        $VirtualNetwork | Set-AzureRmVirtualNetwork
    }

}

$ErrorActionPreference = "Continue"
    
foreach($VmDetail in $VmDetails)
{
    $Tier = ($VMDetail.tier).ToUpper()
    $JSONPath = Join-Path -Path 'C:\Temp\' -ChildPath $VmDetail.Templatename
    Write-Output "$($VMDetail.virtualMachineName) in tier $Tier is being deployed"
    if($($VmDetail.isdatadisk) -eq "no")
    {
        $TestArray = [pscustomobject]@{
            Name = "TestDataDisk"
            sizeinGB = "5"
            DDSnapshotID = "USE2EDCWDLB9002-DATA-HDD-001-Snapshot"
            StorageType = "Standard_LRS"
        }
        $JSONArray = $TestArray | ConvertTo-Json
        $t1 = "[" +$JSONArray+"]"
        $datadisk = [Newtonsoft.Json.JsonConvert]::DeserializeObject($t1.ToString()) 
    }
    else
    {
        $datadisk = [Newtonsoft.Json.JsonConvert]::DeserializeObject($($VmDetail.datadisk).ToString())
    }

    if($($VmDetail.isavset) -eq "no" )
    {
        $availabilitySetName = "tempaset"
        $availabilitySetPlatformFaultDomainCount = "2"
        $availabilitySetPlatformUpdateDomainCount= "5"
    }
    else
    { 
        $availabilitySetName = $($VmDetail.availabilitySetName)
        $availabilitySetPlatformFaultDomainCount = $($VmDetail.availabilitySetPlatformFaultDomainCount)
        $availabilitySetPlatformUpdateDomainCount= $($VmDetail.availabilitySetPlatformUpdateDomainCount)
    }

    $ParamObj = @{
                    "adminPassword" = $adminPassword
                    "adminUsername" = $($VmDetail.adminUsername)
                    "availabilitySetName" = $availabilitySetName
                    "availabilitySetPlatformFaultDomainCount" = $availabilitySetPlatformFaultDomainCount
                    "availabilitySetPlatformUpdateDomainCount" = $availabilitySetPlatformUpdateDomainCount
                    "datadisk" = $datadisk 
                    "diagnosticsStorageAccountName" = $($VmDetail.diagnosticsStorageAccountName)
                    "diagnosticsStorageResourceGroup" = $($VmDetail.diagnosticsStorageResourceGroup)
                    "isavset" = $($VmDetail.isavset)
                    "isdatadisk" = $($VmDetail.isdatadisk)
                    "location" = $($VmDetail.location)
                    "OsdiskType" = $($VmDetail.OsdiskType)
                    "OSdiskSizeGB" = $($VmDetail.OSdiskSizeGB)
                    "ImageName" = $($VmDetail.ImageName)
                    "OMSWorkspaceName" = $($VmDetail.OMSWorkspaceName)
                    "OMSResourceGroupName" = $($VmDetail.OMSResourceGroupName)                        
                    "PrivateipAddress" = $($VmDetail.PrivateipAddress)
                    "RootPassword" = $RootPassword
                    "subnetName" = $($VmDetail.subnetName)
                    "virtualMachineName" = $($VmDetail.virtualMachineName)
                    "virtualMachineSize" = $($VmDetail.virtualMachineSize)
                    "virtualNetworkName" = $($VmDetail.virtualNetworkName)
                    "vNetResourceGroup" = $($VmDetail.vNetResourceGroup)
                 }

    New-AzureRmResourceGroupDeployment -Name $($VmDetail.virtualMachineName) -ResourceGroupName $($VmDetail.virtualMachineResourceGroup) -Mode Incremental -TemplateFile $JSONPath -TemplateParameterObject $ParamObj
    Test-AzureRmResourceGroupDeployment  -ResourceGroupName $($VmDetail.virtualMachineResourceGroup) -Mode Incremental -TemplateFile $JSONPath -TemplateParameterObject $ParamObj
    Write-Output "$($VMDetail.virtualMachineName) in tier $Tier is created"
}