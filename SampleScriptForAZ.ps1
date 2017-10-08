# ***************************************************************************
# 
# File: SampleScriptForAZ.ps1
#
# Version: 1.1
# 
# Author: Igor Pagliai (MSFT)
# 
# 
# ---------------------------- DISCLAIMER ------------------------------------
# This script code is provided only as an example, code is "as is with no
# guarantee or waranty concerning the usability or impact on systems and 
# may be used, distributed, and modified in any way provided the parties 
# agree and acknowledge the Microsoft or Microsoft Partners have neither
# accountabilty or responsibility for results produced by use of this script.
## Microsoft will not provide any support through any means.
# ---------------------------- DISCLAIMER ------------------------------------
#
# ***************************************************************************



#region INIT 

# PowerShell version: 
Get-Module AzureRM -list | Select-Object Name,Version,Path

# Check PowerShell single modules versions: #
$module_names='AzureRM*' 
if(Get-Module -ListAvailable |  
    Where-Object { $_.name -clike $module_names })  
{  
    (Get-Module -ListAvailable | Where-Object{ $_.Name -clike $module_names }) |  
    Select Version, Name, Author, PowerShellVersion  | Format-Table 
}  
else  
{  
    “The Azure PowerShell module is not installed.” 
}


# Initialize global variables for the subscription #
# PLEASE replace parameter placeholders with your own values #
#
$mySubscriptionID = "Your Subscription ID"
$mySubscriptionName = "Your Subscription Name"
$VMpwd = "Your VM Administrator Password"  
$rgname = "Your Resource Group Name" 
$location = "Your Azure Region"
$storageacccountname = "Your Storage Account Name"
#
# Login and select subscription #
Login-AzureRmAccount
Get-AzureRmSubscription –SubscriptionName $mySubscriptionName | Set-AzureRmContext

# Get Azure Context for public Cloud
Get-AzureRmEnvironment -Name AzureCloud

#endregion INIT

#region CREATE BASIC RESOURCES

# Create new Resource Group #
New-AzureRmResourceGroup -Name $rgname -Location $location

# Create  storage account and set as default: #
New-AzureRmStorageAccount -ResourceGroupName $rgname -Name $storageacccountname -Type Standard_LRS -Location $location
Set-AzureRmCurrentStorageAccount –ResourceGroupName $rgname –StorageAccountName $storageacccountname
# Check current defaults: #
Get-AzureRmContext -Verbose

# Check Azure quotas for compute and storage: #
Get-AzureRmVMUsage $location
Get-AzureRmStorageUsage -Verbose

# Create Subnets and VNET #
$subnet1 = New-AzureRmVirtualNetworkSubnetConfig -Name 'Subnet1' -AddressPrefix '10.1.1.0/24'
$subnet2 = New-AzureRmVirtualNetworkSubnetConfig -Name 'Subnet2' -AddressPrefix '10.1.2.0/24'
$subnet3 = New-AzureRmVirtualNetworkSubnetConfig -Name 'Subnet3' -AddressPrefix '10.1.3.0/24'
New-AzureRmVirtualNetwork -Name 'Vnet1' -ResourceGroupName $rgname -Location $location -AddressPrefix '10.1.0.0/16' -Subnet $subnet1,$subnet2,$subnet3

#endregion

#region MANAGED DISK CREATION AND TEST

# Create an empty Managed Disk in ZONE1: #
$mdiskconfig1 = New-AzureRmDiskConfig -AccountType StandardLRS -Location $location -DiskSizeGB 256 -CreateOption Empty -Zone 1
$mdisk1 = New-AzureRmDisk -ResourceGroupName $rgname -Disk $mdiskconfig1 -DiskName "EmptyManagedDiskMD1"
$ref1 = (Get-AzureRmDisk -ResourceGroupName $rgname -DiskName "EmptyManagedDiskMD1")
Write-Host ('Disk Provisioning State -> [ ' + ($ref1.ProvisioningState) + ' ]')

# Resize of the disk: #
$ref1.DiskSizeGB = 512 
Update-AzureRmDisk -DiskName $ref1.Name -Disk $ref1 -ResourceGroupName $rgname
$ref1 = (Get-AzureRmDisk -ResourceGroupName $rgname -DiskName "EmptyManagedDiskMD1")
$ref1.DiskSizeGB
$ref1.ProvisioningState
$ref1.Zones

# Create a snapshot on the Managed Disk: #
$mdisksnapshotconfig1 = New-AzureRmSnapshotConfig -AccountType StandardLRS -DiskSizeGB 512 -Location $location -SourceUri $ref1.Id  -CreateOption Copy
$mdisksnapshot1 = New-AzureRmSnapshot -ResourceGroupName $rgname -SnapshotName "EmptyManagedDiskMD1snaphot" -Snapshot $mdisksnapshotconfig1
# NOTE: I can create a STANDARD snapshot from PREMIUM managed disk! #
Get-AzureRmSnapshot -ResourceGroupName $rgname -SnapshotName "EmptyManagedDiskMD1snaphot" -Verbose
# NOTE: There is no Zone attribute in the returned Snapshot object

