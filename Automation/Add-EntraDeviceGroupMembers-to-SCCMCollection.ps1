# This Sample Code is provided for the purpose of illustration only and is not intended to be used 
# in a production environment. THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" 
# WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED 
# WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE. We grant You a nonexclusive, 
# royalty-free right to use and modify the Sample Code and to reproduce and distribute the object code 
# form of the Sample Code, provided that You agree: (i) to not use Our name, logo, or trademarks to 
# market Your software product in which the Sample Code is embedded; (ii) to include a valid copyright 
# notice on Your software product in which the Sample Code is embedded; and (iii) to indemnify, hold 
# harmless, and defend Us and Our suppliers from and against any claims or lawsuits, including attorneys'
# fees, that arise or result from the use or distribution of the Sample Code.
# This sample script is not supported under any Microsoft standard support program or service. 
# The sample script is provided AS IS without warranty of any kind. Microsoft further disclaims 
# all implied warranties including, without limitation, any implied warranties of merchantability 
# or of fitness for a particular purpose. The entire risk arising out of the use or performance of 
# the sample scripts and documentation remains with you. In no event shall Microsoft, its authors, 
# or anyone else involved in the creation, production, or delivery of the scripts be liable for any 
# damages whatsoever (including, without limitation, damages for loss of business profits, business 
# interruption, loss of business information, or other pecuniary loss) arising out of the use of or 
# inability to use the sample scripts or documentation, even if Microsoft has been advised of the 
# possibility of such damages

## This script accepts an EntraID Device Group name and:
## 1. Queries the specified EntraID Device Group for the list of device membership
## 2. Queries the specified SCCM Device Collection for the list of device membership
## 3. A list of devices is created where there is membership in the EntraID Device Group but no membership in the SCCM Device Collection. This list is used to define membership additions for the script.
## 4. A list of devices is created where there is membership in the SCCM Device Collection but no membership in the Entra Device Collection. This list is used to define membership removals for the script.
## 5. A sum of the additions and removals to the SCCM Device Collection is calculated for the total number of changes for this run of the script
## 6. If any changes exist for this run:
##    - Additions to the SCCM Device Collection are processed by adding a Custom Property to each device with the Name of the EntraID Device Group and the value of True
##    - Removals from the SCCM Device Collection are processed by removing the Custom Property from the Device
##    - A full collection evaluation is triggered for the SCCM Device Collection
## 7. If no changes exist for this run, the script exits
## 8. All of these processes are logged to the log file specified



<#!
.SYNOPSIS
Syncs EntraID Device Group membership to an SCCM Device Collection via a custom property.

.DESCRIPTION
Queries Entra for device group members, compares them with SCCM collection members, and adds/removes
a custom property on SCCM devices to reflect Entra group membership. The SCCM collection can then use
that property for dynamic membership. Logs all actions to the specified log file.

.PARAMETER EntraDeviceGroupName
The name of the EntraID Device Group to query.

.PARAMETER SCCMCollectionName
The name of the SCCM device collection to hydrate.

.PARAMETER EntraTenantID
The Entra tenant ID or tenant FQDN.

.PARAMETER EntraAppID
The Entra application (client) ID with permissions to read groups and members.

.PARAMETER EntraClientSecret
The client secret for the EntraID application.

.PARAMETER SiteServerFQDN
The FQDN of the SCCM provider site server hosting the AdminService endpoint.

.PARAMETER SiteCode
The SCCM site code used to connect to the SCCM PSDrive.

.PARAMETER LogFilePath
Full path to the log file to create or append to.

.EXAMPLE
PS> .\Add-EntraDeviceGroupMembers-to-SCCMCollection.ps1 -EntraDeviceGroupName "MyEntraGroup" -SCCMCollectionName "MySCCMCollection" -LogFilePath "C:\Logs\EntraSCCM.log" -EntraTenantID "contoso.onmicrosoft.com" -EntraAppID "00000000-0000-0000-0000-000000000000" -EntraClientSecret "<secret>" -SiteServerFQDN "cm01.contoso.local" -SiteCode "P01"

