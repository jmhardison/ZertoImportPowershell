################################################
# Configure the variables below using the Production vCenter & ZVM
################################################
$LogDataDir = ".\"
$ProfileCSV = ".\vpg-master.csv"
$ZertoServer = "192.168.0.31"
$ZertoPort = "9669"
$ZertoUserObj = Get-Credential
$vCenterServer = "192.168.0.81"
$vCenterUserObj = Get-Credential
$VPGProfileNo = "1"
$VMsToProtectvCenterFolderName = "ZVRVMsToProtect"
$ProtectedVMvCenterFolderName = "ZVRProtectedVMs"
$NextVPGCreationDelay = "60"
####################################################################################################
# Nothing to configure below this line - Starting the main function of the script
####################################################################################################
################################################
# Setting log directory for engine and current month
################################################
$CurrentMonth = get-date -format MM.yy
$CurrentLogDataDir = $LogDataDir + $CurrentMonth
$CurrentTime = get-date -format hh.mm.ss
# Testing path exists to engine logging, if not creating it
$ExportDataDirTestPath = test-path $CurrentLogDataDir
$CurrentLogDataFile = $LogDataDir + $CurrentMonth + "\VPGCreationLog-" + $CurrentTime + ".txt"
if ($ExportDataDirTestPath -eq $False)
{
New-Item -ItemType Directory -Force -Path $CurrentLogDataDir
}
start-transcript -path $CurrentLogDataFile -NoClobber
################################################
# Connecting to vCenter - required for successful authentication with Zerto API
################################################
connect-viserver -Server $vCenterServer -User $vCenterUserObj.UserName -Password [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($vCenterUserObj.password))
################################################
# Building Zerto API string and invoking API
################################################
$baseURL = "https://" + $ZertoServer + ":"+$ZertoPort+"/v1/"
# Authenticating with Zerto APIs
$xZertoSessionURL = $baseURL + "session/add"
$authInfo = ("{0}:{1}" -f $ZertoUserObj.UserName, [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ZertoUserObj.password)))
$authInfo = [System.Text.Encoding]::UTF8.GetBytes($authInfo)
$authInfo = [System.Convert]::ToBase64String($authInfo)
$headers = @{Authorization=("Basic {0}" -f $authInfo)}
$sessionBody = '{"AuthenticationMethod": "1"}'
$TypeJSON = "application/JSON"
$TypeXML = "application/XML"
$xZertoSessionResponse = Invoke-WebRequest -Uri $xZertoSessionURL -Headers $headers -Method POST -Body $sessionBody -ContentType $TypeJSON
#Extracting x-zerto-session from the response, and adding it to the actual API
$xZertoSession = $xZertoSessionResponse.headers.get_item("x-zerto-session")
$zertosessionHeader = @{"x-zerto-session"=$xZertoSession; "Accept"=$TypeJSON }
# URL to create VPG settings
$CreateVPGURL = $BaseURL+"vpgSettings"
################################################
# Importing the CSV of Profiles to use for VM Protection
################################################
$ProfileCSVImport = Import-Csv $ProfileCSV
################################################
# Building an Array of all VMs to protect from the vSphere folder and setting the boot group ID
################################################
# Getting a list of all VMs
$VMsToProtect = get-vm * -Location $VMsToProtectvCenterFolderName | Select-Object Name -ExpandProperty Name
# Getting VM boot group info
$VMBootGroup1List = get-vm * -Location "ZVRBootGroup1" | Select-Object Name
$VMBootGroup2List = get-vm * -Location "ZVRBootGroup2" | Select-Object Name
# Setting VM boot group IDs
$VMBootGroup1ID = "00000000-0000-0000-0000-000000000001"
$VMBootGroup2ID = "00000000-0000-0000-0000-000000000002"
# Creating Tag array
$ZVRArray = @()
# Building Array of VMs with boot groups
foreach ($VM in $VMsToProtect)
{
$CurrentVM = $VM.Name
$VPGName = $CurrentVM -replace "-.*"
# Setting VM boot group info
$VMBootGroup1 = $VMBootGroup1List | where {$_.Name -eq "$CurrentVM"} | Select-Object Name -ExpandProperty Name
$VMBootGroup2 = $VMBootGroup2List | where {$_.Name -eq "$CurrentVM"} | Select-Object Name -ExpandProperty Name
# Using IF stattement to set correct boot group ID
if ($VMBootGroup1 -ccontains $CurrentVM)
{
$VMBootGroupID = $VMBootGroup1ID
}
if ($VMBootGroup2 -ccontains $CurrentVM)
{
$VMBootGroupID = $VMBootGroup2ID
}
# Creating Array and adding info for the current VM
$ZVRArrayLine = new-object PSObject
$ZVRArrayLine | Add-Member -MemberType NoteProperty -Name "VMName" -Value $CurrentVM
$ZVRArrayLine | Add-Member -MemberType NoteProperty -Name "VPGName" -Value $VPGName
$ZVRArrayLine | Add-Member -MemberType NoteProperty -Name "BootGroupID" -Value $VMBootGroupID
$ZVRArray += $ZVRArrayLine
# End of for each VM below
}
################################################
# Loading the VPG settings from the CSV, including the ZertoServiceProfile to use
################################################
$ProfileSettings = $ProfileCSVImport | where {$_.ProfileNo -eq "$VPGProfileNo"}
$ReplicationPriority = $ProfileSettings.ReplicationPriority
$RecoverySiteName = $ProfileSettings.RecoverySiteName
$ClusterName = $ProfileSettings.ClusterName
$FailoverNetwork = $ProfileSettings.FailoverNetwork
$TestNetwork = $ProfileSettings.TestNetwork
$DatastoreName = $ProfileSettings.DatastoreName
$JournalDatastore = $ProfileSettings.JournalDatastore
$vCenterFolder = $ProfileSettings.vCenterFolder
$BootGroupDelay = $ProfileSettings.BootGroupDelay
$JournalHistoryInHours = $ProfileSettings.JournalHistoryInHours
$RpoAlertInSeconds = $ProfileSettings.RpoAlertInSeconds
$TestIntervalInMinutes = $ProfileSettings.TestIntervalInMinutes
$JournalHardLimitInMB = $ProfileSettings.JournalHardLimitInMB
$JournalWarningThresholdInMB = $ProfileSettings.JournalWarningThresholdInMB
################################################
# Creating List of VMs to Protect and profile settings from the Array then selecting unique VPG names
################################################
$VPGsToCreate = $ZVRArray | select VPGName -Unique
# Writing output of VMs to protect
if ($VMsToProtect -eq $null)
{
write-host "No VMs found to protect in vCenter folder:$VMsToProtectvCenterFolderName"
}
else
{
# Writing output of VMs to protect
write-host "Found the below VMs in the vCenter folder to protect:
$VMsToProtect"
}
################################################
# Running the creation process by VPGs to create from the $VPGsToCreate variable, as a VPG can contain multiple VMs
################################################
foreach ($VPG in $VPGsToCreate)
{
$VPGName = $VPG.VPGName
$VPGVMs = $ZVRArray | Where {$_.VPGName -Match "$VPGName"}
$VPGVMNames = $VPGVMs.VMName
# Need to get Zerto Identifier for each VM here
write-host "Creating Protection Group:$VPGName for VMs:$VPGVMNames"
################################################
# Getting the Zerto VM Identifiers for all the VMs to be created in this VPG
################################################
# Get SiteIdentifier for getting Local Identifier later in the script
$SiteInfoURL = $BaseURL+"localsite"
$SiteInfoCMD = Invoke-RestMethod -Uri $SiteInfoURL -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$LocalSiteIdentifier = $SiteInfoCMD | Select SiteIdentifier -ExpandProperty SiteIdentifier
# Reseting VM identifier list and creating array, needed as this could be executed for multiple VPGs
$VMIdentifierList = $null
$VMIDArray = @()
# Performing for each VM to protect action
foreach ($VMLine in $VPGVMNames)
{
write-host "$VMLine"
# Getting VM IDs
$VMInfoURL = $BaseURL+"virtualizationsites/$LocalSiteIdentifier/vms"
$VMInfoCMD = Invoke-RestMethod -Uri $VMInfoURL -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$VMIdentifier = $VMInfoCMD | Where-Object {$_.VmName -eq $VMLine} | select VmIdentifier -ExpandProperty VmIdentifier
$VMBootID = $ZVRArray | Where {$_.VMName -Match $VMLine } | Select-Object BootGroupID -ExpandProperty BootGroupID
# Adding VM ID and boot group to array for the API
$VMIDArrayLine = new-object PSObject
$VMIDArrayLine | Add-Member -MemberType NoteProperty -Name "VMID" -Value $VMIdentifier
$VMIDArrayLine | Add-Member -MemberType NoteProperty -Name "VMBootID" -Value $VMBootID
$VMIDArray += $VMIDArrayLine
}
################################################
# Getting Zerto identifiers based on the friendly names in the CSV to use for VPG creation
################################################
# Get SiteIdentifier for getting Identifiers
$TargetSiteInfoURL = $BaseURL+"virtualizationsites"
$TargetSiteInfoCMD = Invoke-RestMethod -Uri $TargetSiteInfoURL -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$TargetSiteIdentifier = $TargetSiteInfoCMD | Where-Object {$_.VirtualizationSiteName -eq $RecoverySiteName} | select SiteIdentifier -ExpandProperty SiteIdentifier
# Get NetworkIdentifiers for API
$VISiteInfoURL1 = $BaseURL+"virtualizationsites/$TargetSiteIdentifier/networks"
$VISiteInfoCMD1 = Invoke-RestMethod -Uri $VISiteInfoURL1 -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$FailoverNetworkIdentifier = $VISiteInfoCMD1 | Where-Object {$_.VirtualizationNetworkName -eq $FailoverNetwork} | Select NetworkIdentifier -ExpandProperty NetworkIdentifier
$TestNetworkIdentifier = $VISiteInfoCMD1 | Where-Object {$_.VirtualizationNetworkName -eq $TestNetwork} | Select NetworkIdentifier -ExpandProperty NetworkIdentifier
# Get ClusterIdentifier for API
$VISiteInfoURL2 = $BaseURL+"virtualizationsites/$TargetSiteIdentifier/hostclusters"
$VISiteInfoCMD2 = Invoke-RestMethod -Uri $VISiteInfoURL2 -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$ClusterIdentifier = $VISiteInfoCMD2 | Where-Object {$_.VirtualizationClusterName -eq $ClusterName} | Select ClusterIdentifier -ExpandProperty ClusterIdentifier
# Get ServiceProfileIdenfitifer for API
$VISiteServiceProfileURL = $BaseURL+"serviceprofiles"
$VISiteServiceProfileCMD = Invoke-RestMethod -Uri $VISiteServiceProfileURL -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$ServiceProfileIdentifier = $VISiteServiceProfileCMD | Where-Object {$_.Description -eq $ServiceProfile} | Select ServiceProfileIdentifier -ExpandProperty ServiceProfileIdentifier
# Get DatastoreIdentifiers for API
$VISiteInfoURL3 = $BaseURL+"virtualizationsites/$TargetSiteIdentifier/datastores"
$VISiteInfoCMD3 = Invoke-RestMethod -Uri $VISiteInfoURL3 -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$DatastoreIdentifier = $VISiteInfoCMD3 | Where-Object {$_.DatastoreName -eq $DatastoreName} | Select DatastoreIdentifier -ExpandProperty DatastoreIdentifier
$JournalDatastoreIdentifier = $VISiteInfoCMD3 | Where-Object {$_.DatastoreName -eq $JournalDatastore} | Select DatastoreIdentifier -ExpandProperty DatastoreIdentifier
# Get Folders for API
$VISiteInfoURL4 = $BaseURL+"virtualizationsites/$TargetSiteIdentifier/folders"
$VISiteInfoCMD4 = Invoke-RestMethod -Uri $VISiteInfoURL4 -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$FolderIdentifier = $VISiteInfoCMD4 | Where-Object {$_.FolderName -eq $vCenterFolder} | Select FolderIdentifier -ExpandProperty FolderIdentifier
# Outputting API results for easier troubleshooting
write-host "ZVR API Output:
$TargetSiteInfoCMD
$VISiteServiceProfileCMD
$VISiteInfoCMD1
$VISiteInfoCMD2
$VISiteInfoCMD3
$VISiteInfoCMD4"
################################################
# Building JSON Request for posting VPG settings to API
################################################
$JSONMain =
"{
 ""Backup"": null,
 ""Basic"": {
 ""JournalHistoryInHours"": ""$JournalHistoryInHours"",
 ""Name"": ""$VPGName"",
 ""Priority"": ""$ReplicationPriority"",
 ""ProtectedSiteIdentifier"": ""$LocalSiteIdentifier"",
 ""RecoverySiteIdentifier"": ""$TargetSiteIdentifier"",
 ""RpoInSeconds"": ""$RpoAlertInSeconds"",
 ""ServiceProfileIdentifier"": null,
 ""TestIntervalInMinutes"": ""$TestIntervalInMinutes"",
 ""UseWanCompression"": true,
 ""ZorgIdentifier"": null
 },
 ""BootGroups"": {
 ""BootGroups"": [
 {
 ""BootDelayInSeconds"": 0,
 ""BootGroupIdentifier"": ""00000000-0000-0000-0000-000000000001"",
 ""Name"": ""Database""
 },
 {
 ""BootDelayInSeconds"": ""$BootGroupDelay"",
 ""BootGroupIdentifier"": ""00000000-0000-0000-0000-000000000002"",
 ""Name"": ""Web""
 }
 ]
 },
 ""Journal"": {
    ""DatastoreClusterIdentifier"":null,
    ""DatastoreIdentifier"":""$DatastoreIdentifier"",
    ""Limitation"":{
    ""HardLimitInMB"":""$JournalHardLimitInMB"",
    ""HardLimitInPercent"":null,
    ""WarningThresholdInMB"":""$JournalWarningThresholdInMB"",
    ""WarningThresholdInPercent"":null
    }
    },
    ""Networks"": {
    ""Failover"":{
    ""Hypervisor"":{
    ""DefaultNetworkIdentifier"":""$FailoverNetworkIdentifier""
    }
    },
    ""FailoverTest"":{
    ""Hypervisor"":{
    ""DefaultNetworkIdentifier"":""$TestNetworkIdentifier""
    }
    }
    },
    ""Recovery"": {
    ""DefaultDatastoreIdentifier"":""$DatastoreIdentifier"",
    ""DefaultFolderIdentifier"":""$FolderIdentifier"",
    ""DefaultHostClusterIdentifier"":""$ClusterIdentifier"",
    ""DefaultHostIdentifier"":null,
    ""ResourcePoolIdentifier"":null
    },
    ""Scripting"": {
    ""PostBackup"": null,
    ""PostRecovery"": {
    ""Command"": null,
    ""Parameters"": null,
    ""TimeoutInSeconds"": 0
    },
    ""PreRecovery"": {
    ""Command"": null,
    ""Parameters"": null,
    ""TimeoutInSeconds"": 0
    }
    },
    ""Vms"": ["
   # Resetting VMs if a previous VPG was created in this run of the script
   $JSONVMs = $null
   # Creating JSON VM array for all the VMs in the VPG
   foreach ($VM in $VMIDArray)
   {
   $VMID = $VM.VMID
   $VMBootID = $VM.VMBootID
   $JSONVMsLine = "{""VmIdentifier"":""$VMID"",""BootGroupIdentifier"":""$VMBootID""}"
   # Running if statement to check if this is the first VM in the array, if not then a comma is added to string
   if ($JSONVMs -ne $null)
   {
   $JSONVMsLine = "," + $JSONVMsLine
   }
   $JSONVMs = $JSONVMs + $JSONVMsLine
   }
   # Creating the end of the JSON request
   $JSONEnd = "]
   }"
   # Putting the JSON request together and outputting the request
   $JSON = $JSONMain + $JSONVMs + $JSONEnd
   write-host "Running JSON request below:
   $JSON"
   ################################################
   # Posting the VPG JSON Request to the API
   ################################################
Try
{
$VPGSettingsIdentifier = Invoke-RestMethod -Method Post -Uri $CreateVPGURL -Body $JSON -ContentType $TypeJSON -Headers $zertosessionHeader
write-host "VPGSettingsIdentifier: $VPGSettingsIdentifier"
}
Catch {
Write-Host $_.Exception.ToString()
$error[0] | Format-List -Force
}
################################################
# Confirming VPG settings from API
################################################
$ConfirmVPGSettingURL = $BaseURL+"vpgSettings/"+"$VPGSettingsIdentifier"
$ConfirmVPGSettingCMD = Invoke-RestMethod -Uri $ConfirmVPGSettingURL -Headers $zertosessionHeader -ContentType $TypeJSON
################################################
# Committing the VPG settings to be created
################################################
$CommitVPGSettingURL = $BaseURL+"vpgSettings/"+"$VPGSettingsIdentifier"+"/commit"
write-host "CommitVPGSettingURL:$CommitVPGSettingURL"
Try
{
Invoke-RestMethod -Method Post -Uri $CommitVPGSettingURL -ContentType $TypeJSON -Headers $zertosessionHeader -TimeoutSec 100
$VPGCreationStatus = "PASSED"
}
Catch {
$VPGCreationStatus = "FAILED"
Write-Host $_.Exception.ToString()
$error[0] | Format-List -Force
}
################################################
# Performing vSphere folder change operation to indicate protected VM, only if succesfully protected
################################################
if ($VPGCreationStatus -eq "PASSED")
{
foreach ($_ in $VPGVMNames)
{
# Setting VM name
$VMName = $_
# Changing VM to new folder
write-host "Moving VM $VMName to Folder $ProtectedVMvCenterFolderName"
Move-VM -VM $VMName -Destination $ProtectedVMvCenterFolderName
# End of per VM folder change below
}
# End of per VM folder change below
#
# End of per VM folder action if protection succeeded below
}
# End of per VM folder action if protection succeeded above
#
################################################
# Waiting xx minute/s before creating the next VPG
################################################
write-host "Waiting $NextVPGCreationDelay seconds before processing next VPG or finishing script"
sleep $NextVPGCreationDelay
# End of per VPG actions below
}
# End of per VPG actions above
################################################
# Disconnecting from vCenter
################################################
disconnect-viserver $vCenterServer -Force -Confirm:$false
################################################
# Stopping logging
################################################
stop-transcript