# Get Snapshot reference and check provisioning state#
$mdisksnapshotref = Get-AzureRmSnapshot -ResourceGroupName $rgname -SnapshotName $mdisksnapshot1.Name
$mdisksnapshotref.ProvisioningState 
$mdisksnapshotref.Id

# Create a new disk in ZONE2 based on this snapshot (COPY operation): #
$mdiskconfig2 = New-AzureRmDiskConfig -AccountType StandardLRS -Location $location -DiskSizeGB 512 -CreateOption Copy -SourceUri $mdisksnapshotref.Id -Zone 2
$mdisk2 = New-AzureRmDisk -ResourceGroupName $rgname -Disk $mdiskconfig2 -DiskName "ManagedDiskFromSnapshot"
write-host "Disk created in Zone["($mdisk2.Zones)"] from a Snapshot on a disk in Zone ["($ref1.Zones)"]..."

#endregion

#region CREATE A NEW VM IN A ZONE

#Get networking objects
$vnet = Get-AzureRmVirtualNetwork -Name "Vnet1" -ResourceGroupName $rgname
$subnet = Get-AzureRmVirtualNetworkSubnetConfig -Name "Subnet1" -VirtualNetwork $vnet

# Create a ZONED ILPIP address of type "BASIC SKU in Zone1"
$vip1 = New-AzureRmPublicIpAddress -ResourceGroupName $rgname -Name “VIP1" -Location $location -AllocationMethod "Static" -DomainNameLabel `
            "mydomain10" -IdleTimeoutInMinutes 10 -IpAddressVersion IPv4 -Sku Basic -Zone 1

# Create a NIC #
$nic1 = New-AzureRmNetworkInterface -ResourceGroupName $rgname -Location $location -Name "nic1" -Subnet $subnet -PublicIpAddress $vip1 `
            -InternalDnsNameLabel "myinternalfqdn10"

# Create Network Security Group (NSG) and apply to the subnet level #
# Create NSG to assign to SUBNET1 to only allow incoming traffic on port 3389 (RDP) and 80 (HTTP) #
$rule1 = New-AzureRMNetworkSecurityRuleConfig -Name "web-rule" -Description "Allow HTTP" -Access Allow -Protocol Tcp -Direction Inbound -Priority 101 `
    -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80
$rule2 = New-AzureRmNetworkSecurityRuleConfig -Name "rdp-rule" -Description "Allow RDP" -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
    -SourceAddressPrefix Internet -SourcePortRange * -DestinationPortRange 3389 -DestinationAddressPrefix *
$rule3 = New-AzureRmNetworkSecurityRuleConfig -Name "ssh-rule" -Description "Allow SSH" -Access Allow -Protocol Tcp -Direction Inbound -Priority 102 `
    -SourceAddressPrefix Internet -SourcePortRange * -DestinationPortRange 22 -DestinationAddressPrefix *
$nsg1 = New-AzureRmNetworkSecurityGroup -ResourceGroupName $rgname -Location $location -Name "NSG-1" -SecurityRules $rule1,$rule2,$rule3
# Apply NSG to SUBNET1 in VNET1 #
Set-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name "Subnet1" -AddressPrefix "10.1.1.0/24" -NetworkSecurityGroup $nsg1
Set-AzureRmVirtualNetwork -VirtualNetwork $vnet
$vnet = Get-AzureRmVirtualNetwork -ResourceGroupName $rgname  -Name "Vnet1"

# Select OS Image for Windows VM: #
$publisher = (Get-AzureRmVMImagePublisher -Location $location |? PublisherName -like "MicrosoftWindowsServer").PublisherName
$offer = (Get-AzureRmVMImageOffer -Location $location -PublisherName $publisher | ? Offer -EQ "WindowsServer").Offer
$sku = (Get-AzureRmVMImageSku -Location $location -Offer $offer -PublisherName $publisher | ? Skus -EQ "2012-R2-Datacenter").Skus
$imageid = (Get-AzureRmVMImage -Location $location -Offer $offer -PublisherName $publisher -Skus $sku | Sort Version -Descending)[0].Id
$version = (Get-AzureRmVMImage -Location $location -Offer $offer -PublisherName $publisher -Skus $sku | Sort Version -Descending)[0].Version

# Create the main VM object in Zone[1]: #
$AccountName = 'Your VM local admin account name'
$VMSize = "Standard_D2_v2" # Change if desired!
$VMName = "Your VM Name"
$ComputerName = $VMName 
$OSDiskName = $VMName + "-osDisk"
$vnetname = "Vnet1";
$subnetname = "Subnet1"
$zone = 1

$StorageAccount = Get-AzureRmStorageAccount -ResourceGroupName $rgname -Name $storageacccountname
# Credentials
$SecurePassword = ConvertTo-SecureString $VMpwd -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($AccountName, $SecurePassword); 
# Create VM Config #
$VirtualMachine = New-AzureRmVMConfig -VMName $VMName -VMSize $VMSize -Zone $zone
$VirtualMachine = Set-AzureRmVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $ComputerName -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate
$VirtualMachine = Set-AzureRmVMSourceImage -VM $VirtualMachine -PublisherName $publisher -Offer $offer -Skus $sku -Version "latest"
$VirtualMachine = Add-AzureRmVMNetworkInterface -VM $VirtualMachine -Id $nic1.Id -Primary
# Set the OS disk to be a Managed Disk #
$VirtualMachine = Set-AzureRmVMOSDisk -VM $VirtualMachine -Name $OSDiskName -CreateOption FromImage -Caching ReadWrite `
    -DiskSizeInGB 128 -StorageAccountType StandardLRS