.NOTES
Requires administrative rights to run.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "The EntraID Device Group name that you want to query for membership and add as a custom property in SCCM")]
    [string]$EntraDeviceGroupName,
    [Parameter(Mandatory = $true, HelpMessage = "The SCCM collection name to use when updating membership")]
    [string]$SCCMCollectionName,
    [Parameter(Mandatory = $true, HelpMessage = "Your Entra Tenant ID (tenant name or GUID)")]
    [string]$EntraTenantID,
    [Parameter(Mandatory = $true, HelpMessage = "Your Entra App ID that has permissions to read device groups and their members")]
    [string]$EntraAppID,
    [Parameter(Mandatory = $true, HelpMessage = "Your Entra App Client Secret")]
    [string]$EntraClientSecret,
    [Parameter(Mandatory = $true, HelpMessage = "The fully qualified domain name of your SCCM Provider")]
    [string]$SiteServerFQDN,
    [Parameter(Mandatory = $true, HelpMessage = "Your SCCM Site Code")]
    [string]$SiteCode,
    [Parameter(Mandatory = $true, HelpMessage = "The full path to the log file to create or append to")]
    [string]$LogFilePath
)

$CurrentPath = (Get-Location).Path

$LogDirectory = Split-Path -Path $LogFilePath -Parent
if ($LogDirectory -and -not (Test-Path -Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Log started." | Add-Content -Path $LogFilePath -Encoding ASCII

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO",
        [ConsoleColor]$Color = "White"
    )

    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $Line -ForegroundColor $Color
    Add-Content -Path $LogFilePath -Value $Line -Encoding ASCII
}

$BaseURL = "https://$SiteServerFQDN/AdminService"
$BaseURLwmi = $BaseURL + "/wmi/"
$BaseURLv1 = $BaseURL + "/v1/"

# =========== Remove Certificate Validation Callback Requirement in Powershell (For Self-Signed Cert Scenarios) ===========
if (-not("dummy" -as [type])) {
    add-type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class Dummy {
    public static bool ReturnTrue(object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors) { return true; }

    public static RemoteCertificateValidationCallback GetDelegate() {
        return new RemoteCertificateValidationCallback(Dummy.ReturnTrue);
    }
}
"@
}
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = [dummy]::GetDelegate()
# ==========================================================================================================================

# =========== Function to Connect to SCCM Powershell CMDLets ===========
function Connect-SCCM {
    param (
        [string]$SiteCode
    )

    $SCCMModulePath = "$env:SMS_ADMIN_UI_PATH\..\ConfigurationManager.psd1"
    if (-not (Get-Module -Name ConfigurationManager)) {
        Import-Module -Name $SCCMModulePath -Force -ErrorAction Stop
    }
    $SiteCodeDrive = "$($SiteCode):"
    Set-Location -Path $SiteCodeDrive
}

# =========== Function to Get EntraID Device Group Members and their Properties ===========
function Get-EntraDeviceGroupMembers {  
    param (
        [string]$GroupName,
        [string]$TenantID,
        [string]$AppID,
        [string]$ClientSecret
    )

    # Connect to Microsoft Graph with the provided credentials
    $Scopes = "https://graph.microsoft.com/.default"
    $TokenRequestBody = @{
        Grant_Type    = "client_credentials"
        Scope         = $Scopes
        Client_Id     = $AppID
        Client_Secret = $ClientSecret
    }
    $TokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantID/oauth2/v2.0/token" -ContentType "application/x-www-form-urlencoded" -Body $TokenRequestBody -ErrorAction Stop -Verbose:$false
    $AccessToken = $TokenResponse.access_token

    # Get the GroupID for the specified Group Name
    $GroupResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$GroupName'" -Headers @{ Authorization = "Bearer $AccessToken" } -ErrorAction Stop -Verbose:$false
    if ($GroupResponse.value.Count -eq 0) {
        Write-Error "No group found with the name '$GroupName'"
        return
    }
    elseif ($GroupResponse.value.Count -gt 1) {
        Write-Error "Multiple groups found with the name '$GroupName'. Please specify a unique group name."
        return
    }
    $GroupID = $GroupResponse.value[0].id

    # Get the membership of the EntraID Device Group
    $MembersResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups/$GroupID/members" -Headers @{ Authorization = "Bearer $AccessToken" } -ErrorAction Stop -Verbose:$false
    
    return $MembersResponse.value
}

