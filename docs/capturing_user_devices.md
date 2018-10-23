# Discovering User Devices

For mapping usernames to MAC addresses via IP address.
This requires multiple points of integration and these scripts capture the data from Windows Domains.

* We use [CIDR notation](https://en.wikipedia.org/wiki/Classless_Inter-Domain_Routing) for IP address filtering

## Remote Event Query

For grabbing user device details that are interacting with the domain controller.
This grabs one minutes worth of details and should be run once a minute.

* [Event result code details](https://www.ultimatewindowssecurity.com/securitylog/encyclopedia/event.aspx?eventID=4768)
* [Event details](https://docs.microsoft.com/en-us/windows/device-security/auditing/event-4768)

```powershell
# Required for reliable Resolve-DnsName.
import-module dnsclient

# Helper for filtering IP addresses belonging to a subnet
function checkSubnet ([string]$cidr, [string]$ip) {
    $network, [uint32]$subnetlen = $cidr.Split('/')
    $a = [uint32[]]$network.split('.')
    [uint32] $unetwork = ($a[0] -shl 24) + ($a[1] -shl 16) + ($a[2] -shl 8) + $a[3]
    $mask = (-bnot [uint32]0) -shl (32 - $subnetlen)
    $a = [uint32[]]$ip.split('.')
    [uint32] $uip = ($a[0] -shl 24) + ($a[1] -shl 16) + ($a[2] -shl 8) + $a[3]
    $unetwork -eq ($mask -band $uip)
}

# Use a password file: https://blogs.technet.microsoft.com/robcost/2008/05/01/powershell-tip-storing-and-using-password-credentials/
$User = "YourDomain\service_account"
$PWord = ConvertTo-SecureString -String "service_account_pass" -AsPlainText -Force
$Credential = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $User, $PWord

$results = New-Object System.Collections.Generic.List[System.Object]
$ips = @()
$events = $null

try {
    Write-Host "Requesting events from remote server...";

    $events = Get-WinEvent -ComputerName "domain.controller.com" -Credential $Credential -LogName "Security" -FilterXPath @"
    *[System[Provider[@Name='Microsoft-Windows-Security-Auditing'] and
      EventID=4768 and TimeCreated[timediff(@SystemTime) <= 90000]]] and
    *[EventData[Data[@Name='Status'] and (Data='0x0')]] and
    *[EventData[Data[@Name='TargetDomainName'] and (Data='YourDomain')]]
"@
} catch {
    Write-Host "Server found no results...";
    Write-Host $_.Exception.Message;
    exit 0
}

Write-Host "Events received from remote server";

# This makes the events look like they were requested locally
# (remote event requests come back as generic objects)
ForEach ($event in $events) {
    $eventXML = [xml]$event.ToXml()

    # Iterate through each one of the XML message properties
    For ($i=0; $i -lt $eventXML.Event.EventData.Data.Count; $i++) {
        # Append these as object properties
        Add-Member -InputObject $event -MemberType NoteProperty -Force `
            -Name  $eventXML.Event.EventData.Data[$i].name `
            -Value $eventXML.Event.EventData.Data[$i].'#text'
    }
}

Write-Host "IP addresses discovered:";

$events | ForEach-Object {
    try {
        $ip = $_.IpAddress
        $username = $_.TargetUserName
        $userlower = $username.ToLower()
        $domain = $_.TargetDomainName

        # Ensure the event includes the IP address
        if ([string]::IsNullOrWhiteSpace($ip) -Or ($ip -eq "-") -Or [string]::IsNullOrWhiteSpace($username) -Or [string]::IsNullOrWhiteSpace($domain)) {
            return
        }

        # Ensure IP address is of the correct type
        [IPAddress]$address = $ip
        if (($PSVersionTable.PSVersion.Major -ge 5) -Or (($PSVersionTable.PSVersion.Major -eq 4) -And ($PSVersionTable.PSVersion.Minor -ge 5))) {
            if ($address.IsIPv4MappedToIPv6) {
                $ip = $address.MapToIPv4().IPAddressToString
            } else {
                # Ignore IPv6
                if ($address.AddressFamily.ToString() -eq "InterNetworkV6") {
                    Write-Host "Ignoring IPv6 address: ", $ip
                    return
                }
            }
        } else {
            # Check IPv6 Mapping manually
            if (($address.AddressFamily.ToString() -eq "InterNetworkV6") -And $ip.StartsWith("::ffff:")) {
                $new_ip = $ip.Split("::ffff:")[-1]

                try {
                    [IPAddress]$address = $new_ip
                    if ($address.AddressFamily.ToString() -eq "InterNetwork") {
                        $ip = $new_ip
                    }
                } catch {
                    # we are not interested in this IP address
                    Write-Host "Ignoring IPv6 address: ", $ip
                    return
                }
            }
        }

        # Check the IP address hasn't been seen already
        if ($ips.Contains($ip)) { return }

        # Filter IP ranges, service accounts and computer names$
        if ( `
            ( `
                (checkSubnet "127.0.0.0/16" $ip) -Or `
                (checkSubnet "192.168.0.0/16" $ip) -Or `
                (checkSubnet "192.155.0.0/16" $ip) `
            ) -and `
            (!$userlower.StartsWith("sccm.")) -and `
            (!$userlower.StartsWith("svc.")) -and `
            ($username[-1] -ne "$") `
        ) {
            $ips += $ip
            Write-Host $ip;

            # Try to grab the computers hostname
            try {
                $hostname = (Resolve-DnsName $ip -ErrorAction SilentlyContinue)[0].NameHost
                $results.Add(@($ip,$username,$domain,$hostname))
            } catch {
                $results.Add(@($ip,$username,$domain))
            }
        }
    } catch {
        Write-Host "Error parsing event";
        Write-Host $_.Exception.Message;
    }
}

