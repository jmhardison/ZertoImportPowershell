# Original From: http://s3.amazonaws.com/zertodownload_docs/Latest/White%20Paper%20-%20Automating%20Zerto%20Virtual%20Replication%20with%20PowerShell%20and%20REST%20APIs.pdf

################################################
# Configure the variables below
################################################
$LogDataDir = ".\"
$ESXiHostCSV = ".\vra-master.csv"
$ZertoServer = "192.168.0.31"
$ZertoPort = "9669"
$ZertoUserObj = Get-Credential
$SecondsBetweenVRADeployments = "120"
##################################################################################
# Nothing to configure below this line - Starting the main function of the script
##################################################################################
################################################
# Setting log directory for engine and current month
################################################
$CurrentMonth = get-date -format MM.yy
$CurrentTime = get-date -format hh.mm.ss
$CurrentLogDataDir = $LogDataDir + $CurrentMonth
$CurrentLogDataFile = $LogDataDir + $CurrentMonth + "\BulkVPGCreationLog-" + $CurrentTime + ".txt"
# Testing path exists to engine logging, if not creating it
$ExportDataDirTestPath = test-path $CurrentLogDataDir
if ($ExportDataDirTestPath -eq $False)
{
New-Item -ItemType Directory -Force -Path $CurrentLogDataDir
}
start-transcript -path $CurrentLogDataFile -NoClobber
################################################
# Setting Cert Policy - required for successful auth with the Zerto API
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
$zertoSessionHeader = @{"x-zerto-session"=$xZertoSession; "Accept"=$TypeJSON }
# Get SiteIdentifier for getting Network Identifier later in the script
$SiteInfoURL = $BaseURL+"localsite"
$SiteInfoCMD = Invoke-RestMethod -Uri $SiteInfoURL -TimeoutSec 100 -Headers $zertoSessionHeader -ContentType $TypeJSON
$SiteIdentifier = $SiteInfoCMD | Select-Object SiteIdentifier -ExpandProperty SiteIdentifier
$VRAInstallURL = $BaseURL+"vras"
################################################
# Importing the CSV of ESXi hosts to deploy VRA to
################################################
$ESXiHostCSVImport = Import-Csv $ESXiHostCSV
################################################
# Starting Install Process for each ESXi host specified in the CSV
################################################
foreach ($ESXiHost in $ESXiHostCSVImport)
{
# Setting variables for ease of use throughout script
$VRAESXiHostName = $ESXiHost.ESXiHostName
$VRADatastoreName = $ESXiHost.DatastoreName
$VRAPortGroupName = $ESXiHost.PortGroupName
$VRAGroupName = $ESXiHost.VRAGroupName
$VRAMemoryInGB = $ESXiHost.MemoryInGB
$VRADefaultGateway = $ESXiHost.DefaultGateway
$VRASubnetMask = $ESXiHost.SubnetMask
$VRAIPAddress = $ESXiHost.VRAIPAddress
# Get NetworkIdentifier for API
$APINetworkURL = $BaseURL+"virtualizationsites/$SiteIdentifier/networks"
$APINetworkCMD = Invoke-RestMethod -Uri $APINetworkURL -TimeoutSec 100 -Headers $zertoSessionHeader -ContentType $TypeJSON
$NetworkIdentifier = $APINetworkCMD | Where-Object {$_.VirtualizationNetworkName -eq $VRAPortGroupName} | Select-Object -ExpandProperty NetworkIdentifier
# Get HostIdentifier for API
$APIHostURL = $BaseURL+"virtualizationsites/$SiteIdentifier/hosts"
$APIHostCMD = Invoke-RestMethod -Uri $APIHostURL -TimeoutSec 100 -Headers $zertoSessionHeader -ContentType $TypeJSON
$VRAESXiHostID = $APIHostCMD | Where-Object {$_.VirtualizationHostName -eq $VRAESXiHostName} | Select-Object -ExpandProperty HostIdentifier
# Get DatastoreIdentifier for API
$APIDatastoreURL = $BaseURL+"virtualizationsites/$SiteIdentifier/datastores"
$APIDatastoreCMD = Invoke-RestMethod -Uri $APIDatastoreURL -TimeoutSec 100 -Headers $zertoSessionHeader -ContentType $TypeJSON
$VRADatastoreID = $APIDatastoreCMD | Where-Object {$_.DatastoreName -eq $VRADatastoreName} | Select-Object -ExpandProperty DatastoreIdentifier
# Creating JSON Body for API settings
$JSON =
"{
 ""DatastoreIdentifier"": ""$VRADatastoreID"",
 ""GroupName"": ""$VRAGroupName"",
 ""HostIdentifier"": ""$VRAESXiHostID"",
 ""HostRootPassword"":null,
 ""MemoryInGb"": ""$VRAMemoryInGB"",
 ""NetworkIdentifier"": ""$NetworkIdentifier"",
 ""UsePublicKeyInsteadOfCredentials"":true,
 ""VraNetworkDataApi"": {
 ""DefaultGateway"": ""$VRADefaultGateway"",
 ""SubnetMask"": ""$VRASubnetMask"",
 ""VraIPAddress"": ""$VRAIPAddress"",
 ""VraIPConfigurationTypeApi"": ""Static""
 }
}"
write-host "Executing $JSON"
# Now trying API install cmd
Try
{
Invoke-RestMethod -Method Post -Uri $VRAInstallURL -Body $JSON -ContentType $TypeJSON -Headers $zertoSessionHeader
}
Catch {
Write-Host $_.Exception.ToString()
$error[0] | Format-List -Force
}
# Waiting xx seconds before deploying the next VRA
write-host "Waiting $SecondsBetweenVRADeployments seconds before deploying the next VRA or stopping"
sleep $SecondsBetweenVRADeployments
# End of per Host operations below
}
# End of per Host operations above
################################################
# Stopping logging
################################################
Stop-Transcript