# =========== Function to Get SCCM Collection Members using Powershell CMDLets ===========
function Get-SCCMCollectionMembers {
    param (
        [string]$CollectionName
    )

    $Collection = (Get-CMDeviceCollection -Name "$CollectionName" -ErrorAction Stop)  
    if ($null -eq $Collection) {
        Write-Error "No collection found with the name '$CollectionName'"
        return
    }

    $Members = Get-CMCollectionMember -CollectionName "$CollectionName" -ErrorAction Stop
    return $Members
}

# =========== Function to Add Custom Property to SCCM Devices using the SCCM AdminService API ===========
function Add-CustomPropertyToSCCMDevice {
    param (
        [string]$DeviceName,
        [string]$CustomPropertyName,
        [string]$CustomPropertyValue
    )

    $Properties = @{
        "ExtensionData" = @{ 
            $CustomPropertyName = $CustomPropertyValue
        }
    } | ConvertTo-Json
    # Get the device ResourceID based on the device name
    $DeviceResourceID = (Get-CMDevice -Name $DeviceName -ErrorAction SilentlyContinue).ResourceID
    # Call the SCCM AdminService API to add a Custom Property to the specified device with the specified value
    If ($DeviceResourceID) {
        Write-Log "Adding [$CustomPropertyName] property to $DeviceName ..." -Level INFO -Color Yellow
        Invoke-RestMethod -Method Post -Uri ($BaseURLv1 + "/Device($DeviceResourceID)/AdminService.SetExtensionData") -Body $Properties -ContentType "Application/Json" -UseDefaultCredentials | Out-Null
    }
}

# =========== Function to Remove Custom Property from SCCM Devices using the SCCM AdminService API ===========
function Remove-CustomPropertyFromSCCMDevice {
    param (
        [string]$DeviceName,
        [string]$CustomPropertyName
    )

    $Properties = @{"PropertyNames" = @($CustomPropertyName)} | ConvertTo-Json

    # Get the device ResourceID based on the device name
    $DeviceResourceID = (Get-CMDevice -Name $DeviceName -ErrorAction SilentlyContinue).ResourceID
    # Add code here to call the SCCM AdminService API to remove a Custom Property from the specified device
    If ($DeviceResourceID) {
        Write-Log "Removing [$CustomPropertyName] property from $DeviceName ..." -Level INFO -Color Yellow
        Invoke-RestMethod -Method Post -Uri ($BaseURLv1 + "/Device($DeviceResourceID)/AdminService.DeleteCustomProperties") -Body $Properties -ContentType "Application/Json" -UseDefaultCredentials | Out-Null
    }
}

# =========== Function to Count Changes to be made by adding the $DevicesToAddToSCCMCollection and $DevicesToRemoveFromSCCMCollection to determine whether a collection update is necessary ===========
function Count-CollectionChanges {
    param (
        [array]$DevicesToAdd,
        [array]$DevicesToRemove
    )

    $AddCount = $DevicesToAdd.Count
    $RemoveCount = $DevicesToRemove.Count

    return ($DevicesToAdd.Count + $DevicesToRemove.Count)
}

# =========== Execute Script Logic ===========
# Connect to SCCM Site Drive
Connect-SCCM -SiteCode $SiteCode

$EntraDeviceGroupMembers = (Get-EntraDeviceGroupMembers -GroupName $EntraDeviceGroupName -TenantID $EntraTenantID -AppID $EntraAppID -ClientSecret $EntraClientSecret)
$EntraDeviceGroupMemberNames = ($EntraDeviceGroupMembers | Select-Object -ExpandProperty displayName).ToUpperInvariant()
$SCCMCollectionMembers = (Get-SCCMCollectionMembers -CollectionName $SCCMCollectionName)
$SCCMCollectionMemberNames = ($SCCMCollectionMembers | Select-Object -ExpandProperty Name).ToUpperInvariant()

# List devices that are in the EntraID Device Group but not in the SCCM Collection
# This list is used to define membership additions for the script
$DevicesToAddToSCCMCollection = $EntraDeviceGroupMembers | Where-Object { $_.displayName.ToUpperInvariant() -notin $SCCMCollectionMemberNames }