$resultArr = $results.ToArray()

# Only post to the server if there are results
if ($resultArr.length -gt 0) {
    Write-Host "Posting to control server";

    # Send to the server
    $postParams = ConvertTo-Json @{module="LocateUser";method="lookup";args=@($resultArr)}
    $res = Invoke-WebRequest -UseBasicParsing -Uri https://engine.server.com/control/api/webhooks/trig-SwDJ35~kzR/notify?secret=3ad9d883f8e7a17d490510530b07bd90 -Method POST -Body $postParams -ContentType "application/json" -TimeoutSec 40
    Write-Host "Response code was:" $res.StatusCode;

    if ($res.StatusCode -ne 202) {
        Write-Host "Webhook post failed...";
        exit 1
    }
} else {
    Write-Host "No results found...";
}

```

### Querying a MS Network Policy Server (RADIUS)

This allows us to grab MAC addresses of BYOD devices. Useful if tracking mobile phones on the wifi is desirable.

```powershell
# Required for reliable Resolve-DnsName.
import-module dnsclient
import-module dhcpserver

# Use a password file: https://blogs.technet.microsoft.com/robcost/2008/05/01/powershell-tip-storing-and-using-password-credentials/
$User = "YourDomain\service_account"
$PWord = ConvertTo-SecureString -String "service_account_pass" -AsPlainText -Force
$Credential = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $User, $PWord

$results = New-Object System.Collections.Generic.List[System.Object]
$macs = @()
$events = $null

try {
    Write-Host "Requesting events from Network Policy Server...";

    $events = Get-WinEvent -ComputerName "radius.server.com" -Credential $Credential -LogName "Security" -FilterXPath @"
    *[System[Provider[@Name='Microsoft-Windows-Security-Auditing'] and
      EventID=6278 and TimeCreated[timediff(@SystemTime) <= 90000]]] and
    *[EventData[Data[@Name='SubjectDomainName'] and (Data='YourDomain')]]
"@
} catch {
    Write-Host "Server found no results...";
    Write-Host $_.Exception.Message;
    exit 0
}

Write-Host "Events received from remote server";

# This makes the events look like they were requested locally
# (remote event requests come back as generic objects)
ForEach ($event in $events) {
    $eventXML = [xml]$event.ToXml()

    # Iterate through each one of the XML message properties
    For ($i=0; $i -lt $eventXML.Event.EventData.Data.Count; $i++) {
        # Append these as object properties
        Add-Member -InputObject $event -MemberType NoteProperty -Force `
            -Name  $eventXML.Event.EventData.Data[$i].name `
            -Value $eventXML.Event.EventData.Data[$i].'#text'
    }
}

Write-Host "MAC addresses discovered:";

$events | ForEach-Object {
    try {
        $mac_address = $_.CallingStationID
        # Username in domain\username format
        $username = $_.FullyQualifiedSubjectUserName
        $ip = $null

        # Grab the IP address assigned to the MAC address
        try {
            $ip = Get-DhcpServerv4Scope -ComputerName "dhcpserver.contoso.com" -ScopeId 192.168.4.0 | Get-DhcpServerv4Lease -ComputerName "dhcpserver.contoso.com" | where {$_.Clientid -like "$mac_address"}
            $ip = $ip.IPAddress.IPAddressToString
        } catch {
            # Ignore errors as it just means we won't able find the hostname
        }

        # Ensure the event includes the username and device mac address
        if ([string]::IsNullOrWhiteSpace($mac_address) -Or ($mac_address -eq "-") -Or [string]::IsNullOrWhiteSpace($username) -Or ($username -eq "-")) {
            return
        }

        # Check the IP address hasn't been seen already
        if ($macs.Contains($mac_address)) { return }

        # Filter IP ranges and computer name$
        $macs += $mac_address
        Write-Host $mac_address

        # Try to grab the computers hostname
        try {
            $hostname = (Resolve-DnsName $ip -ErrorAction SilentlyContinue)[0].NameHost
            $results.Add(@($mac_address,$username,$hostname))
        } catch {
            $results.Add(@($mac_address,$username))
        }
    } catch {
        Write-Host "Error parsing event";
        Write-Host $_.Exception.Message;
    }
}

