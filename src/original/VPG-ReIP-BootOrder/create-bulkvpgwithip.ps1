################################################
# Configure the variables below
################################################
$LogDataDir = ".\"
$VPGList = ".\vpg-master.csv"
$VMList = ".\vpg-vm.csv"
$ZertoServer = "192.168.0.31"
$ZertoPort = "9669"
$ZertoUserObj = Get-Credential
$TimeToWaitBetweenVPGCreation = "120"
########################################################################################################################
# Nothing to configure below this line - Starting the main function of the script
########################################################################################################################
################################################
# Setting Cert Policy - required for successful auth with the Zerto API without connecting to vsphere using PowerCLI
################################################
add-type @"
 using System.Net;
 using System.Security.Cryptography.X509Certificates;
 public class TrustAllCertsPolicy : ICertificatePolicy {
 public bool CheckValidationResult(
 ServicePoint srvPoint, X509Certificate certificate,
 WebRequest request, int certificateProblem) {
 return true;
 }
 }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
################################################
# Connecting to vCenter - if required uncomment line below
################################################
# connect-viserver -Server $vCenterServer -User $vCenterUser -Password $vCenterPassword
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
$TypeJSON = "application/json"
$TypeXML = "application/xml"
$xZertoSessionResponse = Invoke-WebRequest -Uri $xZertoSessionURL -Headers $headers -Method POST -Body $sessionBody -ContentType $TypeJSON
#Extracting x-zerto-session from the response, and adding it to the actual API
$xZertoSession = $xZertoSessionResponse.headers.get_item("x-zerto-session")
$zertosessionHeader = @{"x-zerto-session"=$xZertoSession; "Accept"=$TypeJSON }
# URL to create VPG settings
$CreateVPGURL = $BaseURL+"vpgSettings"
################################################
# Importing the CSV of Profiles to use for VM Protection
################################################
$VPGCSVImport = Import-Csv $VPGList
$VMCSVImport = Import-Csv $VMList
################################################
# Running the creation process by VPG, as a VPG can contain multiple VMs
################################################
foreach ($VPG in $VPGCSVImport)
{
$VPGName = $VPG.VPGName
$ReplicationPriority = $VPG.ReplicationPriority
$RecoverySiteName = $VPG.RecoverySiteName
$ClusterName = $VPG.ClusterName
$FailoverNetwork = $VPG.FailoverNetwork
$TestNetwork = $VPG.TestNetwork
$DatastoreName = $VPG.DatastoreName
$JournalDatastore = $VPG.JournalDatastore
$vCenterFolder = $VPG.vCenterFolder
$JournalHistoryInHours = $VPG.JournalHistoryInHours
$RpoAlertInSeconds = $VPG.RpoAlertInSeconds
$TestIntervalInMinutes = $VPG.TestIntervalInMinutes
$JournalHardLimitInMB = $VPG.JournalHardLimitInMB
$JournalWarningThresholdInMB = $VPG.JournalWarningThresholdInMB
$BootGroupDelay = $VPG.BootGroupDelay
# Getting list of VMs for the VPG
$VPGVMs = $VMCSVImport | Where {$_.VPGName -Match "$VPGName"}
$VPGVMNames = $VPGVMs.VMName
# Logging and showing action
write-host "Creating Protection Group:$VPGName for VMs:$VPGVMNames"
################################################
# Getting Identifiers for VPG settings
################################################
# Get SiteIdentifier for getting Local Identifier later in the script
$SiteInfoURL = $BaseURL+"localsite"
$SiteInfoCMD = Invoke-RestMethod -Uri $SiteInfoURL -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$LocalSiteIdentifier = $SiteInfoCMD | Select SiteIdentifier -ExpandProperty SiteIdentifier
# Get SiteIdentifier for getting Identifiers
$TargetSiteInfoURL = $BaseURL+"virtualizationsites"
$TargetSiteInfoCMD = Invoke-RestMethod -Uri $TargetSiteInfoURL -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$TargetSiteIdentifier = $TargetSiteInfoCMD | Where-Object {$_.VirtualizationSiteName -eq $RecoverySiteName} | select SiteIdentifier -ExpandProperty SiteIdentifier
# Getting VM identifiers
$VMInfoURL = $BaseURL+"virtualizationsites/$LocalSiteIdentifier/vms"
$VMInfoCMD = Invoke-RestMethod -Uri $VMInfoURL -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
# Get NetworkIdentifiers for API
$VISiteInfoURL1 = $BaseURL+"virtualizationsites/$TargetSiteIdentifier/networks"
$VISiteInfoCMD1 = Invoke-RestMethod -Uri $VISiteInfoURL1 -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$FailoverNetworkIdentifier = $VISiteInfoCMD1 | Where-Object {$_.VirtualizationNetworkName -eq $FailoverNetwork} | Select -ExpandProperty NetworkIdentifier
$TestNetworkIdentifier = $VISiteInfoCMD1 | Where-Object {$_.VirtualizationNetworkName -eq $TestNetwork} | Select -ExpandProperty NetworkIdentifier
# Get ClusterIdentifier for API
$VISiteInfoURL2 = $BaseURL+"virtualizationsites/$TargetSiteIdentifier/hostclusters"
$VISiteInfoCMD2 = Invoke-RestMethod -Uri $VISiteInfoURL2 -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$ClusterIdentifier = $VISiteInfoCMD2 | Where-Object {$_.VirtualizationClusterName -eq $ClusterName} | Select -ExpandProperty ClusterIdentifier
# Get DatastoreIdentifiers for API
$VISiteInfoURL3 = $BaseURL+"virtualizationsites/$TargetSiteIdentifier/datastores"
$VISiteInfoCMD3 = Invoke-RestMethod -Uri $VISiteInfoURL3 -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$DatastoreIdentifier = $VISiteInfoCMD3 | Where-Object {$_.DatastoreName -eq $DatastoreName} | Select -ExpandProperty DatastoreIdentifier
$JournalDatastoreIdentifier = $VISiteInfoCMD3 | Where-Object {$_.DatastoreName -eq $JournalDatastore} | Select -ExpandProperty DatastoreIdentifier
# Get Folders for API
$VISiteInfoURL4 = $BaseURL+"virtualizationsites/$TargetSiteIdentifier/folders"
$VISiteInfoCMD4 = Invoke-RestMethod -Uri $VISiteInfoURL4 -TimeoutSec 100 -Headers $zertosessionHeader -ContentType $TypeJSON
$FolderIdentifier = $VISiteInfoCMD4 | Where-Object {$_.FolderName -eq $vCenterFolder} | Select -ExpandProperty FolderIdentifier
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
 ""BootDelayInSeconds"": ""$BootGroupDelay"",
 ""BootGroupIdentifier"": ""00000000-0000-0000-0000-000000000001"",
 ""Name"": ""Group1""
 },
 {
 ""BootDelayInSeconds"": ""0"",
 ""BootGroupIdentifier"": ""00000000-0000-0000-0000-000000000002"",
 ""Name"": ""Group2""
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
# Creating JSON request per VM using the VM array for all the VMs in the VPG
foreach ($VM in $VPGVMs)
{
$VMName = $VM.VMName
$BootGroupName = $VM.BootGroupName
$VMSettings = $VMInfoCMD | Where-Object {$_.VmName -eq $VMName} | select *
$VMIdentifier = $VMSettings | select -ExpandProperty VmIdentifier
# Getting VM NIC settings
$VMNICFailoverNetworkName = $VM.VMNICFailoverNetworkName
$VMNICFailoverDNSSuffix = $VM.VMNICFailoverDNSSuffix
$VMNICFailoverShouldReplaceMacAddress = $VM.VMNICFailoverShouldReplaceMacAddress
$VMNICFailoverGateway = $VM.VMNICFailoverGateway
$VMNICFailoverDHCP = $VM.VMNICFailoverDHCP
$VMNICFailoverPrimaryDns = $VM.VMNICFailoverPrimaryDns
$VMNICFailoverSecondaryDns = $VM.VMNICFailoverSecondaryDns
$VMNICFailoverStaticIp = $VM.VMNICFailoverStaticIp
$VMNICFailoverSubnetMask = $VM.VMNICFailoverSubnetMask
$VMNICFailoverTestNetworkName = $VM.VMNICFailoverTestNetworkName
$VMNICFailoverTestDNSSuffix = $VM.VMNICFailoverTestDNSSuffix
$VMNICFailoverTestShouldReplaceMacAddress = $VM.VMNICFailoverTestShouldReplaceMacAddress
$VMNICFailoverTestGateway = $VM.VMNICFailoverTestGateway
$VMNICFailoverTestDHCP = $VM.VMNICFailoverTestDHCP
$VMNICFailoverTestPrimaryDns = $VM.VMNICFailoverTestPrimaryDns
$VMNICFailoverTestSecondaryDns = $VM.VMNICFailoverTestSecondaryDns
$VMNICFailoverTestStaticIp = $VM.VMNICFailoverTestStaticIp
$VMNICFailoverTestSubnetMask = $VM.VMNICFailoverTestSubnetMask
# Setting answers to lower case for API to process
$VMNICFailoverShouldReplaceMacAddress = $VMNICFailoverShouldReplaceMacAddress.ToLower()
$VMNICFailoverDHCP = $VMNICFailoverDHCP.ToLower()
$VMNICFailoverTestShouldReplaceMacAddress = $VMNICFailoverTestShouldReplaceMacAddress.ToLower()
$VMNICFailoverTestDHCP = $VMNICFailoverTestDHCP.ToLower()
# Translating network names to ZVR Network Identifiers
$VMNICFailoverNetworkIdentifier = $VISiteInfoCMD1 | where-object {$_.VirtualizationNetworkName -eq $VMNICFailoverNetworkName} | select -ExpandProperty NetworkIdentifier
$VMNICFailoverTestNetworkIdentifier = $VISiteInfoCMD1 | where-object {$_.VirtualizationNetworkName -eq $VMNICFailoverTestNetworkName} | select -ExpandProperty NetworkIdentifier
# Setting boot group ID
if ($BootGroupName -eq "Group1")
{
$BootGroupIdentifier = "00000000-0000-0000-0000-000000000001"
}
else
{
$BootGroupIdentifier = "00000000-0000-0000-0000-000000000002"
}
#####################
# Building JSON start
#####################
$VMJSONStart =
" {
 ""BootGroupIdentifier"":""$BootGroupIdentifier"",
 ""VmIdentifier"":""$VMIdentifier"",
 ""Nics"":["
#####################
# Building NIC JSON
#####################
# NIC JSON
$VMJSONNIC =
" {
 ""Failover"":{
 ""Hypervisor"":{
 ""DnsSuffix"":""$VMNICFailoverDNSSuffix"",
 ""IpConfig"":{
 ""Gateway"":""$VMNICFailoverGateway"",
 ""IsDhcp"":$VMNICFailoverDHCP,
 ""PrimaryDns"":""$VMNICFailoverPrimaryDns"",
 ""SecondaryDns"":""$VMNICFailoverSecondaryDns"",
 ""StaticIp"":""$VMNICFailoverStaticIp"",
 ""SubnetMask"":""$VMNICFailoverSubnetMask""
 },
 ""NetworkIdentifier"":""$VMNICFailoverNetworkIdentifier"",
 ""ShouldReplaceMacAddress"":$VMNICFailoverShouldReplaceMacAddress
 }
 },
 ""FailoverTest"":{
 ""Hypervisor"":{
 ""DnsSuffix"":""$VMNICFailoverTestDNSSuffix"",
 ""IpConfig"":{
 ""Gateway"":""$VMNICFailoverTestGateway"",
 ""IsDhcp"":$VMNICFailoverTestDHCP,
 ""PrimaryDns"":""$VMNICFailoverTestPrimaryDns"",
 ""SecondaryDns"":""$VMNICFailoverTestSecondaryDns"",
 ""StaticIp"":""$VMNICFailoverTestStaticIp"",
 ""SubnetMask"":""$VMNICFailoverTestSubnetMask""
 },
 ""NetworkIdentifier"":""$VMNICFailoverTestNetworkIdentifier"",
 ""ShouldReplaceMACAddress"":$VMNICFailoverTestShouldReplaceMacAddress
 }
 },
 ""NicIdentifier"":""Network adapter 1""
 }"
#####################
# Building end of JSON
#####################
$VMJSONEnd = "]
 }"
#####################
# Putting JSON together
#####################
$JSONVMsLine = $VMJSONStart + $VMJSONNIC + $VMJSONEnd
# Running if statement to check if this is the first VM in the array, if not then a comma is added to string
if ($JSONVMs -ne $null)
{
$JSONVMsLine = "," + $JSONVMsLine
}
$JSONVMs = $JSONVMs + $JSONVMsLine
# End of for each VM below
}
# End of for each VM above
#
# Creating the end of the JSON request
$JSONEnd = "],
}"
# Putting the JSON request elements together and outputting the request
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
# Committing the VPG settings to be created
################################################
$CommitVPGSettingURL = $BaseURL+"vpgSettings/"+"$VPGSettingsIdentifier"+"/commit"
write-host "Commiting VPG creation for VPG:$VPGName with URL:
$CommitVPGSettingURL"
Try
{
Invoke-RestMethod -Method Post -Uri $CommitVPGSettingURL -ContentType $TypeJSON -Headers $zertosessionHeader -TimeoutSec 100
}
Catch {
Write-Host $_.Exception.ToString()
$error[0] | Format-List -Force
}
################################################
# Waiting $TimeToWaitBetweenVPGCreation seconds before creating the next VPG
################################################
write-host "Waiting $TimeToWaitBetweenVPGCreation seconds before creating the next VPG or stopping script if on the last VPG"
sleep $TimeToWaitBetweenVPGCreation
#
# End of per VPG actions below
}
# End of per VPG actions above