Write-Log "-------------------------------------------------------------------------------------------------------------" -Level INFO -Color Yellow
Write-Log "Devices that are in the EntraID Device Group [$EntraDeviceGroupName] but not in the SCCM Collection [$SCCMCollectionName]:" -Level INFO -Color Yellow
Write-Log "-------------------------------------------------------------------------------------------------------------" -Level INFO -Color Yellow
ForEach ($Device in $DevicesToAddToSCCMCollection) {
    Write-Log "- $($Device.displayName)" -Level INFO -Color Cyan
}
If($DevicesToAddToSCCMCollection.Count -eq 0) {
    Write-Log "None" -Level INFO -Color Cyan
}

# List devices that are in the SCCM Collection but not in the EntraID Device Group
# This list is used to define membership removals for the script
$DevicesToRemoveFromSCCMCollection = $SCCMCollectionMembers | Where-Object { $_.Name.ToUpperInvariant() -notin $EntraDeviceGroupMemberNames }

Write-Log "-------------------------------------------------------------------------------------------------------------" -Level INFO -Color Yellow
Write-Log "Devices that are in the SCCM Collection [$SCCMCollectionName] but not in the EntraID Device Group [$EntraDeviceGroupName]:" -Level INFO -Color Yellow
Write-Log "-------------------------------------------------------------------------------------------------------------" -Level INFO -Color Yellow
ForEach ($Device in $DevicesToRemoveFromSCCMCollection) {
    Write-Log "- $($Device.Name)" -Level INFO -Color Cyan
}
If($DevicesToRemoveFromSCCMCollection.Count -eq 0) {
    Write-Log "None" -Level INFO -Color Cyan
}

Write-Log "-------------------------------------------------------------------------------------------------------------" -Level INFO -Color Green
Write-Log "There are $($DevicesToAddToSCCMCollection.Count) devices to be added to the SCCM Collection [$SCCMCollectionName]." -Level INFO -Color Green
Write-Log "There are $($DevicesToRemoveFromSCCMCollection.Count) devices to be removed from the SCCM Collection [$SCCMCollectionName]." -Level INFO -Color Green
Write-Log "-------------------------------------------------------------------------------------------------------------" -Level INFO -Color Green

$TotalChanges = Count-CollectionChanges -DevicesToAdd $DevicesToAddToSCCMCollection -DevicesToRemove $DevicesToRemoveFromSCCMCollection
If ($TotalChanges -eq 0) {
    Write-Log "No changes detected. Skipping SCCM Collection update." -Level INFO -Color Green
} else {
    Write-Log "Changes detected. Proceeding with SCCM Collection update." -Level INFO -Color Green

    # Add Custom Property to devices that are in the EntraID Device Group but not in the SCCM Collection
    ForEach($Device in $DevicesToAddToSCCMCollection) {
        $DeviceExists = (Get-CMDevice -Name $Device.displayName -ErrorAction SilentlyContinue)
        If($DeviceExists) {
            Write-Log "Device [$($Device.displayName)] found in SCCM" -Level INFO -Color Yellow
            Write-Log "Adding Custom Property [$EntraDeviceGroupName] to device [$($Device.displayName)] ..." -Level INFO -Color Gray
            Add-CustomPropertyToSCCMDevice -DeviceName $Device.displayName -CustomPropertyName $EntraDeviceGroupName -CustomPropertyValue "True"
        }   
    }

    # Remove Custom Property from devices that are in the SCCM Collection but not in the EntraID Device Group
    ForEach($Device in $DevicesToRemoveFromSCCMCollection) {
        $DeviceExists = (Get-CMDevice -Name $Device.Name -ErrorAction SilentlyContinue)
        If($DeviceExists) {
            Write-Log "Device [$($Device.Name)] found in SCCM" -Level INFO -Color Yellow
            Write-Log "Removing Custom Property [$EntraDeviceGroupName] from device [$($Device.Name)] ..." -Level INFO -Color Gray
            Remove-CustomPropertyFromSCCMDevice -DeviceName $Device.Name -CustomPropertyName $EntraDeviceGroupName
        }   
    }

    # Wait for a moment
    Write-Log "Please wait ..." -Level INFO -Color Green
    Start-Sleep -Seconds 10

    # Update Collection Membership
    Write-Log "Initiating a Full Update of the SCCM Collection [$SCCMCollectionName] ..." -Level INFO -Color Green
    Invoke-CMCollectionUpdate -Name "$SCCMCollectionName"
}

# Completion
Set-Location -Path $CurrentPath
Write-Log "Script execution completed." -Level INFO -Color Magenta
