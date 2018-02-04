Install-Module -Name ZertoModule
Import-Module ZertoModule

Connect-ZertoZVM -ZertoServer "il1zerto.test.com" -ZertoUser  "Test\\ZertoUser"

#Putting it all together
$VPGFile = '.\vpg-master.csv'
$VMFile = '.\vm-master.csv'

$VPGList = Get-Content $VPGFile | ConvertFrom-Csv
$VMList = Get-Content $VMFile | ConvertFrom-Csv

$VPGList | ForEach-Object {
    #VPG Variables
    $VPGName = $_.VPGName
    $RecoverySiteName = $_.RecoverySiteName
    $ClusterName = $_.ClusterName
    $FailoverNetwork = $_.FailoverNetwork
    $TestNetwork = $_.TestNetwork
    $DatastoreName = $_.DatastoreName
    $Folder = $_.Folder

    #Get site id
    $failoversiteid = Get-ZertoSiteID -ZertoSiteName $_.RecoverySiteName


    #create an array
    $VMs = @()
    $VMList | Where-Object {$_.VPGName -eq $VPGName} | ForEach-Object {
        #get failover network id
        $failovernetid = Get-ZertoSiteNetworkID -ZertoSiteIdentifier $failoversiteid -NetworkName $_.FailoverNetwork
        $testnetid = Get-ZertoSiteNetworkID -ZertoSiteIdentifier $failoversiteid -NetworkName $_.TestNetwork

        #Make Recovery Object        
        $VPGRecovery = New-ZertoVPGVMRecovery -FolderIdentifier $_.Folder

        #Make IP Object
        $IP = New-ZertoVPGFailoverIPAddress -NICName $_.NICName `
                    -TestNetworkID $testnetid `
                    -NetworkID $failovernetid

        #Make VM Object
        $VM = New-ZertoVPGVirtualMachine -VMName $_.VMName -VPGFailoverIPAddress $IP -VPGVMRecovery $VPGRecovery

        #Add VM to array
        $VMs += $VM
    }

    #Create VPG with VM array
    Add-ZertoVPG -Priority Low `
        -VPGName $_.VPGName `
        -RecoverySiteName $_.RecoverySiteName `
        -ClusterName $_.ClusterName `
        -FailoverNetwork $_.FailoverNetwork `
        -TestNetwork $_.TestNetwork `
        -DatastoreName $_.DatastoreName `
        -Folder $_.Folder `
        -JournalUseDefault:$true `
        -VPGVirtualMachines $VMs
}