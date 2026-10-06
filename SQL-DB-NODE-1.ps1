$ConfigData = @{
    AllNodes = @(
        @{
            NodeName                    = "localhost"
            # Allows credential to be saved in plain-text in the the *.mof instance document.
            PSDscAllowPlainTextPassword = $true
            PSDscAllowDomainUser        = $true
        }
    )
}

[DSCLocalConfigurationManager()]
Configuration LCMConfig
{
    Node localhost
    {
        Settings {
            RebootNodeIfNeeded = $True
            ActionAfterReboot  = "ContinueConfiguration"
            ConfigurationMode  = "ApplyOnly"
        }
    }
}

LCMConfig

Set-DscLocalConfigurationManager -Path .\LCMConfig -Verbose -Force

Get-DscLocalConfigurationManager

Configuration YM-Careers-SQLServerConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [string]$NodeName = "localhost",

        [Parameter(Mandatory)]
        [string]$NewComputerName
        
    )

    if($null -eq (Get-module -Name PowershellGet -Listavailable | where-object {$_.version -eq "2.2.4"})){ 
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 
        Install-Module PowerShellGet -RequiredVersion 2.2.4 -SkipPublisherCheck -Force  
        Install-module -Name ComputerManagementDsc, xComputerManagement, NetworkingDsc, StorageDsc, xSQLServer, SqlServerDsc -Force
    }

    #Tags and Instance data
    $instanceId = (New-Object System.Net.WebClient).DownloadString("http://169.254.169.254/latest/meta-data/instance-id")
    $environment = "beta"#(Get-EC2Tag | Where-Object { $_.ResourceId -eq $instanceId -and $_.Key -eq 'Environment' }).Value.ToLower()
    $role = (Get-EC2Tag | Where-Object { $_.ResourceId -eq $instanceId -and $_.Key -eq 'Role' }).Value
    $lc_role = $role.ToLower()
    $domainShort = "beta"#(Get-SSMParameter -Name /$environment/ad/domain_name_short).Value
    $domainname = (Get-SSMParameter -Name /$environment/ad/domain_name).Value
    $application = "YM-SQL-Server"#(Get-EC2Tag | Where-Object { $_.ResourceId -eq $instanceId -and $_.Key -eq 'Application' }).Value
    $Imagepath = "C:\software\SQLFULL_ENU.iso" #Imagepath for SQL installation media - should be present prior to running DSC.

    #Service Accounts
    $DomainUser = (Get-SSMParameter -Name /$environment/ad/user).Value
    $DomainUserpassword = (Get-SSMParameter -Name /$environment/ad/password -WithDecryption $true).Value | ConvertTo-SecureString -AsPlainText -Force
    $sqlserviceuserNoDomain = (Get-SSMParameter -Name /$environment/db/$application/sql_service_user).Value
    $sqlserviceuserpassword = (Get-SSMParameter -Name /$environment/db/$application/sql_service_password -WithDecryption $true).Value | ConvertTo-SecureString -AsPlainText -Force
    $sqlagentuserNoDomain = (Get-SSMParameter -Name /$environment/db/$application/sql_agent_user).Value
    $sqlagentuserpassword = (Get-SSMParameter -Name /$environment/db/$application/sql_agent_password -WithDecryption $true).Value | ConvertTo-SecureString -AsPlainText -Force
    $SaAccount = "sa"
    $SaPassword = -join ((48..90) + (97..122) | Get-Random -Count 24 | foreach {[char] $_}) | ConvertTo-SecureString -AsPlainText -Force
    
    #Domain variables
    if($environment -eq "prod"){
        $JoinOu = "OU=Computers,OU=ymc,DC=ymc,DC=$environment,DC=local"
    }
    else{
        $JoinOu = "OU=Computers,OU=$environment,DC=$environment,DC=ymc,DC=local"
    }

    #Service accounts for sql and domain join
    $SQLSvcAccountCred = New-Object System.Management.Automation.PSCredential -ArgumentList `
    "$domainShort\$sqlagentuserNoDomain", $sqlagentuserpassword
    
    $AgtSvcAccountCred = New-Object System.Management.Automation.PSCredential -ArgumentList `
    "$domainShort\$sqlagentuserNoDomain", $sqlagentuserpassword
    
    $DomainCredential = New-Object System.Management.Automation.PSCredential -ArgumentList `
    "$DomainUser", $DomainUserpassword

    $SaAccountCred = New-Object System.Management.Automation.PSCredential -ArgumentList `
    "$SaAccount", $SaPassword

    #SQLInstallation Parameters
    $Features = "SQLENGINE,SSMS"
    $InstanceName = "MSSQLSERVER"
    $SQLSaAccounts = "$domainShort\srvCareers", "$domainShort\SQL Admins", $DomainCredential.UserName

    #Pulling networking information
    $AmazonIpv4 = (Invoke-webrequest http://169.254.169.254/latest/meta-data/local-ipv4).content
    $LocalNetwork = Get-NetIPAddress | where-object {$_.IPv4Address -eq $AmazonIpv4}
    $Nic = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -computername . | where-object {$_.InterfaceIndex -eq $LocalNetwork.InterfaceIndex}

    [string]$Ip = $LocalNetwork.IPAddress
    [string]$AddressFamily = $LocalNetwork.AddressFamily
    [string]$Cidr = $Localnetwork.PrefixLength
    [string]$IpWithCidr = "$Ip/$Cidr"
    [string]$InterfaceAlias = $Localnetwork.InterfaceAlias
    [string]$Gateway = $Nic.DefaultIPGateway
    [array]$Dns = $Nic.DNSServerSearchOrder -split ','

	Import-DscResource -Module ComputerManagementDsc
    Import-DscResource -Module xComputerManagement
    Import-DscResource -module PSDesiredStateConfiguration 
    Import-DscResource -Module NetworkingDsc
    Import-DscResource -Module StorageDsc
    Import-DscResource -Module xSQLServer
    Import-DscResource -Module SqlServerDsc


	Node $NodeName
    {
        NetIPInterface IpNetIntRequirements
        {
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = $AddressFamily
            Dhcp           = 'Disabled'
            Nlmtu          = 9000
        }

        NetAdapterBinding DisableIPv6
        {
            InterfaceAlias = $InterfaceAlias
            ComponentId    = 'ms_tcpip6'
            State          = 'Disabled'
        }
        
        IPAddress NewIPv4Address
        {
            IPAddress      = $IpWithCidr
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = $AddressFamily
        }

        DefaultGatewayAddress DefaultGateway
        {
            Address        = $Gateway
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = $AddressFamily
        }

        DnsServerAddress DnsServers
        {
            Address        = $Dns
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = $AddressFamily
            Validate       = $true
        }

        DnsConnectionSuffix DnsSuffix
        {
            InterfaceAlias                 = $InterfaceAlias
            RegisterThisConnectionsAddress = $False
            ConnectionSpecificSuffix       = $domainname
            DependsOn                      = '[DnsServerAddress]DnsServers'
        }
    


        Computer JoinDomain
        {
            #Name          = $env:COMPUTERNAME
            Name           = $NewComputerName
            #WorkGroupName = "Workgroup"
            DomainName     = $domainname
            JoinOU         = $JoinOu
            Credential     = $DomainCredential
            DependsOn      = '[DnsServerAddress]DnsServers'
        }
       
        PendingReboot RebootAfterJoinDomain
        {
            Name = "DomainJoin"
            DependsOn = "[Computer]JoinDomain"
        }
        
        GroupSet AdminGroup
        {
            GroupName        = @("Administrators")
            Ensure           = "Present"
            MembersToInclude = @("$domainname\AWS Delegated Administrators")
            Credential       = $DomainCredential
        }

        WindowsFeature NetFramework45Core
        {
            Name = "NET-Framework-45-Core"
            Ensure = "Present"
        } 

        #Setup of Drives for SQL Backup and Data locations
        WaitForDisk Disk1
        {
            DiskId = 1
            DiskIdType = 'Number'
            RetryIntervalSec = 60
            RetryCount = 60
        }
        
        Disk FVolume
        {
            DiskId = 1
            DiskIdType = 'Number'
            FSFormat = 'NTFS'
            AllocationUnitSize = 65536
            DriveLetter = 'F'
            FSLabel = 'BACKUPS'
            AllowDestructive = $False
            DependsOn = '[WaitForDisk]Disk1'
        }

        WaitForDisk Disk2
        {
            DiskId = 2
            DiskIdType = 'Number'
            RetryIntervalSec = 60
            RetryCount = 60
        }
        
        Disk DVolume
        {
            DiskId = 2
            DiskIdType = 'Number'
            FSFormat = 'NTFS'
            AllocationUnitSize = 65536
            DriveLetter = 'D'
            FSLabel = 'DATA'
            AllowDestructive = $False
            DependsOn = '[WaitForDisk]Disk2'
        }

        WaitForDisk Disk3
        {
            DiskId = 3
            DiskIdType = 'Number'
            RetryIntervalSec = 60
            RetryCount = 60
        }
        
        Disk GVolume
        {
            DiskId = 3
            DiskIdType = 'Number'
            FSFormat = 'NTFS'
            AllocationUnitSize = 65536
            DriveLetter = 'G'
            FSLabel = 'BACKUPS'
            AllowDestructive = $False
            DependsOn = '[WaitForDisk]Disk3'
        }

        WaitForDisk Disk4
        {
            DiskId = 4
            DiskIdType = 'Number'
            RetryIntervalSec = 60
            RetryCount = 60
        }
        
        Disk HVolume
        {
            DiskId = 4
            DiskIdType = 'Number'
            FSFormat = 'NTFS'
            AllocationUnitSize = 65536
            DriveLetter = 'H'
            FSLabel = 'BACKUPS'
            AllowDestructive = $False
            DependsOn = '[WaitForDisk]Disk4'
        }

        File SQLBackupDir
        {
            Type = 'Directory'
            DestinationPath = 'F:\sql_back'
            Ensure = 'Present'
            DependsOn = '[Disk]FVolume'
        }

        File SQLUserDBDir
        {
            Type = 'Directory'
            DestinationPath = 'D:\sql_data'
            Ensure = 'Present'
            DependsOn = '[Disk]DVolume'
        }

        File SQLTempDBDir
        {
            Type = 'Directory'
            DestinationPath = 'H:\sql_data'
            Ensure = 'Present'
            DependsOn = '[Disk]HVolume'
        }

        MountImage MountSqlIso
        {
            ImagePath = $Imagepath
            DriveLetter = 'Z'
            StorageType = 'ISO'
            Access = 'ReadOnly'
            Ensure = 'Present'
        }
        
		<#********************************
		SQL Server Installation
		********************************#>
		
        SqlSetup SQL2012
		{
			InstanceName = $InstanceName 
            SQLCollation  = 'SQL_Latin1_General_CP1_CI_AS'
            SqlSysadminAccounts = $SQLSaAccounts
            SAPwd       = $SaAccountCred
            InstanceDir = "C:\Program Files\Microsoft SQL Server"
            INSTALLSHAREDWOWDIR="C:\Program Files (x86)\Microsoft SQL Server"
            InstallSQLDataDir = "D:\sql_data"
            SQLUserDBDir = "D:\sql_data"
            SQLUserDBLogDir = "D:\sql_logs"
            SQLTempDBDir = "H:\sql_data"
            SQLTempDBLogDir = "D:\sql_temp_logs"
            SQLBackupDir = "F:\sql_back"
			SourcePath = "Z:\"
			SecurityMode = "SQL"
			Features=$Features
			UpdateSource = "MU" # set this to windows update, otherwise it will use the default and cause the setup to crash
			UpdateEnabled = "True"
			SuppressReboot = $False
			ForceReboot = $False
            SqlSvcStartupType = "Automatic"
            BrowserSvcStartupType = "Disabled"
            TcpEnabled = $true
			SQLSvcAccount = $SQLSvcAccountCred
			AgtSvcAccount= $AgtSvcAccountCred
			Dependson = "[WindowsFeature]NetFramework45Core","[Disk]DVolume", "[Disk]FVolume", "[Disk]GVolume", "[Disk]HVolume", "[MountImage]MountSqlIso", `
            "[File]SqlTempDBDir", "[File]SQLUserDBDir", "[File]SQLBackupDir"
		 }
         

    }

}

YM-Careers-SQLServerConfiguration -ConfigurationData $ConfigData `
    -NodeName localhost -newcomputername SQL-DB-NODE-1

Test-DscConfiguration -Path .\YM-Careers-SQLServerConfiguration -Verbose

if((Test-path Z:) -eq $True){
    Dismount-diskimage -Imagepath $Imagepath
}