$resultArr = $results.ToArray()

# Only post to the server if there are results
if ($resultArr.length -gt 0) {
    Write-Host "Posting to control server";

    # Send to the server
    $postParams = ConvertTo-Json @{module="LocateUser";method="associate";args=@($resultArr)}
    $res = Invoke-WebRequest -UseBasicParsing -Uri https://engine.server.com/control/api/webhooks/trig-SwDJ35~kzR/notify?secret=3ad9d883f8e7a17d490510530b07bd90 -Method POST -Body $postParams -ContentType "application/json" -TimeoutSec 40
    Write-Host "Response code was:" $res.StatusCode;

    if ($res.StatusCode -ne 202) {
        Write-Host "Webhook post failed...";
        exit 1
    }
} else {
    Write-Host "No results found...";
}

```


## Workstation Monitoring

Where users log onto a shared resource and we want to know who is sitting at which workstation.
We should attach an event to particular events using the filter below. More details on how to set this up [are here](https://docs.google.com/document/d/14XIJbnvJBg23Qc_oc3JN5Ub0geETTSmTWr8Sd8YryLM/edit?usp=sharing)

* [Event Type Details](https://www.ultimatewindowssecurity.com/securitylog/encyclopedia/event.aspx?eventID=4624)

```xml

  <Triggers>
    <EventTrigger>
      <ValueQueries>
          <Value name="username">Event/EventData/Data[@Name='TargetUserName']</Value>
          <Value name="domain">Event/EventData/Data[@Name='TargetDomainName']</Value>
      </ValueQueries>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Security"&gt;&lt;Select Path="Security"&gt;*[System[Provider[@Name='Microsoft-Windows-Security-Auditing'] and EventID=4624]] and *[EventData[Data[@Name='LogonType'] and (Data='2' or Data='7')]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>


```

This allows log off events to be be caught and the workstation marked as free.

```powershell

param (
    [Parameter(Mandatory=$false)][string]$username,
    [Parameter(Mandatory=$false)][string]$domain
)

# Get the IP address of the local PC
$ipV4 = Test-Connection -ComputerName $env:COMPUTERNAME -Count 1  | Select -ExpandProperty IPV4Address
$ip = $ipV4.IPAddressToString

# Ensure the event includes the IP address
if ([string]::IsNullOrWhiteSpace($ip) -Or ($ip -eq "-") -Or [string]::IsNullOrWhiteSpace($username) -Or [string]::IsNullOrWhiteSpace($domain)) {
    Write-Host "IP address was blank";
    exit 0
}

# Post to details to server
$postParams = ConvertTo-Json @{module="LocateUser";method="lookup";args=@(,@($ip,$username,$domain))}
Invoke-WebRequest -UseBasicParsing -Uri https://engine.server.com/control/api/webhooks/trig-O6AXyP7jb5/notify?secret=f371579324eb56659b2f0b2c6f43d617 -Method POST -Body $postParams -ContentType "application/json"

```


## Untrusted or Self Signed Certificates

Add this to ignore certificate errors

```powershell

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

```

## Protocol violation errors

Add this to ignore errors, see: https://stackoverflow.com/questions/35260354/powershell-wget-protocol-violation

```powershell

function Set-UseUnsafeHeaderParsing
{
    param(
        [Parameter(Mandatory,ParameterSetName='Enable')]
        [switch]$Enable,

        [Parameter(Mandatory,ParameterSetName='Disable')]
        [switch]$Disable
    )

    $ShouldEnable = $PSCmdlet.ParameterSetName -eq 'Enable'

    $netAssembly = [Reflection.Assembly]::GetAssembly([System.Net.Configuration.SettingsSection])

    if($netAssembly)
    {
        $bindingFlags = [Reflection.BindingFlags] 'Static,GetProperty,NonPublic'
        $settingsType = $netAssembly.GetType('System.Net.Configuration.SettingsSectionInternal')

        $instance = $settingsType.InvokeMember('Section', $bindingFlags, $null, $null, @())

        if($instance)
        {
            $bindingFlags = 'NonPublic','Instance'
            $useUnsafeHeaderParsingField = $settingsType.GetField('useUnsafeHeaderParsing', $bindingFlags)

            if($useUnsafeHeaderParsingField)
            {
              $useUnsafeHeaderParsingField.SetValue($instance, $ShouldEnable)
            }
        }
    }
}

# Call this before Invoke-WebRequest
Set-UseUnsafeHeaderParsing -Enable

```
