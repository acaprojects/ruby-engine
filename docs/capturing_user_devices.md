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

# Helper for filtering IP addresses belonging to a subnet
function checkSubnet ([string]$cidr, [string]$ip) {
    $network, [tint]$subnetlen = $cidr.Split('/')
    $a = [uint32[]]$network.split('.')
    [uint32] $unetwork = ($a[0] -shl 24) + ($a[1] -shl 16) + ($a[2] -shl 8) + $a[3]
    $mask = (-bnot [uint32]0) -shl (32 - $subnetlen)
    $a = [uint32[]]$ip.split('.')
    [uint32] $uip = ($a[0] -shl 24) + ($a[1] -shl 16) + ($a[2] -shl 8) + $a[3]
    $unetwork -eq ($mask -band $uip)
}

# For automated remote execution
# - file permissions should be such that only this user can read this file.
$User = "YourDomain\service_account"
$PWord = ConvertTo-SecureString -String "service_account_pass" -AsPlainText -Force
$Credential = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $User, $PWord

$results = New-Object System.Collections.Generic.List[System.Object]
try {
    $ips = @()

    Write-Host "Requesting events from remote server...";

    $events = Get-WinEvent -ComputerName "domain.controller.com" -Credential $Credential -LogName "Security" -FilterXPath @"
    *[System[Provider[@Name='Microsoft-Windows-Security-Auditing'] and
      EventID=4768 and TimeCreated[timediff(@SystemTime) <= 60000]]] and
    *[EventData[Data[@Name='Status'] and (Data='0x0')]] and
    *[EventData[Data[@Name='TargetDomainName'] and (Data='YourDomain')]]
"@

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
        $ip = $_.IpAddress
        $username = $_.TargetUserName
        $domain = $_.TargetDomainName

        # Ensure the event includes the IP address
        if ([string]::IsNullOrWhiteSpace($ip) -Or ($ip -eq "-") -Or [string]::IsNullOrWhiteSpace($username) -Or [string]::IsNullOrWhiteSpace($domain)) {
            return
        }

        # Ensure IP address is of the correct type
        [IPAddress]$address = $ip
        if ($address.IsIPv4MappedToIPv6) {
            $ip = $address.MapToIPv4().IPAddressToString
        }

        # Check the IP address hasn't been seen already
        if ($ips.Contains($ip)) { return }
        $ips += $ip

        Write-Host $ip;

        # Filter IP ranges
        if ((checkSubnet "127.0.0.0/16" $ip) -Or (checkSubnet "192.168.0.0/16" $ip)) {
            $results.Add(@($ip,$username,$domain))
        }
    }
} catch {
    Write-Host "Server found no results...";
    exit 0
}

$resultArr = $results.ToArray()

# Only post to the server if there are results
if ($resultArr.length -gt 0) {
    Write-Host "Posting to control server";

    # Send to the server
    $postParams = ConvertTo-Json @{module="LocateUser";method="lookup";args=@($resultArr)}
    Invoke-WebRequest -Uri https://engine.server.com/control/api/webhooks/trig-SwDJ35~kzR/notify?secret=3ad9d883f8e7a17d490510530b07bd90 -Method POST -Body $postParams -ContentType "application/json" -TimeoutSec 40
} else {
    Write-Host "No results found...";
}

```


## Workstation Monitoring

Where users log onto a shared resource and we want to know who is sitting at which workstation.
We should attach an event to particular events using the filter below. More details on how to set this up [are here](https://docs.google.com/document/d/188Yu3pNGnxzg3z4xsnNsgwIEyf9TZGYdjJI3w5lweSc/edit?usp=sharing)

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
$postParams = ConvertTo-Json @{module="LocateUser";method="lookup";args=@(@($ip,$username,$domain))}
Invoke-WebRequest -Uri https://engine.server.com/control/api/webhooks/trig-O6AXyP7jb5/notify?secret=f371579324eb56659b2f0b2c6f43d617 -Method POST -Body $postParams -ContentType "application/json"

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