$VM1 = New-AzureRmVM -ResourceGroupName $rgname -Location $Location -VM $VirtualMachine

#endregion 

#region ADD ADDITIONAL MANAGED DATA DISK AS ZONED RESOURCE

$zone = 1
$mdiskconfig2 = New-AzureRmDiskConfig -AccountType StandardLRS -Location $location -DiskSizeGB 128 -CreateOption Empty -Zone $zone
$mdisk2 = New-AzureRmDisk -ResourceGroupName $rgname -Disk $mdiskconfig2 -DiskName "EmptyManagedDiskMD3" 
$ref2 = (Get-AzureRmDisk -ResourceGroupName $rgname -DiskName "EmptyManagedDiskMD3")
$ref2.ProvisioningState # Succeded
$ref2.Zones # Zone[1]
$VM1 = Get-AzureRmVM -ResourceGroupName $rgname -Name $VMName
Add-AzureRmVMDataDisk -VM $VM1 -Name $ref2.Name -ManagedDiskId $ref2.Id -StorageAccountType $ref2.AccountType -CreateOption Attach -Lun 0 -Caching None -DiskSizeInGB $ref2.DiskSizeGB
Update-AzureRmVM -ResourceGroupName $rgname -VM $VM1
#Show VM and Disk Zone
write-host "VM created in Zone[" (Get-AzureRmVM -ResourceGroupName $rgname -Name $VMName).Zones "]"
write-host "Attached Data Disk in Zone[" $ref2.Zones "]"

# Try to ADD an additional data disk in a different Zone, will fail #
$zone = 3
$mdiskconfig3 = New-AzureRmDiskConfig -AccountType StandardLRS -Location $location -DiskSizeGB 128 -CreateOption Empty -Zone $zone
$mdisk3 = New-AzureRmDisk -ResourceGroupName $rgname -Disk $mdiskconfig3 -DiskName "EmptyManagedDiskMD4" 
$ref3 = (Get-AzureRmDisk -ResourceGroupName $rgname -DiskName "EmptyManagedDiskMD4")
$ref3.ProvisioningState # Succeded
$ref3.Zones # Zone[3]
$VM1 = Get-AzureRmVM -ResourceGroupName $rgname -Name $VMName
Add-AzureRmVMDataDisk -VM $VM1 -Name $ref3.Name -ManagedDiskId $ref3.Id -StorageAccountType $ref3.AccountType -CreateOption Attach -Lun 1 -Caching None -DiskSizeInGB $ref3.DiskSizeGB
Update-AzureRmVM -ResourceGroupName $rgname -VM $VM1
#Show VM and Disk Zone
write-host "VM created in Zone[" (Get-AzureRmVM -ResourceGroupName $rgname -Name $VMName).Zones "]"
write-host "Attached Data Disk in Zone[" $ref3.Zones "] failed..."

#endregion

#region DEVOPS

################################### List objects in the resource group along with ZONE ##########################
# List VMs:
Get-AzureRmVM -ResourceGroupName $rgname
# List Disks:
Get-AzureRMDisk -ResourceGroupName $rgname | select Name,Zones,Location
# List IP:
Get-AzureRmPublicIpAddress -ResourceGroupName $rgname | select Name,Location,IpAddress,PublicIpAddressVersion,Zones

################################### CLEANUP ################################
# Stop all VMs #
Get-AzureRmVM -ResourceGroupName $rgname | Stop-AzureRmVM -Force
# Remove entire Resource Group 
Remove-AzureRmResourceGroup -Name $rgname

#endregion


