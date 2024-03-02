# SPDX-FileCopyrightText: Copyright Corsinvest Srl
# SPDX-License-Identifier: GPL-3.0-only

#Requires -Version 6.0

class PveValidateVmId : System.Management.Automation.IValidateSetValuesGenerator {
    [string[]] GetValidValues() { return Get-PveVm | Select-Object -ExpandProperty vmid }
}

class PveValidateVmName : System.Management.Automation.IValidateSetValuesGenerator {
    [string[]] GetValidValues() {
        return Get-PveVm | Where-Object { $_.status -ne 'unknown' } | Select-Object -ExpandProperty name
    }
}

class PveValidateNode : System.Management.Automation.IValidateSetValuesGenerator {
    [string[]] GetValidValues() { return Get-PveNodes | Select-Object -ExpandProperty node }
}

class PveTicket {
    [string] $HostName = ''
    [int] $Port = 8006
    [bool] $SkipCertificateCheck = $true
    [string] $Ticket = ''
    [string] $CSRFPreventionToken = ''
    [string] $ApiToken = ''
}

class PveResponse {
    #Contain real response of Proxmox VE
    #Is converted in object Json response
    [PSCustomObject] $Response
    [int] $StatusCode = 200
    [string] $ReasonPhrase
    [bool] $IsSuccessStatusCode = $true
    [string] $RequestResource
    [hashtable] $Parameters
    [string] $Method
    [string] $ResponseType

    [bool] ResponseInError() { return $null -ne $this.Response.error }
    [PSCustomObject] ToTable() { return $this.Response.data | Format-Table -Property * }
    [PSCustomObject] ToData() { return $this.Response.data }
    [void] ToCsv([string] $filename) { $this.Response.data | Export-Csv $filename }
    [void] ToGridView() { $this.Response.data | Out-GridView -Title "View Result Data" }
}

$Global:PveTicketLast = $null

##########
## CORE ##
##########
#region Core
function Connect-PveCluster {
    <#
.DESCRIPTION
Connect to Proxmox VE Cluster.
.PARAMETER HostsAndPorts
Host and ports
Format 10.1.1.90:8006,10.1.1.91:8006,10.1.1.92:8006.
.PARAMETER SkipCertificateCheck
Skips certificate validation checks.
.PARAMETER Credentials
Username and password, username formatted as user@pam, user@pve, user@yourdomain or user (default domain pam).
.PARAMETER ApiToken
Api Token format USER@REALM!TOKENID=UUID
.PARAMETER Otp
One-time password for Two-factor authentication.
.PARAMETER SkipRefreshPveTicketLast
Skip refresh PveTicket Last global variable
.EXAMPLE
$PveTicket = Connect-PveCluster -HostsAndPorts 192.168.128.115 -Credentials (Get-Credential -Username 'root').
.OUTPUTS
PveTicket. Return ticket connection.
#>
    [CmdletBinding()]
    [OutputType([PveTicket])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$HostsAndPorts,

        [pscredential]$Credentials,

        [string]$ApiToken,

        [string]$Otp,

        [switch]$SkipCertificateCheck,

        [switch]$SkipRefreshPveTicketLast
    )

    process {
        $hostName = '';
        $port = 0;

        #find host and port
        foreach ($hostAndPort in $HostsAndPorts) {
            $data = $hostAndPort.Split(':');
            $hostTmp = $data[0];
            $portTmp = 8006;

            if ($data.Length -eq 2 ) { [int32]::TryParse($data[1] , [ref]$portTmp) | Out-Null }

            if (Test-Connection -Ping $hostTmp -BufferSize 16 -Count 1 -ea 0 -quiet) {
                $hostName = $hostTmp;
                $port = $portTmp;
                break;
            }
        }

        if ([string]::IsNullOrWhiteSpace($hostName)) { throw 'Host not valid' }
        if ($port -le 0) { throw 'Port not valid' }

        $pveTicket = [PveTicket]::new()
        $pveTicket.HostName = $hostName
        $pveTicket.Port = $port
        $pveTicket.SkipCertificateCheck = $SkipCertificateCheck
        $pveTicket.ApiToken = $ApiToken

        if (-not $ApiToken)
        {
            if (-not $Credentials) {
                $Credentials = Get-Credential -Message 'Proxmox VE Username and password, username formated as user@pam, user@pve, user@yourdomain or user (default domain pam).'
            }

            #not exists domain set default pam
            $userName = $Credentials.UserName
            if ($userName.IndexOf('@') -lt 0) { $userName += '@pam' }

            $parameters = @{
                username = $userName
                password = $Credentials.GetNetworkCredential().Password
            }

            if($PSBoundParameters['Otp']) { $parameters['otp'] = $Otp }

            $response = Invoke-PveRestApi -PveTicket $pveTicket -Method Create -Resource '/access/ticket' -Parameters $parameters

            #erro response
            if (!$response.IsSuccessStatusCode -or $response.StatusCode -le 0) {
                throw $response.ReasonPhrase
            }

            if ($response.Response.data.NeedTFA){
                throw "Couldn't authenticate user: missing Two Factor Authentication (TFA)"
            }

            $pveTicket.Ticket = $response.Response.data.ticket
            $pveTicket.CSRFPreventionToken = $response.Response.data.CSRFPreventionToken
        }

        #last ticket connection
        if ($null -eq $Global:PveTicketLast -or (-not $SkipRefreshPveTicketLast)) {
            $Global:PveTicketLast = $pveTicket
        }

        return $pveTicket
    }
}

function Invoke-PveRestApi {
    <#
.DESCRIPTION
Invoke Proxmox VE Rest API
.PARAMETER PveTicket
Ticket data
.PARAMETER Resource
Resource Request
.PARAMETER Method
Method request
.PARAMETER ResponseType
Type request
.PARAMETER Parameters
Parameters request
.EXAMPLE
$PveTicket = Connect-PveCluster -HostsAndPorts '192.168.128.115' -Credentials (Get-Credential -Username 'root').
(Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource '/version').Resonse.data

data
----
@{version=5.4; release=15; repoid=d0ec33c6; keyboard=it}
.NOTES
This must be used before any other cmdlets are used
.OUTPUTS
Return object request
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory)]
        [string]$Resource,

        [ValidateNotNullOrEmpty()]
        [ValidateSet('Get', 'Set', 'Create', 'Delete')]
        [string]$Method = 'Get',

        [Parameter()]
        [ValidateSet('json', 'extjs', 'html', 'text', 'png','')]
        [string]$ResponseType = 'json',

        [hashtable]$Parameters
    )

    process {
        #use last ticket
        if ($null -eq $PveTicket) { $PveTicket = $Global:PveTicketLast }

        #web method
        $restMethod = @{
            Get    = 'Get'
            Set    = 'Put'
            Create = 'Post'
            Delete = 'Delete'
        }[$Method]

        $cookie = New-Object System.Net.Cookie -Property @{
            Name   = 'PVEAuthCookie'
            Path   = '/'
            Domain = $PveTicket.HostName
            Value  = $PveTicket.Ticket
        }

        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $session.cookies.add($cookie)

        $query = ''

        $parametersTmp = @{}

        if ($Parameters -and $Parameters.Count -gt 0 )
        {
             $Parameters.keys | ForEach-Object {
                $parametersTmp[$_] = $Parameters[$_] -is [switch] `
                                         ? $Parameters[$_] ? 1 : 0 `
                                         : $Parameters[$_]
             }
        }

        if ($parametersTmp.Count -gt 0 -and $('Get', 'Delete').IndexOf($restMethod) -ge 0) {
            Write-Debug 'Parameters:'
            $parametersTmp.keys | ForEach-Object { Write-Debug "$_ => $($parametersTmp[$_])" }

            $query = '?' + (($parametersTmp.Keys | ForEach-Object { "$_=$($parametersTmp[$_])" }) -join '&')
        }

        $response = New-Object PveResponse -Property @{
            Method          = $restMethod
            Parameters      = $parametersTmp
            ResponseType    = $ResponseType
            RequestResource = $Resource
        }

        $headers = @{ CSRFPreventionToken = $PveTicket.CSRFPreventionToken }
        if($PveTicket.ApiToken -ne '') { $headers.Authorization = 'PVEAPIToken ' + $PveTicket.ApiToken }

        $url = "https://$($PveTicket.HostName):$($PveTicket.Port)/api2"
        if($ResponseType -ne '') { $url += "/$ResponseType" }
        $url += "$Resource$query"

        $params = @{
            Uri                  = $url
            Method               = $restMethod
            WebSession           = $session
            SkipCertificateCheck = $PveTicket.SkipCertificateCheck
            Headers              = $headers
        }

        Write-Debug ($params | Format-List | Out-String)

        #body parameters
        if ($parametersTmp.Count -gt 0 -and $('Post', 'Put').IndexOf($restMethod) -ge 0) {
            $params['ContentType'] = 'application/json'
            $params['body'] = ($parametersTmp | ConvertTo-Json)
            Write-Debug "Body: $($params.body | Format-Table | Out-String)"
        }

        try {
            Write-Debug "Params: $($params | Format-Table | Out-String)"

            $response.Response = Invoke-RestMethod @params
        }
        catch {
            $response.StatusCode = $_.Exception.Response.StatusCode
            $response.ReasonPhrase = $_.Exception.Response.ReasonPhrase
            $response.IsSuccessStatusCode = $_.Exception.Response.IsSuccessStatusCode
            if ($response.StatusCode -eq 0) {
                $response.ReasonPhrase = $_.Exception.Message
                $response.StatusCode = -1
            }
        }

        Write-Debug "PveRestApi Response: $($response.Response | Format-Table | Out-String)"
        Write-Debug "PveRestApi IsSuccessStatusCode: $($response.IsSuccessStatusCode)"
        Write-Debug "PveRestApi StatusCode: $($response.StatusCode)"
        Write-Debug "PveRestApi ReasonPhrase: $($response.ReasonPhrase)"

        return $response
    }
}
#endregion

#############
## UTILITY ##
#############

#region Utility
Function Build-PveDocumentation {
    <#
.DESCRIPTION
Build documentation for Power Shell command For Proxmox VE
.PARAMETER TemplateFile
Template file for generation documentation
.PARAMETER OutputFile
Output file
#>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter()]
        [string] $TemplateFile = 'https://raw.githubusercontent.com/corsinvest/cv4pve-api-powershell/master/help-out-html.ps1',

        [Parameter(Mandatory)]
        [string] $OutputFile
    )

    process {
        $progress = 0
        $commands = (Get-Command -module 'Corsinvest.ProxmoxVE.Api' -CommandType Function) | Sort-Object #| Select-Object -first 10
        $totProgress = $commands.Length
        $data = [System.Collections.ArrayList]::new()
        foreach ($item in $commands) {
            $progress++
            $perc = [Math]::Round(($progress / $totProgress) * 100)
                            #-CurrentOperation "Completed $($progress) of $totProgress." `
            Write-Progress -Activity "Elaborate command" `
                            -Status "$perc% $($item.Name)" `
                            -PercentComplete $perc

            #help
            $help = Get-Help $item.Name -Full

            #alias
            $alias = Get-Alias -definition $item.Name -ErrorAction SilentlyContinue
            if ($alias) { $help | Add-Member Alias $alias }

            # related links and assign them to a links hashtable.
            if (($help.relatedLinks | Out-String).Trim().Length -gt 0) {
                $links = $help.relatedLinks.navigationLink | ForEach-Object {
                    if ($_.uri) { @{name = $_.uri; link = $_.uri; target = '_blank' } }
                    if ($_.linkText) { @{name = $_.linkText; link = "#$($_.linkText)"; cssClass = 'psLink'; target = '_top' } }
                }
                $help | Add-Member Links $links
            }

            #parameter aliases to the object.
            foreach ($parameter in $help.parameters.parameter ) {
                $paramAliases = ($cmdHelp.parameters.values | Where-Object name -like $parameter.name | Select-Object aliases).Aliases
                if ($paramAliases) { $parameter | Add-Member Aliases "$($paramAliases -join ', ')" -Force }
            }

            $data.Add($help) > $null
        }

        $data = $data | Where-Object { $_.Name }
        $totProgress = $data.Count

        #template
        $content = (($TemplateFile -as [System.Uri]).Scheme -match '[http|https]') ?
                    (Invoke-WebRequest $TemplateFile).Content :
                    (Get-Content $TemplateFile -Raw -Force)

        #generate help
        Invoke-Expression $content > $OutputFile
    }
}

#region Convert Time Windows/Unix
function ConvertTo-PveUnixTime {
<#
.SYNOPSIS
Convert datetime objects to UNIX time.
.DESCRIPTION
Convert System.DateTime objects to UNIX time.
.PARAMETER Date
Date time
.OUTPUTS
[Int32]. Return Unix Time.
#>
    [CmdletBinding()]
    [OutputType([long])]
    param (
        [Parameter(Mandatory,Position = 0,ValueFromPipeline )]
        [DateTime]$Date
    )

    process {
        [long] (New-Object -TypeName System.DateTimeOffset -ArgumentList ($Date)).ToUnixTimeSeconds()
    }
}

Function ConvertFrom-PveUnixTime {
    <#
.DESCRIPTION
Convert Unix Time in DateTime
.PARAMETER Time
Unix Time
.OUTPUTS
DateTime. Return DateTime from Unix Time.
#>
    [CmdletBinding()]
    [OutputType([DateTime])]
    param (
        [Parameter(Position = 0, Mandatory)]
        [long] $Time
    )

    return [System.DateTimeOffset]::FromUnixTimeSeconds($Time).DateTime
}
#endregion

Function Enter-PveSpice {
    <#
.DESCRIPTION
Enter Spice VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.PARAMETER Viewer
Path of Spice remove viewer.
- Linux /usr/bin/remote-viewer
- Windows C:\Program Files\VirtViewer v?.?-???\bin\remote-viewer.exe
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Viewer
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName | Select-Object -First 1
        if ($vm.type -eq 'qemu') {
            $node = $vm.node
            $vmid = $vm.vmid

            $parameters = @{ proxy = $null -eq $PveTicket ? $PveTicketLast.HostName : $PveTicket.HostName }

            $ret = Invoke-PveRestApi -PveTicket $PveTicket -Method Create -ResponseType '' -Resource "/spiceconfig/nodes/$node/qemu/$vmid/spiceproxy" -Parameters $parameters

            Write-Debug "======================================="
            Write-Debug "SPICE Proxy Configuration"
            Write-Debug "======================================="
            Write-Debug $ret
            Write-Debug "======================================="

            $tmp = New-TemporaryFile
            $ret.Response | Out-File $tmp.FullName

            Start-Process -FilePath $Viewer -Args $tmp.FullName
        }
    }
}

#region Task
function Wait-PveTaskIsFinish {
    <#
.DESCRIPTION
Get task is running.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Upid
Upid task e.g UPID:pve1:00004A1A:0964214C:5EECEF11:vzdump:134:root@pam:
.PARAMETER Wait
Millisecond wait next check
.PARAMETER Timeout
Millisecond timeout
.OUTPUTS
Bool. Return tas is running.
#>
    [OutputType([bool])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Upid,

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [int]$Wait = 500,

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [int]$Timeout = 10000
    )

    process {
        $isRunning = $true;
        if ($wait -le 0) { $wait = 500; }
        if ($timeOut -lt $wait) { $timeOut = $wait + 5000; }
        $timeStart = [DateTime]::Now
        $waitTime = $timeStart

        while ($isRunning -and ($timeStart - [DateTime]::Now).Milliseconds -lt $timeOut) {
            $now = [DateTime]::Now
            if (($now - $waitTime).TotalMilliseconds -ge $wait) {
                $waitTime = $now;
                $isRunning = Get-PveTaskIsRunning -PveTicket $PveTicket -Upid $Upid
            }
        }

        #check timeout
        return ($timeStart - [DateTime]::Now).Milliseconds -lt $timeOut
    }
}

function Get-PveTaskIsRunning {
    <#
.DESCRIPTION
Get task is running.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Upid
Upid task e.g UPID:pve1:00004A1A:0964214C:5EECEF11:vzdump:134:root@pam:
.OUTPUTS
Bool. Return tas is running.
#>
    [OutputType([bool])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Upid
    )

    process {
        return (Get-PveNodesTasksStatus -PveTicket $PveTicket -Node $Upid.Split(':')[1] -Upid $Upid).Response.data.status -eq 'running'
    }
}
#endregion

# function Get-PveStorage {
#     <#
# .DESCRIPTION
# Get nodes
# .PARAMETER PveTicket
# Ticket data connection.
# .PARAMETER Storage
# The Name of the storage.
# .OUTPUTS
# PSCustomObject. Return Vm Data.
# #>
#     [OutputType([PSCustomObject])]
#     [CmdletBinding()]
#     Param(
#         [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
#         [PveTicket]$PveTicket,

#         [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
#         [string]$Storage
#     )

#     process {
#         return $null -eq $Storage

#         $data = (Get-PveClusterResources -PveTicket $PveTicket -Type storage).Response.data
#         return $null -eq $Storage ?
#                 $data :
#                 $data | Where-Object { $_.storage -like $Storage }
#     }
# }

function Get-PveNode {
    <#
.DESCRIPTION
Get nodes
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The Name of the node.
.OUTPUTS
PSCustomObject. Return Vm Data.
#>
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $data = (Get-PveClusterResources -PveTicket $PveTicket -Type node).Response.data
        if($PSBoundParameters['Node'])
        {
            return $data | Where-Object { $_.node -like $Node }
        }
        else
        {
            return $data
        }
    }
}

function Get-PveVm {
    <#
.DESCRIPTION
Get VMs/CTs from id or name.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The id or name VM/CT comma separated (eg. 100,101,102,TestDebian)
-vmid or -name exclude (e.g. -200,-TestUbuntu)
range 100:107,-105,200:204
'@pool-???' for all VM/CT in specific pool (e.g. @pool-customer1),
'@tag-???' for all VM/CT in specific tags (e.g. @tag-customerA),
'@node-???' for all VM/CT in specific node (e.g. @node-pve1, @node-\$(hostname)),
'@all-???' for all VM/CT in specific host (e.g. @all-pve1, @all-\$(hostname)),
'@all' for all VM/CT in cluster";
.OUTPUTS
PSCustomObject. Return Vm Data.
#>
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$VmIdOrName
    )

    process {
        $data = (Get-PveClusterResources -PveTicket $PveTicket -Type vm).Response.data
        if ($PSBoundParameters['VmIdOrName'])
        {
            return $data | Where-Object { VmCheckIdOrName -Vm $_ -VmIdOrName $VmIdOrName }
        }
        else
        {
            return $data
        }
    }
}

function IsNumeric([string]$x) {
    try {
        0 + $x | Out-Null
        return $true
    } catch {
        return $false
    }
}

function VmCheckIdOrName
{
    [OutputType([bool])]
    Param(
        [PSCustomObject]$Vm,

        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName
    )

    if($VmIdOrName -eq 'all') { return $true }

    foreach ($item in $VmIdOrName.Split(","))
    {
        If($item -like '*:*')
        {
            #range number
            $range = $item.Split(":");
            if(($range.Length -eq 2) -and (IsNumeric($range[0])) -and (IsNumeric($range[1])))
            {
                if (($vm.vmid -ge $range[0]) -and ($vm.vmid -le $range[1])) {
                    return $true
                }
            }
        }
        ElseIf((IsNumeric($item)))
        {
            if($vm.vmid -eq $item) { return $true }
        }
        Elseif($item.IndexOf("all-") -eq 0 -and $item.Substring(4) -eq $vm.node)
        {
            #all vm in node
            return $true
        }
        Elseif($item.IndexOf("@all-") -eq 0 -and $item.Substring(5) -eq $vm.node)
        {
            #all vm in node
            return $true
        }
        Elseif($item.IndexOf("@node-") -eq 0 -and $item.Substring(6) -eq $vm.node)
        {
            #all vm in node
            return $true
        }
        Elseif($item.IndexOf("@pool-") -eq 0 -and $item.Substring(6) -eq $vm.pool)
        {
            #all vm in pool
            return $true
        }
        Elseif($item.IndexOf("@tags-") -eq 0)
        {
            #tags
            if(($vm.tags + "").Split(",").Contains($item.Substring(6)))
            {
                return $true
            }
        }
        ElseIf($vm.name -like $item) {
            #name
            return $true
        }
    }

    return $false
}

function Unlock-PveVm {
    <#
.DESCRIPTION
Unlock VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu') { return $vm | Set-PveNodesQemuConfig -PveTicket $PveTicket -Delete 'lock' -Skiplock }
        ElseIf ($vm.type -eq 'lxc') { return $vm | Set-PveNodesLxcConfig -PveTicket $PveTicket -Delete 'lock' }
    }
}

#region VM status
function Start-PveVm {
    <#
.DESCRIPTION
Start VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu') { return $vm | New-PveNodesQemuStatusStart -PveTicket $PveTicket }
        ElseIf ($vm.type -eq 'lxc') { return $vm | New-PveNodesLxcStatusStart -PveTicket $PveTicket }
    }
}

function Stop-PveVm {
    <#
.DESCRIPTION
Stop VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu') { return $vm | New-PveNodesQemuStatusStop -PveTicket $PveTicket }
        ElseIf ($vm.type -eq 'lxc') { return $vm | New-PveNodesLxcStatusStop -PveTicket $PveTicket }
    }
}

function Suspend-PveVm {
    <#
.DESCRIPTION
Suspend VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu') { return $vm | New-PveNodesQemuStatusSuspend -PveTicket $PveTicket }
        ElseIf ($vm.type -eq 'lxc') { return $vm | New-PveNodesLxcStatusSuspend -PveTicket $PveTicket }
    }
}

function Resume-PveVm {
    <#
.DESCRIPTION
Resume VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu') { return $vm | New-PveNodesQemuStatusResume -PveTicket $PveTicket }
        ElseIf ($vm.type -eq 'lxc') { return $vm | New-PveNodesLxcStatusResume -PveTicket $PveTicket }
    }
}

function Reset-PveVm {
    <#
.DESCRIPTION
Reset VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu') { return $vm | New-PveNodesQemuStatusReset -PveTicket $PveTicket }
        ElseIf ($vm.type -eq 'lxc') { throw "Lxc not implement reset!" }
    }
}
#endregion

#region Snapshot
function Get-PveVmSnapshot {
    <#
.DESCRIPTION
Get snapshots VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu') { return $vm | Get-PveNodesQemuSnapshot -PveTicket $PveTicket }
        ElseIf ($vm.type -eq 'lxc') { return $vm | Get-PveNodesLxcSnapshot -PveTicket $PveTicket }
    }
}

function New-PveVmSnapshot {
    <#
.DESCRIPTION
Create snapshot VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Description
A textual description or comment.
.PARAMETER Vmstate
Save the vmstate
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName,

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Description,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Snapname,

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [switch]$Vmstate = $false
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu')
        {
            if ($Vmstate) {
                return $vm | New-PveNodesQemuSnapshot -PveTicket $PveTicket -Snapname $Snapname -Description $Description -Vmstate
            }
            else
            {
                return $vm | New-PveNodesQemuSnapshot -PveTicket $PveTicket -Snapname $Snapname -Description $Description
            }
        }
        ElseIf ($vm.type -eq 'lxc')
        {
            return $vm | New-PveNodesLxcSnapshot -PveTicket $PveTicket -Snapname $Snapname -Description $Description
        }
    }
}

function Remove-PveVmSnapshot {
    <#
.DESCRIPTION
Delete a VM snapshot.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.PARAMETER Snapname
The name of the snapshot.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Snapname
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu') { return $vm | Remove-PveNodesQemuSnapshot -PveTicket $PveTicket -Snapname $Snapname }
        ElseIf ($vm.type -eq 'lxc') { return $vm | Remove-PveNodesLxcSnapshot -PveTicket $PveTicket -Snapname $Snapname }
    }
}

function Undo-PveVmSnapshot {
    <#
.DESCRIPTION
Rollback VM state to specified snapshot.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER VmIdOrName
The (unique) ID or Name of the VM.
.PARAMETER Snapname
The name of the snapshot.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$VmIdOrName,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Snapname
    )

    process {
        $vm = Get-PveVm -PveTicket $PveTicket -VmIdOrName $VmIdOrName
        if ($vm.type -eq 'qemu') { return $vm | New-PveNodesQemuSnapshotRollback -PveTicket $PveTicket -Snapname $Snapname }
        ElseIf ($vm.type -eq 'lxc') { return $vm | New-PveNodesLxcSnapshotRollback -PveTicket $PveTicket -Snapname $Snapname }
    }
}
#endregion
#endregion

###########
## ALIAS ##
###########

Set-Alias -Name Show-PveSpice -Value Enter-PveSpice -PassThru
Set-Alias -Name Get-PveTasksStatus -Value Get-PveNodesTasksStatus -PassThru

#QEMU
Set-Alias -Name Start-PveQemu -Value New-PveNodesQemuStatusStart -PassThru
Set-Alias -Name Stop-PveQemu -Value New-PveNodesQeumStatusStop -PassThru
Set-Alias -Name Suspend-PveQemu -Value New-PveNodesQemuStatusSuspend -PassThru
Set-Alias -Name Resume-PveQemu -Value New-PveNodesQemuStatusResume -PassThru
Set-Alias -Name Reset-PveQemu -Value New-PveNodesQemuStatusReset -PassThru
Set-Alias -Name Restart-PveQemu -Value New-PveNodesQemuStatusReboot -PassThru
#Set-Alias -Name Shutdown-PveQemu -Value New-PveNodesQemuStatusShutdown
Set-Alias -Name Move-PveQemu -Value New-PveNodesQemuMigrate -PassThru
Set-Alias -Name New-PveQemu -Value New-PveNodesQemu -PassThru
Set-Alias -Name Copy-PveQemu -Value New-PveNodesQemuClone -PassThru

#LXC
Set-Alias -Name Start-PveLxc -Value New-PveNodesLxcStatusStart -PassThru
Set-Alias -Name Stop-PveLxc -Value New-PveNodesLxcStatusStop -PassThru
Set-Alias -Name Suspend-PveLxc -Value New-PveNodesLxcStatusSuspend -PassThru
Set-Alias -Name Resume-PveLxc -Value New-PveNodesLxcStatusResume -PassThru
Set-Alias -Name Restart-PveLxc -Value New-PveNodesLxcStatusReboot -PassThru
#Set-Alias -Name Start-PveLxc -Value New-PveNodesLxcStatusShutdown
Set-Alias -Name Move-PveLxc -Value New-PveNodesLxcMigrate -PassThru
Set-Alias -Name Copy-PveLxc -Value New-PveNodesLxcClone -PassThru

#NODE
Set-Alias -Name Update-PveNode -Value New-PveNodesAptUpdate -PassThru
Set-Alias -Name Backup-PveVzdump -Value New-PveNodesVzdump -PassThru
#Set-Alias -Name Stop-PveNode -Value New-PveNodesStatus -Command 'shutdown' -PassThru

#######################
## API AUTOGENERATED ##
#######################

function Get-PveCluster
{
<#
.DESCRIPTION
Cluster index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster"
    }
}

function Get-PveClusterReplication
{
<#
.DESCRIPTION
List replication jobs.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/replication"
    }
}

function New-PveClusterReplication
{
<#
.DESCRIPTION
Create a new replication job
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Description.
.PARAMETER Disable
Flag to disable/deactivate the entry.
.PARAMETER Id
Replication Job ID. The ID is composed of a Guest ID and a job number, separated by a hyphen, i.e. '<GUEST>-<JOBNUM>'.
.PARAMETER Rate
Rate limit in mbps (megabytes per second) as floating point number.
.PARAMETER RemoveJob
Mark the replication job for removal. The job will remove all local replication snapshots. When set to 'full', it also tries to remove replicated volumes on the target. The job then removes itself from the configuration file. Enum: local,full
.PARAMETER Schedule
Storage replication schedule. The format is a subset of `systemd` calendar events.
.PARAMETER Source
For internal use, to detect if the guest was stolen.
.PARAMETER Target
Target node.
.PARAMETER Type
Section type. Enum: local
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Rate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('local','full')]
        [string]$RemoveJob,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Schedule,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Target,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('local')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Id']) { $parameters['id'] = $Id }
        if($PSBoundParameters['Rate']) { $parameters['rate'] = $Rate }
        if($PSBoundParameters['RemoveJob']) { $parameters['remove_job'] = $RemoveJob }
        if($PSBoundParameters['Schedule']) { $parameters['schedule'] = $Schedule }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/replication" -Parameters $parameters
    }
}

function Remove-PveClusterReplication
{
<#
.DESCRIPTION
Mark replication job for removal.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
Will remove the jobconfig entry, but will not cleanup.
.PARAMETER Id
Replication Job ID. The ID is composed of a Guest ID and a job number, separated by a hyphen, i.e. '<GUEST>-<JOBNUM>'.
.PARAMETER Keep
Keep replicated data at target (do not remove).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Keep
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Keep']) { $parameters['keep'] = $Keep }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/replication/$Id" -Parameters $parameters
    }
}

function Get-PveClusterReplicationIdx
{
<#
.DESCRIPTION
Read replication job configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
Replication Job ID. The ID is composed of a Guest ID and a job number, separated by a hyphen, i.e. '<GUEST>-<JOBNUM>'.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/replication/$Id"
    }
}

function Set-PveClusterReplication
{
<#
.DESCRIPTION
Update replication job configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Description.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Disable
Flag to disable/deactivate the entry.
.PARAMETER Id
Replication Job ID. The ID is composed of a Guest ID and a job number, separated by a hyphen, i.e. '<GUEST>-<JOBNUM>'.
.PARAMETER Rate
Rate limit in mbps (megabytes per second) as floating point number.
.PARAMETER RemoveJob
Mark the replication job for removal. The job will remove all local replication snapshots. When set to 'full', it also tries to remove replicated volumes on the target. The job then removes itself from the configuration file. Enum: local,full
.PARAMETER Schedule
Storage replication schedule. The format is a subset of `systemd` calendar events.
.PARAMETER Source
For internal use, to detect if the guest was stolen.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Rate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('local','full')]
        [string]$RemoveJob,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Schedule,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Rate']) { $parameters['rate'] = $Rate }
        if($PSBoundParameters['RemoveJob']) { $parameters['remove_job'] = $RemoveJob }
        if($PSBoundParameters['Schedule']) { $parameters['schedule'] = $Schedule }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/replication/$Id" -Parameters $parameters
    }
}

function Get-PveClusterMetrics
{
<#
.DESCRIPTION
Metrics index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/metrics"
    }
}

function Get-PveClusterMetricsServer
{
<#
.DESCRIPTION
List configured metric servers.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/metrics/server"
    }
}

function Remove-PveClusterMetricsServer
{
<#
.DESCRIPTION
Remove Metric server.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/metrics/server/$Id"
    }
}

function Get-PveClusterMetricsServerIdx
{
<#
.DESCRIPTION
Read metric server configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/metrics/server/$Id"
    }
}

function New-PveClusterMetricsServer
{
<#
.DESCRIPTION
Create a new external metric server config
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER ApiPathPrefix
An API path prefix inserted between '<host>':'<port>/' and '/api2/'. Can be useful if the InfluxDB service runs behind a reverse proxy.
.PARAMETER Bucket
The InfluxDB bucket/db. Only necessary when using the http v2 api.
.PARAMETER Disable
Flag to disable the plugin.
.PARAMETER Id
The ID of the entry.
.PARAMETER Influxdbproto
-- Enum: udp,http,https
.PARAMETER MaxBodySize
InfluxDB max-body-size in bytes. Requests are batched up to this size.
.PARAMETER Mtu
MTU for metrics transmission over UDP
.PARAMETER Organization
The InfluxDB organization. Only necessary when using the http v2 api. Has no meaning when using v2 compatibility api.
.PARAMETER Path
root graphite path (ex':' proxmox.mycluster.mykey)
.PARAMETER Port
server network port
.PARAMETER Proto
Protocol to send graphite data. TCP or UDP (default) Enum: udp,tcp
.PARAMETER Server
server dns name or IP address
.PARAMETER Timeout
graphite TCP socket timeout (default=1)
.PARAMETER Token
The InfluxDB access token. Only necessary when using the http v2 api. If the v2 compatibility api is used, use 'user':'password' instead.
.PARAMETER Type
Plugin type. Enum: graphite,influxdb
.PARAMETER VerifyCertificate
Set to 0 to disable certificate verification for https endpoints.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ApiPathPrefix,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bucket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('udp','http','https')]
        [string]$Influxdbproto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MaxBodySize,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Mtu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Organization,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Path,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('udp','tcp')]
        [string]$Proto,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Token,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('graphite','influxdb')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$VerifyCertificate
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['ApiPathPrefix']) { $parameters['api-path-prefix'] = $ApiPathPrefix }
        if($PSBoundParameters['Bucket']) { $parameters['bucket'] = $Bucket }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Influxdbproto']) { $parameters['influxdbproto'] = $Influxdbproto }
        if($PSBoundParameters['MaxBodySize']) { $parameters['max-body-size'] = $MaxBodySize }
        if($PSBoundParameters['Mtu']) { $parameters['mtu'] = $Mtu }
        if($PSBoundParameters['Organization']) { $parameters['organization'] = $Organization }
        if($PSBoundParameters['Path']) { $parameters['path'] = $Path }
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }
        if($PSBoundParameters['Token']) { $parameters['token'] = $Token }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['VerifyCertificate']) { $parameters['verify-certificate'] = $VerifyCertificate }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/metrics/server/$Id" -Parameters $parameters
    }
}

function Set-PveClusterMetricsServer
{
<#
.DESCRIPTION
Update metric server configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER ApiPathPrefix
An API path prefix inserted between '<host>':'<port>/' and '/api2/'. Can be useful if the InfluxDB service runs behind a reverse proxy.
.PARAMETER Bucket
The InfluxDB bucket/db. Only necessary when using the http v2 api.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Disable
Flag to disable the plugin.
.PARAMETER Id
The ID of the entry.
.PARAMETER Influxdbproto
-- Enum: udp,http,https
.PARAMETER MaxBodySize
InfluxDB max-body-size in bytes. Requests are batched up to this size.
.PARAMETER Mtu
MTU for metrics transmission over UDP
.PARAMETER Organization
The InfluxDB organization. Only necessary when using the http v2 api. Has no meaning when using v2 compatibility api.
.PARAMETER Path
root graphite path (ex':' proxmox.mycluster.mykey)
.PARAMETER Port
server network port
.PARAMETER Proto
Protocol to send graphite data. TCP or UDP (default) Enum: udp,tcp
.PARAMETER Server
server dns name or IP address
.PARAMETER Timeout
graphite TCP socket timeout (default=1)
.PARAMETER Token
The InfluxDB access token. Only necessary when using the http v2 api. If the v2 compatibility api is used, use 'user':'password' instead.
.PARAMETER VerifyCertificate
Set to 0 to disable certificate verification for https endpoints.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ApiPathPrefix,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bucket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('udp','http','https')]
        [string]$Influxdbproto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MaxBodySize,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Mtu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Organization,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Path,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('udp','tcp')]
        [string]$Proto,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Token,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$VerifyCertificate
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['ApiPathPrefix']) { $parameters['api-path-prefix'] = $ApiPathPrefix }
        if($PSBoundParameters['Bucket']) { $parameters['bucket'] = $Bucket }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Influxdbproto']) { $parameters['influxdbproto'] = $Influxdbproto }
        if($PSBoundParameters['MaxBodySize']) { $parameters['max-body-size'] = $MaxBodySize }
        if($PSBoundParameters['Mtu']) { $parameters['mtu'] = $Mtu }
        if($PSBoundParameters['Organization']) { $parameters['organization'] = $Organization }
        if($PSBoundParameters['Path']) { $parameters['path'] = $Path }
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }
        if($PSBoundParameters['Token']) { $parameters['token'] = $Token }
        if($PSBoundParameters['VerifyCertificate']) { $parameters['verify-certificate'] = $VerifyCertificate }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/metrics/server/$Id" -Parameters $parameters
    }
}

function Get-PveClusterNotifications
{
<#
.DESCRIPTION
Index for notification-related API endpoints.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications"
    }
}

function Get-PveClusterNotificationsEndpoints
{
<#
.DESCRIPTION
Index for all available endpoint types.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/endpoints"
    }
}

function Get-PveClusterNotificationsEndpointsSendmail
{
<#
.DESCRIPTION
Returns a list of all sendmail endpoints
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/endpoints/sendmail"
    }
}

function New-PveClusterNotificationsEndpointsSendmail
{
<#
.DESCRIPTION
Create a new sendmail endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Author
Author of the mail
.PARAMETER Comment
Comment
.PARAMETER Disable
Disable this target
.PARAMETER FromAddress
`From` address for the mail
.PARAMETER Mailto
List of email recipients
.PARAMETER MailtoUser
List of users
.PARAMETER Name
The name of the endpoint.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Author,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$FromAddress,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Mailto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MailtoUser,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Author']) { $parameters['author'] = $Author }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['FromAddress']) { $parameters['from-address'] = $FromAddress }
        if($PSBoundParameters['Mailto']) { $parameters['mailto'] = $Mailto }
        if($PSBoundParameters['MailtoUser']) { $parameters['mailto-user'] = $MailtoUser }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/notifications/endpoints/sendmail" -Parameters $parameters
    }
}

function Remove-PveClusterNotificationsEndpointsSendmail
{
<#
.DESCRIPTION
Remove sendmail endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/notifications/endpoints/sendmail/$Name"
    }
}

function Get-PveClusterNotificationsEndpointsSendmailIdx
{
<#
.DESCRIPTION
Return a specific sendmail endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/endpoints/sendmail/$Name"
    }
}

function Set-PveClusterNotificationsEndpointsSendmail
{
<#
.DESCRIPTION
Update existing sendmail endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Author
Author of the mail
.PARAMETER Comment
Comment
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Disable
Disable this target
.PARAMETER FromAddress
`From` address for the mail
.PARAMETER Mailto
List of email recipients
.PARAMETER MailtoUser
List of users
.PARAMETER Name
The name of the endpoint.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Author,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$FromAddress,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Mailto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MailtoUser,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Author']) { $parameters['author'] = $Author }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['FromAddress']) { $parameters['from-address'] = $FromAddress }
        if($PSBoundParameters['Mailto']) { $parameters['mailto'] = $Mailto }
        if($PSBoundParameters['MailtoUser']) { $parameters['mailto-user'] = $MailtoUser }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/notifications/endpoints/sendmail/$Name" -Parameters $parameters
    }
}

function Get-PveClusterNotificationsEndpointsGotify
{
<#
.DESCRIPTION
Returns a list of all gotify endpoints
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/endpoints/gotify"
    }
}

function New-PveClusterNotificationsEndpointsGotify
{
<#
.DESCRIPTION
Create a new gotify endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Comment
.PARAMETER Disable
Disable this target
.PARAMETER Name
The name of the endpoint.
.PARAMETER Server
Server URL
.PARAMETER Token
Secret token
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Token
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Token']) { $parameters['token'] = $Token }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/notifications/endpoints/gotify" -Parameters $parameters
    }
}

function Remove-PveClusterNotificationsEndpointsGotify
{
<#
.DESCRIPTION
Remove gotify endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/notifications/endpoints/gotify/$Name"
    }
}

function Get-PveClusterNotificationsEndpointsGotifyIdx
{
<#
.DESCRIPTION
Return a specific gotify endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
Name of the endpoint.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/endpoints/gotify/$Name"
    }
}

function Set-PveClusterNotificationsEndpointsGotify
{
<#
.DESCRIPTION
Update existing gotify endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Comment
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Disable
Disable this target
.PARAMETER Name
The name of the endpoint.
.PARAMETER Server
Server URL
.PARAMETER Token
Secret token
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Token
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Token']) { $parameters['token'] = $Token }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/notifications/endpoints/gotify/$Name" -Parameters $parameters
    }
}

function Get-PveClusterNotificationsEndpointsSmtp
{
<#
.DESCRIPTION
Returns a list of all smtp endpoints
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/endpoints/smtp"
    }
}

function New-PveClusterNotificationsEndpointsSmtp
{
<#
.DESCRIPTION
Create a new smtp endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Author
Author of the mail. Defaults to 'Proxmox VE'.
.PARAMETER Comment
Comment
.PARAMETER Disable
Disable this target
.PARAMETER FromAddress
`From` address for the mail
.PARAMETER Mailto
List of     email recipients
.PARAMETER MailtoUser
List of users
.PARAMETER Mode
Determine which encryption method shall be used for the connection. Enum: insecure,starttls,tls
.PARAMETER Name
The name of the endpoint.
.PARAMETER Password
Password for SMTP authentication
.PARAMETER Port
The port to be used. Defaults to 465 for TLS based connections, 587 for STARTTLS based connections and port 25 for insecure plain-text connections.
.PARAMETER Server
The address of the SMTP server.
.PARAMETER Username
Username for SMTP authentication
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Author,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$FromAddress,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Mailto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MailtoUser,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('insecure','starttls','tls')]
        [string]$Mode,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Username
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Author']) { $parameters['author'] = $Author }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['FromAddress']) { $parameters['from-address'] = $FromAddress }
        if($PSBoundParameters['Mailto']) { $parameters['mailto'] = $Mailto }
        if($PSBoundParameters['MailtoUser']) { $parameters['mailto-user'] = $MailtoUser }
        if($PSBoundParameters['Mode']) { $parameters['mode'] = $Mode }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Username']) { $parameters['username'] = $Username }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/notifications/endpoints/smtp" -Parameters $parameters
    }
}

function Remove-PveClusterNotificationsEndpointsSmtp
{
<#
.DESCRIPTION
Remove smtp endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/notifications/endpoints/smtp/$Name"
    }
}

function Get-PveClusterNotificationsEndpointsSmtpIdx
{
<#
.DESCRIPTION
Return a specific smtp endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/endpoints/smtp/$Name"
    }
}

function Set-PveClusterNotificationsEndpointsSmtp
{
<#
.DESCRIPTION
Update existing smtp endpoint
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Author
Author of the mail. Defaults to 'Proxmox VE'.
.PARAMETER Comment
Comment
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Disable
Disable this target
.PARAMETER FromAddress
`From` address for the mail
.PARAMETER Mailto
List of email recipients
.PARAMETER MailtoUser
List of users
.PARAMETER Mode
Determine which encryption method shall be used for the connection. Enum: insecure,starttls,tls
.PARAMETER Name
The name of the endpoint.
.PARAMETER Password
Password for SMTP authentication
.PARAMETER Port
The port to be used. Defaults to 465 for TLS based connections, 587 for STARTTLS based connections and port 25 for insecure plain-text connections.
.PARAMETER Server
The address of the SMTP server.
.PARAMETER Username
Username for SMTP authentication
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Author,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$FromAddress,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Mailto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MailtoUser,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('insecure','starttls','tls')]
        [string]$Mode,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Username
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Author']) { $parameters['author'] = $Author }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['FromAddress']) { $parameters['from-address'] = $FromAddress }
        if($PSBoundParameters['Mailto']) { $parameters['mailto'] = $Mailto }
        if($PSBoundParameters['MailtoUser']) { $parameters['mailto-user'] = $MailtoUser }
        if($PSBoundParameters['Mode']) { $parameters['mode'] = $Mode }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Username']) { $parameters['username'] = $Username }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/notifications/endpoints/smtp/$Name" -Parameters $parameters
    }
}

function Get-PveClusterNotificationsTargets
{
<#
.DESCRIPTION
Returns a list of all entities that can be used as notification targets.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/targets"
    }
}

function Get-PveClusterNotificationsMatchers
{
<#
.DESCRIPTION
Returns a list of all matchers
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/matchers"
    }
}

function New-PveClusterNotificationsMatchers
{
<#
.DESCRIPTION
Create a new matcher
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Comment
.PARAMETER Disable
Disable this matcher
.PARAMETER InvertMatch
Invert match of the whole matcher
.PARAMETER MatchCalendar
Match notification timestamp
.PARAMETER MatchField
Metadata fields to match (regex or exact match). Must be in the form (regex|exact)':'<field>=<value>
.PARAMETER MatchSeverity
Notification severities to match
.PARAMETER Mode
Choose between 'all' and 'any' for when multiple properties are specified Enum: all,any
.PARAMETER Name
Name of the matcher.
.PARAMETER Target
Targets to notify on match
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$InvertMatch,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MatchCalendar,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MatchField,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MatchSeverity,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('all','any')]
        [string]$Mode,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Target
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['InvertMatch']) { $parameters['invert-match'] = $InvertMatch }
        if($PSBoundParameters['MatchCalendar']) { $parameters['match-calendar'] = $MatchCalendar }
        if($PSBoundParameters['MatchField']) { $parameters['match-field'] = $MatchField }
        if($PSBoundParameters['MatchSeverity']) { $parameters['match-severity'] = $MatchSeverity }
        if($PSBoundParameters['Mode']) { $parameters['mode'] = $Mode }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/notifications/matchers" -Parameters $parameters
    }
}

function Remove-PveClusterNotificationsMatchers
{
<#
.DESCRIPTION
Remove matcher
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/notifications/matchers/$Name"
    }
}

function Get-PveClusterNotificationsMatchersIdx
{
<#
.DESCRIPTION
Return a specific matcher
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/notifications/matchers/$Name"
    }
}

function Set-PveClusterNotificationsMatchers
{
<#
.DESCRIPTION
Update existing matcher
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Comment
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Disable
Disable this matcher
.PARAMETER InvertMatch
Invert match of the whole matcher
.PARAMETER MatchCalendar
Match notification timestamp
.PARAMETER MatchField
Metadata fields to match (regex or exact match). Must be in the form (regex|exact)':'<field>=<value>
.PARAMETER MatchSeverity
Notification severities to match
.PARAMETER Mode
Choose between 'all' and 'any' for when multiple properties are specified Enum: all,any
.PARAMETER Name
Name of the matcher.
.PARAMETER Target
Targets to notify on match
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$InvertMatch,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MatchCalendar,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MatchField,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$MatchSeverity,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('all','any')]
        [string]$Mode,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Target
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['InvertMatch']) { $parameters['invert-match'] = $InvertMatch }
        if($PSBoundParameters['MatchCalendar']) { $parameters['match-calendar'] = $MatchCalendar }
        if($PSBoundParameters['MatchField']) { $parameters['match-field'] = $MatchField }
        if($PSBoundParameters['MatchSeverity']) { $parameters['match-severity'] = $MatchSeverity }
        if($PSBoundParameters['Mode']) { $parameters['mode'] = $Mode }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/notifications/matchers/$Name" -Parameters $parameters
    }
}

function Get-PveClusterConfig
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/config"
    }
}

function New-PveClusterConfig
{
<#
.DESCRIPTION
Generate new cluster configuration. If no links given, default to local IP address as link0.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Clustername
The name of the cluster.
.PARAMETER LinkN
Address and priority information of a single corosync link. (up to 8 links supported; link0..link7)
.PARAMETER Nodeid
Node id for this node.
.PARAMETER Votes
Number of votes for this node.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Clustername,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$LinkN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Nodeid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Votes
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Clustername']) { $parameters['clustername'] = $Clustername }
        if($PSBoundParameters['Nodeid']) { $parameters['nodeid'] = $Nodeid }
        if($PSBoundParameters['Votes']) { $parameters['votes'] = $Votes }

        if($PSBoundParameters['LinkN']) { $LinkN.keys | ForEach-Object { $parameters['link' + $_] = $LinkN[$_] } }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/config" -Parameters $parameters
    }
}

function Get-PveClusterConfigApiversion
{
<#
.DESCRIPTION
Return the version of the cluster join API available on this node.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/config/apiversion"
    }
}

function Get-PveClusterConfigNodes
{
<#
.DESCRIPTION
Corosync node list.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/config/nodes"
    }
}

function Remove-PveClusterConfigNodes
{
<#
.DESCRIPTION
Removes a node from the cluster configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/config/nodes/$Node"
    }
}

function New-PveClusterConfigNodes
{
<#
.DESCRIPTION
Adds a node to the cluster configuration. This call is for internal use.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Apiversion
The JOIN_API_VERSION of the new node.
.PARAMETER Force
Do not throw error if node already exists.
.PARAMETER LinkN
Address and priority information of a single corosync link. (up to 8 links supported; link0..link7)
.PARAMETER NewNodeIp
IP Address of node to add. Used as fallback if no links are given.
.PARAMETER Node
The cluster node name.
.PARAMETER Nodeid
Node id for this node.
.PARAMETER Votes
Number of votes for this node
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Apiversion,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$LinkN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$NewNodeIp,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Nodeid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Votes
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Apiversion']) { $parameters['apiversion'] = $Apiversion }
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['NewNodeIp']) { $parameters['new_node_ip'] = $NewNodeIp }
        if($PSBoundParameters['Nodeid']) { $parameters['nodeid'] = $Nodeid }
        if($PSBoundParameters['Votes']) { $parameters['votes'] = $Votes }

        if($PSBoundParameters['LinkN']) { $LinkN.keys | ForEach-Object { $parameters['link' + $_] = $LinkN[$_] } }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/config/nodes/$Node" -Parameters $parameters
    }
}

function Get-PveClusterConfigJoin
{
<#
.DESCRIPTION
Get information needed to join this cluster over the connected node.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The node for which the joinee gets the nodeinfo.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Node']) { $parameters['node'] = $Node }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/config/join" -Parameters $parameters
    }
}

function New-PveClusterConfigJoin
{
<#
.DESCRIPTION
Joins this node into an existing cluster. If no links are given, default to IP resolved by node's hostname on single link (fallback fails for clusters with multiple links).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Fingerprint
Certificate SHA 256 fingerprint.
.PARAMETER Force
Do not throw error if node already exists.
.PARAMETER Hostname
Hostname (or IP) of an existing cluster member.
.PARAMETER LinkN
Address and priority information of a single corosync link. (up to 8 links supported; link0..link7)
.PARAMETER Nodeid
Node id for this node.
.PARAMETER Password
Superuser (root) password of peer node.
.PARAMETER Votes
Number of votes for this node
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Fingerprint,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Hostname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$LinkN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Nodeid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Votes
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Fingerprint']) { $parameters['fingerprint'] = $Fingerprint }
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Hostname']) { $parameters['hostname'] = $Hostname }
        if($PSBoundParameters['Nodeid']) { $parameters['nodeid'] = $Nodeid }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Votes']) { $parameters['votes'] = $Votes }

        if($PSBoundParameters['LinkN']) { $LinkN.keys | ForEach-Object { $parameters['link' + $_] = $LinkN[$_] } }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/config/join" -Parameters $parameters
    }
}

function Get-PveClusterConfigTotem
{
<#
.DESCRIPTION
Get corosync totem protocol settings.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/config/totem"
    }
}

function Get-PveClusterConfigQdevice
{
<#
.DESCRIPTION
Get QDevice status
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/config/qdevice"
    }
}

function Get-PveClusterFirewall
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall"
    }
}

function Get-PveClusterFirewallGroups
{
<#
.DESCRIPTION
List security groups.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/groups"
    }
}

function New-PveClusterFirewallGroups
{
<#
.DESCRIPTION
Create new security group.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Group
Security Group name.
.PARAMETER Rename
Rename/update an existing security group. You can set 'rename' to the same value as 'name' to update the 'comment' of an existing group.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rename
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Group']) { $parameters['group'] = $Group }
        if($PSBoundParameters['Rename']) { $parameters['rename'] = $Rename }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/firewall/groups" -Parameters $parameters
    }
}

function Remove-PveClusterFirewallGroups
{
<#
.DESCRIPTION
Delete security group.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Group
Security Group name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/firewall/groups/$Group"
    }
}

function Get-PveClusterFirewallGroupsIdx
{
<#
.DESCRIPTION
List rules.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Group
Security Group name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/groups/$Group"
    }
}

function New-PveClusterFirewallGroupsIdx
{
<#
.DESCRIPTION
Create new rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER Group
Security Group name.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('in','out','group')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Pos']) { $parameters['pos'] = $Pos }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/firewall/groups/$Group" -Parameters $parameters
    }
}

function Remove-PveClusterFirewallGroupsIdx
{
<#
.DESCRIPTION
Delete rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Group
Security Group name.
.PARAMETER Pos
Update rule at position <pos>.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/firewall/groups/$Group/$Pos" -Parameters $parameters
    }
}

function Get-PveClusterFirewallGroupsIdx
{
<#
.DESCRIPTION
Get single rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Group
Security Group name.
.PARAMETER Pos
Update rule at position <pos>.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/groups/$Group/$Pos"
    }
}

function Set-PveClusterFirewallGroups
{
<#
.DESCRIPTION
Modify rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER Group
Security Group name.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Moveto
Move rule to new position <moveto>. Other arguments are ignored.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Moveto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('in','out','group')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Moveto']) { $parameters['moveto'] = $Moveto }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/firewall/groups/$Group/$Pos" -Parameters $parameters
    }
}

function Get-PveClusterFirewallRules
{
<#
.DESCRIPTION
List rules.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/rules"
    }
}

function New-PveClusterFirewallRules
{
<#
.DESCRIPTION
Create new rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('in','out','group')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Pos']) { $parameters['pos'] = $Pos }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/firewall/rules" -Parameters $parameters
    }
}

function Remove-PveClusterFirewallRules
{
<#
.DESCRIPTION
Delete rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Pos
Update rule at position <pos>.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/firewall/rules/$Pos" -Parameters $parameters
    }
}

function Get-PveClusterFirewallRulesIdx
{
<#
.DESCRIPTION
Get single rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Pos
Update rule at position <pos>.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/rules/$Pos"
    }
}

function Set-PveClusterFirewallRules
{
<#
.DESCRIPTION
Modify rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Moveto
Move rule to new position <moveto>. Other arguments are ignored.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Moveto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('in','out','group')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Moveto']) { $parameters['moveto'] = $Moveto }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/firewall/rules/$Pos" -Parameters $parameters
    }
}

function Get-PveClusterFirewallIpset
{
<#
.DESCRIPTION
List IPSets
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/ipset"
    }
}

function New-PveClusterFirewallIpset
{
<#
.DESCRIPTION
Create new IPSet
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
IP set name.
.PARAMETER Rename
Rename an existing IPSet. You can set 'rename' to the same value as 'name' to update the 'comment' of an existing IPSet.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rename
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Rename']) { $parameters['rename'] = $Rename }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/firewall/ipset" -Parameters $parameters
    }
}

function Remove-PveClusterFirewallIpset
{
<#
.DESCRIPTION
Delete IPSet
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
Delete all members of the IPSet, if there are any.
.PARAMETER Name
IP set name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/firewall/ipset/$Name" -Parameters $parameters
    }
}

function Get-PveClusterFirewallIpsetIdx
{
<#
.DESCRIPTION
List IPSet content
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
IP set name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/ipset/$Name"
    }
}

function New-PveClusterFirewallIpsetIdx
{
<#
.DESCRIPTION
Add IP or Network to IPSet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Name
IP set name.
.PARAMETER Nomatch
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nomatch
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Nomatch']) { $parameters['nomatch'] = $Nomatch }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/firewall/ipset/$Name" -Parameters $parameters
    }
}

function Remove-PveClusterFirewallIpsetIdx
{
<#
.DESCRIPTION
Remove IP or Network from IPSet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
IP set name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/firewall/ipset/$Name/$Cidr" -Parameters $parameters
    }
}

function Get-PveClusterFirewallIpsetIdx
{
<#
.DESCRIPTION
Read IP or Network settings from IPSet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Name
IP set name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/ipset/$Name/$Cidr"
    }
}

function Set-PveClusterFirewallIpset
{
<#
.DESCRIPTION
Update IP or Network settings
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
IP set name.
.PARAMETER Nomatch
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nomatch
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Nomatch']) { $parameters['nomatch'] = $Nomatch }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/firewall/ipset/$Name/$Cidr" -Parameters $parameters
    }
}

function Get-PveClusterFirewallAliases
{
<#
.DESCRIPTION
List aliases
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/aliases"
    }
}

function New-PveClusterFirewallAliases
{
<#
.DESCRIPTION
Create IP or Network Alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Name
Alias name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/firewall/aliases" -Parameters $parameters
    }
}

function Remove-PveClusterFirewallAliases
{
<#
.DESCRIPTION
Remove IP or Network alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
Alias name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/firewall/aliases/$Name" -Parameters $parameters
    }
}

function Get-PveClusterFirewallAliasesIdx
{
<#
.DESCRIPTION
Read alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
Alias name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/aliases/$Name"
    }
}

function Set-PveClusterFirewallAliases
{
<#
.DESCRIPTION
Update IP or Network alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
Alias name.
.PARAMETER Rename
Rename an existing alias.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rename
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Rename']) { $parameters['rename'] = $Rename }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/firewall/aliases/$Name" -Parameters $parameters
    }
}

function Get-PveClusterFirewallOptions
{
<#
.DESCRIPTION
Get Firewall options.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/options"
    }
}

function Set-PveClusterFirewallOptions
{
<#
.DESCRIPTION
Set Firewall options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Ebtables
Enable ebtables rules cluster wide.
.PARAMETER Enable
Enable or disable the firewall cluster wide.
.PARAMETER LogRatelimit
Log ratelimiting settings
.PARAMETER PolicyIn
Input policy. Enum: ACCEPT,REJECT,DROP
.PARAMETER PolicyOut
Output policy. Enum: ACCEPT,REJECT,DROP
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ebtables,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$LogRatelimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ACCEPT','REJECT','DROP')]
        [string]$PolicyIn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ACCEPT','REJECT','DROP')]
        [string]$PolicyOut
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Ebtables']) { $parameters['ebtables'] = $Ebtables }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['LogRatelimit']) { $parameters['log_ratelimit'] = $LogRatelimit }
        if($PSBoundParameters['PolicyIn']) { $parameters['policy_in'] = $PolicyIn }
        if($PSBoundParameters['PolicyOut']) { $parameters['policy_out'] = $PolicyOut }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/firewall/options" -Parameters $parameters
    }
}

function Get-PveClusterFirewallMacros
{
<#
.DESCRIPTION
List available macros
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/macros"
    }
}

function Get-PveClusterFirewallRefs
{
<#
.DESCRIPTION
Lists possible IPSet/Alias reference which are allowed in source/dest properties.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Type
Only list references of specified type. Enum: alias,ipset
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('alias','ipset')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/firewall/refs" -Parameters $parameters
    }
}

function Get-PveClusterBackup
{
<#
.DESCRIPTION
List vzdump backup schedule.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/backup"
    }
}

function New-PveClusterBackup
{
<#
.DESCRIPTION
Create new vzdump backup job.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER All
Backup all known guest systems on this host.
.PARAMETER Bwlimit
Limit I/O bandwidth (in KiB/s).
.PARAMETER Comment
Description for the Job.
.PARAMETER Compress
Compress dump file. Enum: 0,1,gzip,lzo,zstd
.PARAMETER Dow
Day of week selection.
.PARAMETER Dumpdir
Store resulting files to specified directory.
.PARAMETER Enabled
Enable or disable the job.
.PARAMETER Exclude
Exclude specified guest systems (assumes --all)
.PARAMETER ExcludePath
Exclude certain files/directories (shell globs). Paths starting with '/' are anchored to the container's root,  other paths match relative to each subdirectory.
.PARAMETER Id
Job ID (will be autogenerated).
.PARAMETER Ionice
Set IO priority when using the BFQ scheduler. For snapshot and suspend mode backups of VMs, this only affects the compressor. A value of 8 means the idle priority is used, otherwise the best-effort priority is used with the specified value.
.PARAMETER Lockwait
Maximal time to wait for the global lock (minutes).
.PARAMETER Mailnotification
Deprecated':' use 'notification-policy' instead. Enum: always,failure
.PARAMETER Mailto
Comma-separated list of email addresses or users that should receive email notifications. Has no effect if the 'notification-target' option  is set at the same time.
.PARAMETER Maxfiles
Deprecated':' use 'prune-backups' instead. Maximal number of backup files per guest system.
.PARAMETER Mode
Backup mode. Enum: snapshot,suspend,stop
.PARAMETER Node
Only run if executed on this node.
.PARAMETER NotesTemplate
Template string for generating notes for the backup(s). It can contain variables which will be replaced by their values. Currently supported are {{cluster}}, {{guestname}}, {{node}}, and {{vmid}}, but more might be added in the future. Needs to be a single line, newline and backslash need to be escaped as '\n' and '\\' respectively.
.PARAMETER NotificationPolicy
Specify when to send a notification Enum: always,failure,never
.PARAMETER NotificationTarget
Determine the target to which notifications should be sent. Can either be a notification endpoint or a notification group. This option takes precedence over 'mailto', meaning that if both are  set, the 'mailto' option will be ignored.
.PARAMETER Performance
Other performance-related settings.
.PARAMETER Pigz
Use pigz instead of gzip when N>0. N=1 uses half of cores, N>1 uses N as thread count.
.PARAMETER Pool
Backup all known guest systems included in the specified pool.
.PARAMETER Protected
If true, mark backup(s) as protected.
.PARAMETER PruneBackups
Use these retention options instead of those from the storage configuration.
.PARAMETER Quiet
Be quiet.
.PARAMETER Remove
Prune older backups according to 'prune-backups'.
.PARAMETER RepeatMissed
If true, the job will be run as soon as possible if it was missed while the scheduler was not running.
.PARAMETER Schedule
Backup schedule. The format is a subset of `systemd` calendar events.
.PARAMETER Script
Use specified hook script.
.PARAMETER Starttime
Job Start time.
.PARAMETER Stdexcludes
Exclude temporary files and logs.
.PARAMETER Stop
Stop running backup jobs on this host.
.PARAMETER Stopwait
Maximal time to wait until a guest system is stopped (minutes).
.PARAMETER Storage
Store resulting file to this storage.
.PARAMETER Tmpdir
Store temporary files to specified directory.
.PARAMETER Vmid
The ID of the guest system you want to backup.
.PARAMETER Zstd
Zstd threads. N=0 uses half of the available cores, N>0 uses N as thread count.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$All,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('0','1','gzip','lzo','zstd')]
        [string]$Compress,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dow,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dumpdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enabled,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Exclude,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$ExcludePath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Ionice,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Lockwait,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('always','failure')]
        [string]$Mailnotification,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mailto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Maxfiles,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('snapshot','suspend','stop')]
        [string]$Mode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$NotesTemplate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('always','failure','never')]
        [string]$NotificationPolicy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$NotificationTarget,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Performance,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pigz,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Pool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Protected,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PruneBackups,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Quiet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Remove,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$RepeatMissed,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Schedule,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Script,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Starttime,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Stdexcludes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Stop,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Stopwait,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tmpdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Zstd
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['All']) { $parameters['all'] = $All }
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Compress']) { $parameters['compress'] = $Compress }
        if($PSBoundParameters['Dow']) { $parameters['dow'] = $Dow }
        if($PSBoundParameters['Dumpdir']) { $parameters['dumpdir'] = $Dumpdir }
        if($PSBoundParameters['Enabled']) { $parameters['enabled'] = $Enabled }
        if($PSBoundParameters['Exclude']) { $parameters['exclude'] = $Exclude }
        if($PSBoundParameters['ExcludePath']) { $parameters['exclude-path'] = $ExcludePath }
        if($PSBoundParameters['Id']) { $parameters['id'] = $Id }
        if($PSBoundParameters['Ionice']) { $parameters['ionice'] = $Ionice }
        if($PSBoundParameters['Lockwait']) { $parameters['lockwait'] = $Lockwait }
        if($PSBoundParameters['Mailnotification']) { $parameters['mailnotification'] = $Mailnotification }
        if($PSBoundParameters['Mailto']) { $parameters['mailto'] = $Mailto }
        if($PSBoundParameters['Maxfiles']) { $parameters['maxfiles'] = $Maxfiles }
        if($PSBoundParameters['Mode']) { $parameters['mode'] = $Mode }
        if($PSBoundParameters['Node']) { $parameters['node'] = $Node }
        if($PSBoundParameters['NotesTemplate']) { $parameters['notes-template'] = $NotesTemplate }
        if($PSBoundParameters['NotificationPolicy']) { $parameters['notification-policy'] = $NotificationPolicy }
        if($PSBoundParameters['NotificationTarget']) { $parameters['notification-target'] = $NotificationTarget }
        if($PSBoundParameters['Performance']) { $parameters['performance'] = $Performance }
        if($PSBoundParameters['Pigz']) { $parameters['pigz'] = $Pigz }
        if($PSBoundParameters['Pool']) { $parameters['pool'] = $Pool }
        if($PSBoundParameters['Protected']) { $parameters['protected'] = $Protected }
        if($PSBoundParameters['PruneBackups']) { $parameters['prune-backups'] = $PruneBackups }
        if($PSBoundParameters['Quiet']) { $parameters['quiet'] = $Quiet }
        if($PSBoundParameters['Remove']) { $parameters['remove'] = $Remove }
        if($PSBoundParameters['RepeatMissed']) { $parameters['repeat-missed'] = $RepeatMissed }
        if($PSBoundParameters['Schedule']) { $parameters['schedule'] = $Schedule }
        if($PSBoundParameters['Script']) { $parameters['script'] = $Script }
        if($PSBoundParameters['Starttime']) { $parameters['starttime'] = $Starttime }
        if($PSBoundParameters['Stdexcludes']) { $parameters['stdexcludes'] = $Stdexcludes }
        if($PSBoundParameters['Stop']) { $parameters['stop'] = $Stop }
        if($PSBoundParameters['Stopwait']) { $parameters['stopwait'] = $Stopwait }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Tmpdir']) { $parameters['tmpdir'] = $Tmpdir }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }
        if($PSBoundParameters['Zstd']) { $parameters['zstd'] = $Zstd }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/backup" -Parameters $parameters
    }
}

function Remove-PveClusterBackup
{
<#
.DESCRIPTION
Delete vzdump backup job definition.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
The job ID.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/backup/$Id"
    }
}

function Get-PveClusterBackupIdx
{
<#
.DESCRIPTION
Read vzdump backup job definition.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
The job ID.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/backup/$Id"
    }
}

function Set-PveClusterBackup
{
<#
.DESCRIPTION
Update vzdump backup job definition.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER All
Backup all known guest systems on this host.
.PARAMETER Bwlimit
Limit I/O bandwidth (in KiB/s).
.PARAMETER Comment
Description for the Job.
.PARAMETER Compress
Compress dump file. Enum: 0,1,gzip,lzo,zstd
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Dow
Day of week selection.
.PARAMETER Dumpdir
Store resulting files to specified directory.
.PARAMETER Enabled
Enable or disable the job.
.PARAMETER Exclude
Exclude specified guest systems (assumes --all)
.PARAMETER ExcludePath
Exclude certain files/directories (shell globs). Paths starting with '/' are anchored to the container's root,  other paths match relative to each subdirectory.
.PARAMETER Id
The job ID.
.PARAMETER Ionice
Set IO priority when using the BFQ scheduler. For snapshot and suspend mode backups of VMs, this only affects the compressor. A value of 8 means the idle priority is used, otherwise the best-effort priority is used with the specified value.
.PARAMETER Lockwait
Maximal time to wait for the global lock (minutes).
.PARAMETER Mailnotification
Deprecated':' use 'notification-policy' instead. Enum: always,failure
.PARAMETER Mailto
Comma-separated list of email addresses or users that should receive email notifications. Has no effect if the 'notification-target' option  is set at the same time.
.PARAMETER Maxfiles
Deprecated':' use 'prune-backups' instead. Maximal number of backup files per guest system.
.PARAMETER Mode
Backup mode. Enum: snapshot,suspend,stop
.PARAMETER Node
Only run if executed on this node.
.PARAMETER NotesTemplate
Template string for generating notes for the backup(s). It can contain variables which will be replaced by their values. Currently supported are {{cluster}}, {{guestname}}, {{node}}, and {{vmid}}, but more might be added in the future. Needs to be a single line, newline and backslash need to be escaped as '\n' and '\\' respectively.
.PARAMETER NotificationPolicy
Specify when to send a notification Enum: always,failure,never
.PARAMETER NotificationTarget
Determine the target to which notifications should be sent. Can either be a notification endpoint or a notification group. This option takes precedence over 'mailto', meaning that if both are  set, the 'mailto' option will be ignored.
.PARAMETER Performance
Other performance-related settings.
.PARAMETER Pigz
Use pigz instead of gzip when N>0. N=1 uses half of cores, N>1 uses N as thread count.
.PARAMETER Pool
Backup all known guest systems included in the specified pool.
.PARAMETER Protected
If true, mark backup(s) as protected.
.PARAMETER PruneBackups
Use these retention options instead of those from the storage configuration.
.PARAMETER Quiet
Be quiet.
.PARAMETER Remove
Prune older backups according to 'prune-backups'.
.PARAMETER RepeatMissed
If true, the job will be run as soon as possible if it was missed while the scheduler was not running.
.PARAMETER Schedule
Backup schedule. The format is a subset of `systemd` calendar events.
.PARAMETER Script
Use specified hook script.
.PARAMETER Starttime
Job Start time.
.PARAMETER Stdexcludes
Exclude temporary files and logs.
.PARAMETER Stop
Stop running backup jobs on this host.
.PARAMETER Stopwait
Maximal time to wait until a guest system is stopped (minutes).
.PARAMETER Storage
Store resulting file to this storage.
.PARAMETER Tmpdir
Store temporary files to specified directory.
.PARAMETER Vmid
The ID of the guest system you want to backup.
.PARAMETER Zstd
Zstd threads. N=0 uses half of the available cores, N>0 uses N as thread count.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$All,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('0','1','gzip','lzo','zstd')]
        [string]$Compress,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dow,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dumpdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enabled,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Exclude,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$ExcludePath,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Ionice,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Lockwait,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('always','failure')]
        [string]$Mailnotification,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mailto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Maxfiles,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('snapshot','suspend','stop')]
        [string]$Mode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$NotesTemplate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('always','failure','never')]
        [string]$NotificationPolicy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$NotificationTarget,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Performance,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pigz,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Pool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Protected,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PruneBackups,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Quiet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Remove,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$RepeatMissed,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Schedule,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Script,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Starttime,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Stdexcludes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Stop,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Stopwait,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tmpdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Zstd
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['All']) { $parameters['all'] = $All }
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Compress']) { $parameters['compress'] = $Compress }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Dow']) { $parameters['dow'] = $Dow }
        if($PSBoundParameters['Dumpdir']) { $parameters['dumpdir'] = $Dumpdir }
        if($PSBoundParameters['Enabled']) { $parameters['enabled'] = $Enabled }
        if($PSBoundParameters['Exclude']) { $parameters['exclude'] = $Exclude }
        if($PSBoundParameters['ExcludePath']) { $parameters['exclude-path'] = $ExcludePath }
        if($PSBoundParameters['Ionice']) { $parameters['ionice'] = $Ionice }
        if($PSBoundParameters['Lockwait']) { $parameters['lockwait'] = $Lockwait }
        if($PSBoundParameters['Mailnotification']) { $parameters['mailnotification'] = $Mailnotification }
        if($PSBoundParameters['Mailto']) { $parameters['mailto'] = $Mailto }
        if($PSBoundParameters['Maxfiles']) { $parameters['maxfiles'] = $Maxfiles }
        if($PSBoundParameters['Mode']) { $parameters['mode'] = $Mode }
        if($PSBoundParameters['Node']) { $parameters['node'] = $Node }
        if($PSBoundParameters['NotesTemplate']) { $parameters['notes-template'] = $NotesTemplate }
        if($PSBoundParameters['NotificationPolicy']) { $parameters['notification-policy'] = $NotificationPolicy }
        if($PSBoundParameters['NotificationTarget']) { $parameters['notification-target'] = $NotificationTarget }
        if($PSBoundParameters['Performance']) { $parameters['performance'] = $Performance }
        if($PSBoundParameters['Pigz']) { $parameters['pigz'] = $Pigz }
        if($PSBoundParameters['Pool']) { $parameters['pool'] = $Pool }
        if($PSBoundParameters['Protected']) { $parameters['protected'] = $Protected }
        if($PSBoundParameters['PruneBackups']) { $parameters['prune-backups'] = $PruneBackups }
        if($PSBoundParameters['Quiet']) { $parameters['quiet'] = $Quiet }
        if($PSBoundParameters['Remove']) { $parameters['remove'] = $Remove }
        if($PSBoundParameters['RepeatMissed']) { $parameters['repeat-missed'] = $RepeatMissed }
        if($PSBoundParameters['Schedule']) { $parameters['schedule'] = $Schedule }
        if($PSBoundParameters['Script']) { $parameters['script'] = $Script }
        if($PSBoundParameters['Starttime']) { $parameters['starttime'] = $Starttime }
        if($PSBoundParameters['Stdexcludes']) { $parameters['stdexcludes'] = $Stdexcludes }
        if($PSBoundParameters['Stop']) { $parameters['stop'] = $Stop }
        if($PSBoundParameters['Stopwait']) { $parameters['stopwait'] = $Stopwait }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Tmpdir']) { $parameters['tmpdir'] = $Tmpdir }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }
        if($PSBoundParameters['Zstd']) { $parameters['zstd'] = $Zstd }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/backup/$Id" -Parameters $parameters
    }
}

function Get-PveClusterBackupIncludedVolumes
{
<#
.DESCRIPTION
Returns included guests and the backup status of their disks. Optimized to be used in ExtJS tree views.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
The job ID.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/backup/$Id/included_volumes"
    }
}

function Get-PveClusterBackupInfo
{
<#
.DESCRIPTION
Index for backup info related endpoints
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/backup-info"
    }
}

function Get-PveClusterBackupInfoNotBackedUp
{
<#
.DESCRIPTION
Shows all guests which are not covered by any backup job.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/backup-info/not-backed-up"
    }
}

function Get-PveClusterHa
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ha"
    }
}

function Get-PveClusterHaResources
{
<#
.DESCRIPTION
List HA resources.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Type
Only list resources of specific type Enum: ct,vm
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ct','vm')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ha/resources" -Parameters $parameters
    }
}

function New-PveClusterHaResources
{
<#
.DESCRIPTION
Create a new HA resource.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Description.
.PARAMETER Group
The HA group identifier.
.PARAMETER MaxRelocate
Maximal number of service relocate tries when a service failes to start.
.PARAMETER MaxRestart
Maximal number of tries to restart the service on a node after its start failed.
.PARAMETER Sid
HA resource ID. This consists of a resource type followed by a resource specific name, separated with colon (example':' vm':'100 / ct':'100). For virtual machines and containers, you can simply use the VM or CT id as a shortcut (example':' 100).
.PARAMETER State
Requested resource state. Enum: started,stopped,enabled,disabled,ignored
.PARAMETER Type
Resource type. Enum: ct,vm
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Group,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MaxRelocate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MaxRestart,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Sid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('started','stopped','enabled','disabled','ignored')]
        [string]$State,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ct','vm')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Group']) { $parameters['group'] = $Group }
        if($PSBoundParameters['MaxRelocate']) { $parameters['max_relocate'] = $MaxRelocate }
        if($PSBoundParameters['MaxRestart']) { $parameters['max_restart'] = $MaxRestart }
        if($PSBoundParameters['Sid']) { $parameters['sid'] = $Sid }
        if($PSBoundParameters['State']) { $parameters['state'] = $State }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/ha/resources" -Parameters $parameters
    }
}

function Remove-PveClusterHaResources
{
<#
.DESCRIPTION
Delete resource configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Sid
HA resource ID. This consists of a resource type followed by a resource specific name, separated with colon (example':' vm':'100 / ct':'100). For virtual machines and containers, you can simply use the VM or CT id as a shortcut (example':' 100).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Sid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/ha/resources/$Sid"
    }
}

function Get-PveClusterHaResourcesIdx
{
<#
.DESCRIPTION
Read resource configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Sid
HA resource ID. This consists of a resource type followed by a resource specific name, separated with colon (example':' vm':'100 / ct':'100). For virtual machines and containers, you can simply use the VM or CT id as a shortcut (example':' 100).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Sid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ha/resources/$Sid"
    }
}

function Set-PveClusterHaResources
{
<#
.DESCRIPTION
Update resource configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Description.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Group
The HA group identifier.
.PARAMETER MaxRelocate
Maximal number of service relocate tries when a service failes to start.
.PARAMETER MaxRestart
Maximal number of tries to restart the service on a node after its start failed.
.PARAMETER Sid
HA resource ID. This consists of a resource type followed by a resource specific name, separated with colon (example':' vm':'100 / ct':'100). For virtual machines and containers, you can simply use the VM or CT id as a shortcut (example':' 100).
.PARAMETER State
Requested resource state. Enum: started,stopped,enabled,disabled,ignored
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Group,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MaxRelocate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MaxRestart,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Sid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('started','stopped','enabled','disabled','ignored')]
        [string]$State
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Group']) { $parameters['group'] = $Group }
        if($PSBoundParameters['MaxRelocate']) { $parameters['max_relocate'] = $MaxRelocate }
        if($PSBoundParameters['MaxRestart']) { $parameters['max_restart'] = $MaxRestart }
        if($PSBoundParameters['State']) { $parameters['state'] = $State }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/ha/resources/$Sid" -Parameters $parameters
    }
}

function New-PveClusterHaResourcesMigrate
{
<#
.DESCRIPTION
Request resource migration (online) to another node.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
Target node.
.PARAMETER Sid
HA resource ID. This consists of a resource type followed by a resource specific name, separated with colon (example':' vm':'100 / ct':'100). For virtual machines and containers, you can simply use the VM or CT id as a shortcut (example':' 100).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Sid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Node']) { $parameters['node'] = $Node }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/ha/resources/$Sid/migrate" -Parameters $parameters
    }
}

function New-PveClusterHaResourcesRelocate
{
<#
.DESCRIPTION
Request resource relocatzion to another node. This stops the service on the old node, and restarts it on the target node.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
Target node.
.PARAMETER Sid
HA resource ID. This consists of a resource type followed by a resource specific name, separated with colon (example':' vm':'100 / ct':'100). For virtual machines and containers, you can simply use the VM or CT id as a shortcut (example':' 100).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Sid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Node']) { $parameters['node'] = $Node }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/ha/resources/$Sid/relocate" -Parameters $parameters
    }
}

function Get-PveClusterHaGroups
{
<#
.DESCRIPTION
Get HA groups.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ha/groups"
    }
}

function New-PveClusterHaGroups
{
<#
.DESCRIPTION
Create a new HA group.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Description.
.PARAMETER Group
The HA group identifier.
.PARAMETER Nodes
List of cluster node names with optional priority.
.PARAMETER Nofailback
The CRM tries to run services on the node with the highest priority. If a node with higher priority comes online, the CRM migrates the service to that node. Enabling nofailback prevents that behavior.
.PARAMETER Restricted
Resources bound to restricted groups may only run on nodes defined by the group.
.PARAMETER Type
Group type. Enum: group
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Nodes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nofailback,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Restricted,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('group')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Group']) { $parameters['group'] = $Group }
        if($PSBoundParameters['Nodes']) { $parameters['nodes'] = $Nodes }
        if($PSBoundParameters['Nofailback']) { $parameters['nofailback'] = $Nofailback }
        if($PSBoundParameters['Restricted']) { $parameters['restricted'] = $Restricted }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/ha/groups" -Parameters $parameters
    }
}

function Remove-PveClusterHaGroups
{
<#
.DESCRIPTION
Delete ha group configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Group
The HA group identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/ha/groups/$Group"
    }
}

function Get-PveClusterHaGroupsIdx
{
<#
.DESCRIPTION
Read ha group configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Group
The HA group identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ha/groups/$Group"
    }
}

function Set-PveClusterHaGroups
{
<#
.DESCRIPTION
Update ha group configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Description.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Group
The HA group identifier.
.PARAMETER Nodes
List of cluster node names with optional priority.
.PARAMETER Nofailback
The CRM tries to run services on the node with the highest priority. If a node with higher priority comes online, the CRM migrates the service to that node. Enabling nofailback prevents that behavior.
.PARAMETER Restricted
Resources bound to restricted groups may only run on nodes defined by the group.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Group,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nodes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nofailback,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Restricted
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Nodes']) { $parameters['nodes'] = $Nodes }
        if($PSBoundParameters['Nofailback']) { $parameters['nofailback'] = $Nofailback }
        if($PSBoundParameters['Restricted']) { $parameters['restricted'] = $Restricted }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/ha/groups/$Group" -Parameters $parameters
    }
}

function Get-PveClusterHaStatus
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ha/status"
    }
}

function Get-PveClusterHaStatusCurrent
{
<#
.DESCRIPTION
Get HA manger status.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ha/status/current"
    }
}

function Get-PveClusterHaStatusManagerStatus
{
<#
.DESCRIPTION
Get full HA manger status, including LRM status.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ha/status/manager_status"
    }
}

function Get-PveClusterAcme
{
<#
.DESCRIPTION
ACMEAccount index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/acme"
    }
}

function Get-PveClusterAcmePlugins
{
<#
.DESCRIPTION
ACME plugin index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Type
Only list ACME plugins of a specific type Enum: dns,standalone
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('dns','standalone')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/acme/plugins" -Parameters $parameters
    }
}

function New-PveClusterAcmePlugins
{
<#
.DESCRIPTION
Add ACME plugin configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Api
API plugin name Enum: 1984hosting,acmedns,acmeproxy,active24,ad,ali,anx,artfiles,arvan,aurora,autodns,aws,azion,azure,bookmyname,bunny,cf,clouddns,cloudns,cn,conoha,constellix,cpanel,curanet,cyon,da,ddnss,desec,df,dgon,dnsexit,dnshome,dnsimple,dnsservices,do,doapi,domeneshop,dp,dpi,dreamhost,duckdns,durabledns,dyn,dynu,dynv6,easydns,edgedns,euserv,exoscale,fornex,freedns,gandi_livedns,gcloud,gcore,gd,geoscaling,googledomains,he,hetzner,hexonet,hostingde,huaweicloud,infoblox,infomaniak,internetbs,inwx,ionos,ipv64,ispconfig,jd,joker,kappernet,kas,kinghost,knot,la,leaseweb,lexicon,linode,linode_v4,loopia,lua,maradns,me,miab,misaka,myapi,mydevil,mydnsjp,mythic_beasts,namecheap,namecom,namesilo,nanelo,nederhost,neodigit,netcup,netlify,nic,njalla,nm,nsd,nsone,nsupdate,nw,oci,one,online,openprovider,openstack,opnsense,ovh,pdns,pleskxml,pointhq,porkbun,rackcorp,rackspace,rage4,rcode0,regru,scaleway,schlundtech,selectel,selfhost,servercow,simply,tele3,tencent,transip,udr,ultra,unoeuro,variomedia,veesp,vercel,vscale,vultr,websupport,world4you,yandex,yc,zilore,zone,zonomi
.PARAMETER Data
DNS plugin data. (base64 encoded)
.PARAMETER Disable
Flag to disable the config.
.PARAMETER Id
ACME Plugin ID name
.PARAMETER Nodes
List of cluster node names.
.PARAMETER Type
ACME challenge type. Enum: dns,standalone
.PARAMETER ValidationDelay
Extra delay in seconds to wait before requesting validation. Allows to cope with a long TTL of DNS records.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('1984hosting','acmedns','acmeproxy','active24','ad','ali','anx','artfiles','arvan','aurora','autodns','aws','azion','azure','bookmyname','bunny','cf','clouddns','cloudns','cn','conoha','constellix','cpanel','curanet','cyon','da','ddnss','desec','df','dgon','dnsexit','dnshome','dnsimple','dnsservices','do','doapi','domeneshop','dp','dpi','dreamhost','duckdns','durabledns','dyn','dynu','dynv6','easydns','edgedns','euserv','exoscale','fornex','freedns','gandi_livedns','gcloud','gcore','gd','geoscaling','googledomains','he','hetzner','hexonet','hostingde','huaweicloud','infoblox','infomaniak','internetbs','inwx','ionos','ipv64','ispconfig','jd','joker','kappernet','kas','kinghost','knot','la','leaseweb','lexicon','linode','linode_v4','loopia','lua','maradns','me','miab','misaka','myapi','mydevil','mydnsjp','mythic_beasts','namecheap','namecom','namesilo','nanelo','nederhost','neodigit','netcup','netlify','nic','njalla','nm','nsd','nsone','nsupdate','nw','oci','one','online','openprovider','openstack','opnsense','ovh','pdns','pleskxml','pointhq','porkbun','rackcorp','rackspace','rage4','rcode0','regru','scaleway','schlundtech','selectel','selfhost','servercow','simply','tele3','tencent','transip','udr','ultra','unoeuro','variomedia','veesp','vercel','vscale','vultr','websupport','world4you','yandex','yc','zilore','zone','zonomi')]
        [string]$Api,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Data,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nodes,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('dns','standalone')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$ValidationDelay
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Api']) { $parameters['api'] = $Api }
        if($PSBoundParameters['Data']) { $parameters['data'] = $Data }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Id']) { $parameters['id'] = $Id }
        if($PSBoundParameters['Nodes']) { $parameters['nodes'] = $Nodes }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['ValidationDelay']) { $parameters['validation-delay'] = $ValidationDelay }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/acme/plugins" -Parameters $parameters
    }
}

function Remove-PveClusterAcmePlugins
{
<#
.DESCRIPTION
Delete ACME plugin configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
Unique identifier for ACME plugin instance.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/acme/plugins/$Id"
    }
}

function Get-PveClusterAcmePluginsIdx
{
<#
.DESCRIPTION
Get ACME plugin configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
Unique identifier for ACME plugin instance.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/acme/plugins/$Id"
    }
}

function Set-PveClusterAcmePlugins
{
<#
.DESCRIPTION
Update ACME plugin configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Api
API plugin name Enum: 1984hosting,acmedns,acmeproxy,active24,ad,ali,anx,artfiles,arvan,aurora,autodns,aws,azion,azure,bookmyname,bunny,cf,clouddns,cloudns,cn,conoha,constellix,cpanel,curanet,cyon,da,ddnss,desec,df,dgon,dnsexit,dnshome,dnsimple,dnsservices,do,doapi,domeneshop,dp,dpi,dreamhost,duckdns,durabledns,dyn,dynu,dynv6,easydns,edgedns,euserv,exoscale,fornex,freedns,gandi_livedns,gcloud,gcore,gd,geoscaling,googledomains,he,hetzner,hexonet,hostingde,huaweicloud,infoblox,infomaniak,internetbs,inwx,ionos,ipv64,ispconfig,jd,joker,kappernet,kas,kinghost,knot,la,leaseweb,lexicon,linode,linode_v4,loopia,lua,maradns,me,miab,misaka,myapi,mydevil,mydnsjp,mythic_beasts,namecheap,namecom,namesilo,nanelo,nederhost,neodigit,netcup,netlify,nic,njalla,nm,nsd,nsone,nsupdate,nw,oci,one,online,openprovider,openstack,opnsense,ovh,pdns,pleskxml,pointhq,porkbun,rackcorp,rackspace,rage4,rcode0,regru,scaleway,schlundtech,selectel,selfhost,servercow,simply,tele3,tencent,transip,udr,ultra,unoeuro,variomedia,veesp,vercel,vscale,vultr,websupport,world4you,yandex,yc,zilore,zone,zonomi
.PARAMETER Data
DNS plugin data. (base64 encoded)
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Disable
Flag to disable the config.
.PARAMETER Id
ACME Plugin ID name
.PARAMETER Nodes
List of cluster node names.
.PARAMETER ValidationDelay
Extra delay in seconds to wait before requesting validation. Allows to cope with a long TTL of DNS records.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('1984hosting','acmedns','acmeproxy','active24','ad','ali','anx','artfiles','arvan','aurora','autodns','aws','azion','azure','bookmyname','bunny','cf','clouddns','cloudns','cn','conoha','constellix','cpanel','curanet','cyon','da','ddnss','desec','df','dgon','dnsexit','dnshome','dnsimple','dnsservices','do','doapi','domeneshop','dp','dpi','dreamhost','duckdns','durabledns','dyn','dynu','dynv6','easydns','edgedns','euserv','exoscale','fornex','freedns','gandi_livedns','gcloud','gcore','gd','geoscaling','googledomains','he','hetzner','hexonet','hostingde','huaweicloud','infoblox','infomaniak','internetbs','inwx','ionos','ipv64','ispconfig','jd','joker','kappernet','kas','kinghost','knot','la','leaseweb','lexicon','linode','linode_v4','loopia','lua','maradns','me','miab','misaka','myapi','mydevil','mydnsjp','mythic_beasts','namecheap','namecom','namesilo','nanelo','nederhost','neodigit','netcup','netlify','nic','njalla','nm','nsd','nsone','nsupdate','nw','oci','one','online','openprovider','openstack','opnsense','ovh','pdns','pleskxml','pointhq','porkbun','rackcorp','rackspace','rage4','rcode0','regru','scaleway','schlundtech','selectel','selfhost','servercow','simply','tele3','tencent','transip','udr','ultra','unoeuro','variomedia','veesp','vercel','vscale','vultr','websupport','world4you','yandex','yc','zilore','zone','zonomi')]
        [string]$Api,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Data,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nodes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$ValidationDelay
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Api']) { $parameters['api'] = $Api }
        if($PSBoundParameters['Data']) { $parameters['data'] = $Data }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Nodes']) { $parameters['nodes'] = $Nodes }
        if($PSBoundParameters['ValidationDelay']) { $parameters['validation-delay'] = $ValidationDelay }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/acme/plugins/$Id" -Parameters $parameters
    }
}

function Get-PveClusterAcmeAccount
{
<#
.DESCRIPTION
ACMEAccount index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/acme/account"
    }
}

function New-PveClusterAcmeAccount
{
<#
.DESCRIPTION
Register a new ACME account with CA.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Contact
Contact email addresses.
.PARAMETER Directory
URL of ACME CA directory endpoint.
.PARAMETER EabHmacKey
HMAC key for External Account Binding.
.PARAMETER EabKid
Key Identifier for External Account Binding.
.PARAMETER Name
ACME account config file name.
.PARAMETER TosUrl
URL of CA TermsOfService - setting this indicates agreement.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Contact,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Directory,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$EabHmacKey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$EabKid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$TosUrl
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Contact']) { $parameters['contact'] = $Contact }
        if($PSBoundParameters['Directory']) { $parameters['directory'] = $Directory }
        if($PSBoundParameters['EabHmacKey']) { $parameters['eab-hmac-key'] = $EabHmacKey }
        if($PSBoundParameters['EabKid']) { $parameters['eab-kid'] = $EabKid }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['TosUrl']) { $parameters['tos_url'] = $TosUrl }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/acme/account" -Parameters $parameters
    }
}

function Remove-PveClusterAcmeAccount
{
<#
.DESCRIPTION
Deactivate existing ACME account at CA.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
ACME account config file name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/acme/account/$Name"
    }
}

function Get-PveClusterAcmeAccountIdx
{
<#
.DESCRIPTION
Return existing ACME account information.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
ACME account config file name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/acme/account/$Name"
    }
}

function Set-PveClusterAcmeAccount
{
<#
.DESCRIPTION
Update existing ACME account information with CA. Note':' not specifying any new account information triggers a refresh.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Contact
Contact email addresses.
.PARAMETER Name
ACME account config file name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Contact,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Contact']) { $parameters['contact'] = $Contact }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/acme/account/$Name" -Parameters $parameters
    }
}

function Get-PveClusterAcmeTos
{
<#
.DESCRIPTION
Retrieve ACME TermsOfService URL from CA. Deprecated, please use /cluster/acme/meta.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Directory
URL of ACME CA directory endpoint.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Directory
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Directory']) { $parameters['directory'] = $Directory }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/acme/tos" -Parameters $parameters
    }
}

function Get-PveClusterAcmeMeta
{
<#
.DESCRIPTION
Retrieve ACME Directory Meta Information
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Directory
URL of ACME CA directory endpoint.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Directory
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Directory']) { $parameters['directory'] = $Directory }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/acme/meta" -Parameters $parameters
    }
}

function Get-PveClusterAcmeDirectories
{
<#
.DESCRIPTION
Get named known ACME directory endpoints.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/acme/directories"
    }
}

function Get-PveClusterAcmeChallengeSchema
{
<#
.DESCRIPTION
Get schema of ACME challenge types.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/acme/challenge-schema"
    }
}

function Get-PveClusterCeph
{
<#
.DESCRIPTION
Cluster ceph index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ceph"
    }
}

function Get-PveClusterCephMetadata
{
<#
.DESCRIPTION
Get ceph metadata.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Scope
-- Enum: all,versions
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('all','versions')]
        [string]$Scope
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Scope']) { $parameters['scope'] = $Scope }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ceph/metadata" -Parameters $parameters
    }
}

function Get-PveClusterCephStatus
{
<#
.DESCRIPTION
Get ceph status.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ceph/status"
    }
}

function Get-PveClusterCephFlags
{
<#
.DESCRIPTION
get the status of all ceph flags
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ceph/flags"
    }
}

function Set-PveClusterCephFlags
{
<#
.DESCRIPTION
Set/Unset multiple ceph flags at once.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Nobackfill
Backfilling of PGs is suspended.
.PARAMETER NodeepScrub
Deep Scrubbing is disabled.
.PARAMETER Nodown
OSD failure reports are being ignored, such that the monitors will not mark OSDs down.
.PARAMETER Noin
OSDs that were previously marked out will not be marked back in when they start.
.PARAMETER Noout
OSDs will not automatically be marked out after the configured interval.
.PARAMETER Norebalance
Rebalancing of PGs is suspended.
.PARAMETER Norecover
Recovery of PGs is suspended.
.PARAMETER Noscrub
Scrubbing is disabled.
.PARAMETER Notieragent
Cache tiering activity is suspended.
.PARAMETER Noup
OSDs are not allowed to start.
.PARAMETER Pause
Pauses read and writes.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nobackfill,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$NodeepScrub,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nodown,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Noin,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Noout,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Norebalance,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Norecover,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Noscrub,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Notieragent,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Noup,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Pause
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Nobackfill']) { $parameters['nobackfill'] = $Nobackfill }
        if($PSBoundParameters['NodeepScrub']) { $parameters['nodeep-scrub'] = $NodeepScrub }
        if($PSBoundParameters['Nodown']) { $parameters['nodown'] = $Nodown }
        if($PSBoundParameters['Noin']) { $parameters['noin'] = $Noin }
        if($PSBoundParameters['Noout']) { $parameters['noout'] = $Noout }
        if($PSBoundParameters['Norebalance']) { $parameters['norebalance'] = $Norebalance }
        if($PSBoundParameters['Norecover']) { $parameters['norecover'] = $Norecover }
        if($PSBoundParameters['Noscrub']) { $parameters['noscrub'] = $Noscrub }
        if($PSBoundParameters['Notieragent']) { $parameters['notieragent'] = $Notieragent }
        if($PSBoundParameters['Noup']) { $parameters['noup'] = $Noup }
        if($PSBoundParameters['Pause']) { $parameters['pause'] = $Pause }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/ceph/flags" -Parameters $parameters
    }
}

function Get-PveClusterCephFlagsIdx
{
<#
.DESCRIPTION
Get the status of a specific ceph flag.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Flag
The name of the flag name to get. Enum: nobackfill,nodeep-scrub,nodown,noin,noout,norebalance,norecover,noscrub,notieragent,noup,pause
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('nobackfill','nodeep-scrub','nodown','noin','noout','norebalance','norecover','noscrub','notieragent','noup','pause')]
        [string]$Flag
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/ceph/flags/$Flag"
    }
}

function Set-PveClusterCephFlagsIdx
{
<#
.DESCRIPTION
Set or clear (unset) a specific ceph flag
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Flag
The ceph flag to update Enum: nobackfill,nodeep-scrub,nodown,noin,noout,norebalance,norecover,noscrub,notieragent,noup,pause
.PARAMETER Value
The new value of the flag
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('nobackfill','nodeep-scrub','nodown','noin','noout','norebalance','norecover','noscrub','notieragent','noup','pause')]
        [string]$Flag,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [switch]$Value
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Value']) { $parameters['value'] = $Value }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/ceph/flags/$Flag" -Parameters $parameters
    }
}

function Get-PveClusterJobs
{
<#
.DESCRIPTION
Index for jobs related endpoints.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/jobs"
    }
}

function Get-PveClusterJobsRealmSync
{
<#
.DESCRIPTION
List configured realm-sync-jobs.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/jobs/realm-sync"
    }
}

function Remove-PveClusterJobsRealmSync
{
<#
.DESCRIPTION
Delete realm-sync job definition.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/jobs/realm-sync/$Id"
    }
}

function Get-PveClusterJobsRealmSyncIdx
{
<#
.DESCRIPTION
Read realm-sync job definition.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/jobs/realm-sync/$Id"
    }
}

function New-PveClusterJobsRealmSync
{
<#
.DESCRIPTION
Create new realm-sync job.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Description for the Job.
.PARAMETER EnableNew
Enable newly synced users immediately.
.PARAMETER Enabled
Determines if the job is enabled.
.PARAMETER Id
The ID of the job.
.PARAMETER Realm
Authentication domain ID
.PARAMETER RemoveVanished
A semicolon-seperated list of things to remove when they or the user vanishes during a sync. The following values are possible':' 'entry' removes the user/group when not returned from the sync. 'properties' removes the set properties on existing user/group that do not appear in the source (even custom ones). 'acl' removes acls when the user/group is not returned from the sync. Instead of a list it also can be 'none' (the default).
.PARAMETER Schedule
Backup schedule. The format is a subset of `systemd` calendar events.
.PARAMETER Scope
Select what to sync. Enum: users,groups,both
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$EnableNew,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enabled,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Realm,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$RemoveVanished,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Schedule,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('users','groups','both')]
        [string]$Scope
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['EnableNew']) { $parameters['enable-new'] = $EnableNew }
        if($PSBoundParameters['Enabled']) { $parameters['enabled'] = $Enabled }
        if($PSBoundParameters['Realm']) { $parameters['realm'] = $Realm }
        if($PSBoundParameters['RemoveVanished']) { $parameters['remove-vanished'] = $RemoveVanished }
        if($PSBoundParameters['Schedule']) { $parameters['schedule'] = $Schedule }
        if($PSBoundParameters['Scope']) { $parameters['scope'] = $Scope }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/jobs/realm-sync/$Id" -Parameters $parameters
    }
}

function Set-PveClusterJobsRealmSync
{
<#
.DESCRIPTION
Update realm-sync job definition.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
Description for the Job.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER EnableNew
Enable newly synced users immediately.
.PARAMETER Enabled
Determines if the job is enabled.
.PARAMETER Id
The ID of the job.
.PARAMETER RemoveVanished
A semicolon-seperated list of things to remove when they or the user vanishes during a sync. The following values are possible':' 'entry' removes the user/group when not returned from the sync. 'properties' removes the set properties on existing user/group that do not appear in the source (even custom ones). 'acl' removes acls when the user/group is not returned from the sync. Instead of a list it also can be 'none' (the default).
.PARAMETER Schedule
Backup schedule. The format is a subset of `systemd` calendar events.
.PARAMETER Scope
Select what to sync. Enum: users,groups,both
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$EnableNew,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enabled,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$RemoveVanished,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Schedule,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('users','groups','both')]
        [string]$Scope
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['EnableNew']) { $parameters['enable-new'] = $EnableNew }
        if($PSBoundParameters['Enabled']) { $parameters['enabled'] = $Enabled }
        if($PSBoundParameters['RemoveVanished']) { $parameters['remove-vanished'] = $RemoveVanished }
        if($PSBoundParameters['Schedule']) { $parameters['schedule'] = $Schedule }
        if($PSBoundParameters['Scope']) { $parameters['scope'] = $Scope }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/jobs/realm-sync/$Id" -Parameters $parameters
    }
}

function Get-PveClusterJobsScheduleAnalyze
{
<#
.DESCRIPTION
Returns a list of future schedule runtimes.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Iterations
Number of event-iteration to simulate and return.
.PARAMETER Schedule
Job schedule. The format is a subset of `systemd` calendar events.
.PARAMETER Starttime
UNIX timestamp to start the calculation from. Defaults to the current time.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Iterations,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Schedule,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Starttime
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Iterations']) { $parameters['iterations'] = $Iterations }
        if($PSBoundParameters['Schedule']) { $parameters['schedule'] = $Schedule }
        if($PSBoundParameters['Starttime']) { $parameters['starttime'] = $Starttime }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/jobs/schedule-analyze" -Parameters $parameters
    }
}

function Get-PveClusterMapping
{
<#
.DESCRIPTION
List resource types.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/mapping"
    }
}

function Get-PveClusterMappingPci
{
<#
.DESCRIPTION
List PCI Hardware Mapping
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER CheckNode
If given, checks the configurations on the given node for correctness, and adds relevant diagnostics for the devices to the response.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$CheckNode
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['CheckNode']) { $parameters['check-node'] = $CheckNode }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/mapping/pci" -Parameters $parameters
    }
}

function New-PveClusterMappingPci
{
<#
.DESCRIPTION
Create a new hardware mapping.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Description
Description of the logical PCI device.
.PARAMETER Id
The ID of the logical PCI mapping.
.PARAMETER Map
A list of maps for the cluster nodes.
.PARAMETER Mdev
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [array]$Map,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Mdev
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Id']) { $parameters['id'] = $Id }
        if($PSBoundParameters['Map']) { $parameters['map'] = $Map }
        if($PSBoundParameters['Mdev']) { $parameters['mdev'] = $Mdev }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/mapping/pci" -Parameters $parameters
    }
}

function Remove-PveClusterMappingPci
{
<#
.DESCRIPTION
Remove Hardware Mapping.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/mapping/pci/$Id"
    }
}

function Get-PveClusterMappingPciIdx
{
<#
.DESCRIPTION
Get PCI Mapping.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/mapping/pci/$Id"
    }
}

function Set-PveClusterMappingPci
{
<#
.DESCRIPTION
Update a hardware mapping.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Description
Description of the logical PCI device.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Id
The ID of the logical PCI mapping.
.PARAMETER Map
A list of maps for the cluster nodes.
.PARAMETER Mdev
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$Map,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Mdev
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Map']) { $parameters['map'] = $Map }
        if($PSBoundParameters['Mdev']) { $parameters['mdev'] = $Mdev }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/mapping/pci/$Id" -Parameters $parameters
    }
}

function Get-PveClusterMappingUsb
{
<#
.DESCRIPTION
List USB Hardware Mappings
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER CheckNode
If given, checks the configurations on the given node for correctness, and adds relevant errors to the devices.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$CheckNode
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['CheckNode']) { $parameters['check-node'] = $CheckNode }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/mapping/usb" -Parameters $parameters
    }
}

function New-PveClusterMappingUsb
{
<#
.DESCRIPTION
Create a new hardware mapping.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Description
Description of the logical USB device.
.PARAMETER Id
The ID of the logical USB mapping.
.PARAMETER Map
A list of maps for the cluster nodes.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [array]$Map
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Id']) { $parameters['id'] = $Id }
        if($PSBoundParameters['Map']) { $parameters['map'] = $Map }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/mapping/usb" -Parameters $parameters
    }
}

function Remove-PveClusterMappingUsb
{
<#
.DESCRIPTION
Remove Hardware Mapping.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/mapping/usb/$Id"
    }
}

function Get-PveClusterMappingUsbIdx
{
<#
.DESCRIPTION
Get USB Mapping.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/mapping/usb/$Id"
    }
}

function Set-PveClusterMappingUsb
{
<#
.DESCRIPTION
Update a hardware mapping.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Description
Description of the logical USB device.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Id
The ID of the logical USB mapping.
.PARAMETER Map
A list of maps for the cluster nodes.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [array]$Map
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Map']) { $parameters['map'] = $Map }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/mapping/usb/$Id" -Parameters $parameters
    }
}

function Get-PveClusterSdn
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn"
    }
}

function Set-PveClusterSdn
{
<#
.DESCRIPTION
Apply sdn controller changes && reload.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/sdn"
    }
}

function Get-PveClusterSdnVnets
{
<#
.DESCRIPTION
SDN vnets index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Pending
Display pending config.
.PARAMETER Running
Display running config.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Pending,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Running
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Pending']) { $parameters['pending'] = $Pending }
        if($PSBoundParameters['Running']) { $parameters['running'] = $Running }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/vnets" -Parameters $parameters
    }
}

function New-PveClusterSdnVnets
{
<#
.DESCRIPTION
Create a new sdn vnet object.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Alias
alias name of the vnet
.PARAMETER Tag
vlan or vxlan id
.PARAMETER Type
Type Enum: vnet
.PARAMETER Vlanaware
Allow vm VLANs to pass through this vnet.
.PARAMETER Vnet
The SDN vnet object identifier.
.PARAMETER Zone
zone id
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Alias,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Tag,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('vnet')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Vlanaware,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Alias']) { $parameters['alias'] = $Alias }
        if($PSBoundParameters['Tag']) { $parameters['tag'] = $Tag }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['Vlanaware']) { $parameters['vlanaware'] = $Vlanaware }
        if($PSBoundParameters['Vnet']) { $parameters['vnet'] = $Vnet }
        if($PSBoundParameters['Zone']) { $parameters['zone'] = $Zone }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/sdn/vnets" -Parameters $parameters
    }
}

function Remove-PveClusterSdnVnets
{
<#
.DESCRIPTION
Delete sdn vnet object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Vnet
The SDN vnet object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/sdn/vnets/$Vnet"
    }
}

function Get-PveClusterSdnVnetsIdx
{
<#
.DESCRIPTION
Read sdn vnet configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Pending
Display pending config.
.PARAMETER Running
Display running config.
.PARAMETER Vnet
The SDN vnet object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Pending,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Running,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Pending']) { $parameters['pending'] = $Pending }
        if($PSBoundParameters['Running']) { $parameters['running'] = $Running }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/vnets/$Vnet" -Parameters $parameters
    }
}

function Set-PveClusterSdnVnets
{
<#
.DESCRIPTION
Update sdn vnet object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Alias
alias name of the vnet
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Tag
vlan or vxlan id
.PARAMETER Vlanaware
Allow vm VLANs to pass through this vnet.
.PARAMETER Vnet
The SDN vnet object identifier.
.PARAMETER Zone
zone id
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Alias,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Tag,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Vlanaware,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Alias']) { $parameters['alias'] = $Alias }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Tag']) { $parameters['tag'] = $Tag }
        if($PSBoundParameters['Vlanaware']) { $parameters['vlanaware'] = $Vlanaware }
        if($PSBoundParameters['Zone']) { $parameters['zone'] = $Zone }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/sdn/vnets/$Vnet" -Parameters $parameters
    }
}

function Get-PveClusterSdnVnetsSubnets
{
<#
.DESCRIPTION
SDN subnets index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Pending
Display pending config.
.PARAMETER Running
Display running config.
.PARAMETER Vnet
The SDN vnet object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Pending,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Running,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Pending']) { $parameters['pending'] = $Pending }
        if($PSBoundParameters['Running']) { $parameters['running'] = $Running }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/vnets/$Vnet/subnets" -Parameters $parameters
    }
}

function New-PveClusterSdnVnetsSubnets
{
<#
.DESCRIPTION
Create a new sdn subnet object.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER DhcpDnsServer
IP address for the DNS server
.PARAMETER DhcpRange
A list of DHCP ranges for this subnet
.PARAMETER Dnszoneprefix
dns domain zone prefix  ex':' 'adm' -> <hostname>.adm.mydomain.com
.PARAMETER Gateway
Subnet Gateway':' Will be assign on vnet for layer3 zones
.PARAMETER Snat
enable masquerade for this subnet if pve-firewall
.PARAMETER Subnet
The SDN subnet object identifier.
.PARAMETER Type
-- Enum: subnet
.PARAMETER Vnet
associated vnet
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$DhcpDnsServer,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$DhcpRange,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dnszoneprefix,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Gateway,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Snat,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Subnet,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('subnet')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['DhcpDnsServer']) { $parameters['dhcp-dns-server'] = $DhcpDnsServer }
        if($PSBoundParameters['DhcpRange']) { $parameters['dhcp-range'] = $DhcpRange }
        if($PSBoundParameters['Dnszoneprefix']) { $parameters['dnszoneprefix'] = $Dnszoneprefix }
        if($PSBoundParameters['Gateway']) { $parameters['gateway'] = $Gateway }
        if($PSBoundParameters['Snat']) { $parameters['snat'] = $Snat }
        if($PSBoundParameters['Subnet']) { $parameters['subnet'] = $Subnet }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/sdn/vnets/$Vnet/subnets" -Parameters $parameters
    }
}

function Remove-PveClusterSdnVnetsSubnets
{
<#
.DESCRIPTION
Delete sdn subnet object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Subnet
The SDN subnet object identifier.
.PARAMETER Vnet
The SDN vnet object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Subnet,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/sdn/vnets/$Vnet/subnets/$Subnet"
    }
}

function Get-PveClusterSdnVnetsSubnetsIdx
{
<#
.DESCRIPTION
Read sdn subnet configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Pending
Display pending config.
.PARAMETER Running
Display running config.
.PARAMETER Subnet
The SDN subnet object identifier.
.PARAMETER Vnet
The SDN vnet object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Pending,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Running,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Subnet,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Pending']) { $parameters['pending'] = $Pending }
        if($PSBoundParameters['Running']) { $parameters['running'] = $Running }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/vnets/$Vnet/subnets/$Subnet" -Parameters $parameters
    }
}

function Set-PveClusterSdnVnetsSubnets
{
<#
.DESCRIPTION
Update sdn subnet object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER DhcpDnsServer
IP address for the DNS server
.PARAMETER DhcpRange
A list of DHCP ranges for this subnet
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dnszoneprefix
dns domain zone prefix  ex':' 'adm' -> <hostname>.adm.mydomain.com
.PARAMETER Gateway
Subnet Gateway':' Will be assign on vnet for layer3 zones
.PARAMETER Snat
enable masquerade for this subnet if pve-firewall
.PARAMETER Subnet
The SDN subnet object identifier.
.PARAMETER Vnet
associated vnet
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$DhcpDnsServer,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$DhcpRange,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dnszoneprefix,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Gateway,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Snat,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Subnet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vnet
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['DhcpDnsServer']) { $parameters['dhcp-dns-server'] = $DhcpDnsServer }
        if($PSBoundParameters['DhcpRange']) { $parameters['dhcp-range'] = $DhcpRange }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dnszoneprefix']) { $parameters['dnszoneprefix'] = $Dnszoneprefix }
        if($PSBoundParameters['Gateway']) { $parameters['gateway'] = $Gateway }
        if($PSBoundParameters['Snat']) { $parameters['snat'] = $Snat }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/sdn/vnets/$Vnet/subnets/$Subnet" -Parameters $parameters
    }
}

function Remove-PveClusterSdnVnetsIps
{
<#
.DESCRIPTION
Delete IP Mappings in a VNet
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Ip
The IP address to delete
.PARAMETER Mac
Unicast MAC address.
.PARAMETER Vnet
The SDN vnet object identifier.
.PARAMETER Zone
The SDN zone object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ip,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mac,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Ip']) { $parameters['ip'] = $Ip }
        if($PSBoundParameters['Mac']) { $parameters['mac'] = $Mac }
        if($PSBoundParameters['Zone']) { $parameters['zone'] = $Zone }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/sdn/vnets/$Vnet/ips" -Parameters $parameters
    }
}

function New-PveClusterSdnVnetsIps
{
<#
.DESCRIPTION
Create IP Mapping in a VNet
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Ip
The IP address to associate with the given MAC address
.PARAMETER Mac
Unicast MAC address.
.PARAMETER Vnet
The SDN vnet object identifier.
.PARAMETER Zone
The SDN zone object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ip,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mac,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Ip']) { $parameters['ip'] = $Ip }
        if($PSBoundParameters['Mac']) { $parameters['mac'] = $Mac }
        if($PSBoundParameters['Zone']) { $parameters['zone'] = $Zone }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/sdn/vnets/$Vnet/ips" -Parameters $parameters
    }
}

function Set-PveClusterSdnVnetsIps
{
<#
.DESCRIPTION
Update IP Mapping in a VNet
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Ip
The IP address to associate with the given MAC address
.PARAMETER Mac
Unicast MAC address.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Vnet
The SDN vnet object identifier.
.PARAMETER Zone
The SDN zone object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ip,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mac,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vnet,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Ip']) { $parameters['ip'] = $Ip }
        if($PSBoundParameters['Mac']) { $parameters['mac'] = $Mac }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }
        if($PSBoundParameters['Zone']) { $parameters['zone'] = $Zone }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/sdn/vnets/$Vnet/ips" -Parameters $parameters
    }
}

function Get-PveClusterSdnZones
{
<#
.DESCRIPTION
SDN zones index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Pending
Display pending config.
.PARAMETER Running
Display running config.
.PARAMETER Type
Only list SDN zones of specific type Enum: evpn,faucet,qinq,simple,vlan,vxlan
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Pending,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Running,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('evpn','faucet','qinq','simple','vlan','vxlan')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Pending']) { $parameters['pending'] = $Pending }
        if($PSBoundParameters['Running']) { $parameters['running'] = $Running }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/zones" -Parameters $parameters
    }
}

function New-PveClusterSdnZones
{
<#
.DESCRIPTION
Create a new sdn zone object.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AdvertiseSubnets
Advertise evpn subnets if you have silent hosts
.PARAMETER Bridge
--
.PARAMETER BridgeDisableMacLearning
Disable auto mac learning.
.PARAMETER Controller
Frr router name
.PARAMETER Dhcp
Type of the DHCP backend for this zone Enum: dnsmasq
.PARAMETER DisableArpNdSuppression
Disable ipv4 arp && ipv6 neighbour discovery suppression
.PARAMETER Dns
dns api server
.PARAMETER Dnszone
dns domain zone  ex':' mydomain.com
.PARAMETER DpId
Faucet dataplane id
.PARAMETER Exitnodes
List of cluster node names.
.PARAMETER ExitnodesLocalRouting
Allow exitnodes to connect to evpn guests
.PARAMETER ExitnodesPrimary
Force traffic to this exitnode first.
.PARAMETER Ipam
use a specific ipam
.PARAMETER Mac
Anycast logical router mac address
.PARAMETER Mtu
MTU
.PARAMETER Nodes
List of cluster node names.
.PARAMETER Peers
peers address list.
.PARAMETER Reversedns
reverse dns api server
.PARAMETER RtImport
Route-Target import
.PARAMETER Tag
Service-VLAN Tag
.PARAMETER Type
Plugin type. Enum: evpn,faucet,qinq,simple,vlan,vxlan
.PARAMETER VlanProtocol
-- Enum: 802.1q,802.1ad
.PARAMETER VrfVxlan
l3vni.
.PARAMETER VxlanPort
Vxlan tunnel udp port (default 4789).
.PARAMETER Zone
The SDN zone object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AdvertiseSubnets,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bridge,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$BridgeDisableMacLearning,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Controller,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('dnsmasq')]
        [string]$Dhcp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$DisableArpNdSuppression,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dns,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dnszone,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$DpId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Exitnodes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$ExitnodesLocalRouting,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ExitnodesPrimary,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Ipam,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mac,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Mtu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nodes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Peers,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Reversedns,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$RtImport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Tag,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('evpn','faucet','qinq','simple','vlan','vxlan')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('802.1q','802.1ad')]
        [string]$VlanProtocol,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$VrfVxlan,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$VxlanPort,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AdvertiseSubnets']) { $parameters['advertise-subnets'] = $AdvertiseSubnets }
        if($PSBoundParameters['Bridge']) { $parameters['bridge'] = $Bridge }
        if($PSBoundParameters['BridgeDisableMacLearning']) { $parameters['bridge-disable-mac-learning'] = $BridgeDisableMacLearning }
        if($PSBoundParameters['Controller']) { $parameters['controller'] = $Controller }
        if($PSBoundParameters['Dhcp']) { $parameters['dhcp'] = $Dhcp }
        if($PSBoundParameters['DisableArpNdSuppression']) { $parameters['disable-arp-nd-suppression'] = $DisableArpNdSuppression }
        if($PSBoundParameters['Dns']) { $parameters['dns'] = $Dns }
        if($PSBoundParameters['Dnszone']) { $parameters['dnszone'] = $Dnszone }
        if($PSBoundParameters['DpId']) { $parameters['dp-id'] = $DpId }
        if($PSBoundParameters['Exitnodes']) { $parameters['exitnodes'] = $Exitnodes }
        if($PSBoundParameters['ExitnodesLocalRouting']) { $parameters['exitnodes-local-routing'] = $ExitnodesLocalRouting }
        if($PSBoundParameters['ExitnodesPrimary']) { $parameters['exitnodes-primary'] = $ExitnodesPrimary }
        if($PSBoundParameters['Ipam']) { $parameters['ipam'] = $Ipam }
        if($PSBoundParameters['Mac']) { $parameters['mac'] = $Mac }
        if($PSBoundParameters['Mtu']) { $parameters['mtu'] = $Mtu }
        if($PSBoundParameters['Nodes']) { $parameters['nodes'] = $Nodes }
        if($PSBoundParameters['Peers']) { $parameters['peers'] = $Peers }
        if($PSBoundParameters['Reversedns']) { $parameters['reversedns'] = $Reversedns }
        if($PSBoundParameters['RtImport']) { $parameters['rt-import'] = $RtImport }
        if($PSBoundParameters['Tag']) { $parameters['tag'] = $Tag }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['VlanProtocol']) { $parameters['vlan-protocol'] = $VlanProtocol }
        if($PSBoundParameters['VrfVxlan']) { $parameters['vrf-vxlan'] = $VrfVxlan }
        if($PSBoundParameters['VxlanPort']) { $parameters['vxlan-port'] = $VxlanPort }
        if($PSBoundParameters['Zone']) { $parameters['zone'] = $Zone }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/sdn/zones" -Parameters $parameters
    }
}

function Remove-PveClusterSdnZones
{
<#
.DESCRIPTION
Delete sdn zone object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Zone
The SDN zone object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/sdn/zones/$Zone"
    }
}

function Get-PveClusterSdnZonesIdx
{
<#
.DESCRIPTION
Read sdn zone configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Pending
Display pending config.
.PARAMETER Running
Display running config.
.PARAMETER Zone
The SDN zone object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Pending,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Running,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Pending']) { $parameters['pending'] = $Pending }
        if($PSBoundParameters['Running']) { $parameters['running'] = $Running }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/zones/$Zone" -Parameters $parameters
    }
}

function Set-PveClusterSdnZones
{
<#
.DESCRIPTION
Update sdn zone object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AdvertiseSubnets
Advertise evpn subnets if you have silent hosts
.PARAMETER Bridge
--
.PARAMETER BridgeDisableMacLearning
Disable auto mac learning.
.PARAMETER Controller
Frr router name
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Dhcp
Type of the DHCP backend for this zone Enum: dnsmasq
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER DisableArpNdSuppression
Disable ipv4 arp && ipv6 neighbour discovery suppression
.PARAMETER Dns
dns api server
.PARAMETER Dnszone
dns domain zone  ex':' mydomain.com
.PARAMETER DpId
Faucet dataplane id
.PARAMETER Exitnodes
List of cluster node names.
.PARAMETER ExitnodesLocalRouting
Allow exitnodes to connect to evpn guests
.PARAMETER ExitnodesPrimary
Force traffic to this exitnode first.
.PARAMETER Ipam
use a specific ipam
.PARAMETER Mac
Anycast logical router mac address
.PARAMETER Mtu
MTU
.PARAMETER Nodes
List of cluster node names.
.PARAMETER Peers
peers address list.
.PARAMETER Reversedns
reverse dns api server
.PARAMETER RtImport
Route-Target import
.PARAMETER Tag
Service-VLAN Tag
.PARAMETER VlanProtocol
-- Enum: 802.1q,802.1ad
.PARAMETER VrfVxlan
l3vni.
.PARAMETER VxlanPort
Vxlan tunnel udp port (default 4789).
.PARAMETER Zone
The SDN zone object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AdvertiseSubnets,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bridge,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$BridgeDisableMacLearning,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Controller,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('dnsmasq')]
        [string]$Dhcp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$DisableArpNdSuppression,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dns,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dnszone,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$DpId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Exitnodes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$ExitnodesLocalRouting,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ExitnodesPrimary,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Ipam,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mac,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Mtu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nodes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Peers,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Reversedns,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$RtImport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Tag,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('802.1q','802.1ad')]
        [string]$VlanProtocol,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$VrfVxlan,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$VxlanPort,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AdvertiseSubnets']) { $parameters['advertise-subnets'] = $AdvertiseSubnets }
        if($PSBoundParameters['Bridge']) { $parameters['bridge'] = $Bridge }
        if($PSBoundParameters['BridgeDisableMacLearning']) { $parameters['bridge-disable-mac-learning'] = $BridgeDisableMacLearning }
        if($PSBoundParameters['Controller']) { $parameters['controller'] = $Controller }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Dhcp']) { $parameters['dhcp'] = $Dhcp }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['DisableArpNdSuppression']) { $parameters['disable-arp-nd-suppression'] = $DisableArpNdSuppression }
        if($PSBoundParameters['Dns']) { $parameters['dns'] = $Dns }
        if($PSBoundParameters['Dnszone']) { $parameters['dnszone'] = $Dnszone }
        if($PSBoundParameters['DpId']) { $parameters['dp-id'] = $DpId }
        if($PSBoundParameters['Exitnodes']) { $parameters['exitnodes'] = $Exitnodes }
        if($PSBoundParameters['ExitnodesLocalRouting']) { $parameters['exitnodes-local-routing'] = $ExitnodesLocalRouting }
        if($PSBoundParameters['ExitnodesPrimary']) { $parameters['exitnodes-primary'] = $ExitnodesPrimary }
        if($PSBoundParameters['Ipam']) { $parameters['ipam'] = $Ipam }
        if($PSBoundParameters['Mac']) { $parameters['mac'] = $Mac }
        if($PSBoundParameters['Mtu']) { $parameters['mtu'] = $Mtu }
        if($PSBoundParameters['Nodes']) { $parameters['nodes'] = $Nodes }
        if($PSBoundParameters['Peers']) { $parameters['peers'] = $Peers }
        if($PSBoundParameters['Reversedns']) { $parameters['reversedns'] = $Reversedns }
        if($PSBoundParameters['RtImport']) { $parameters['rt-import'] = $RtImport }
        if($PSBoundParameters['Tag']) { $parameters['tag'] = $Tag }
        if($PSBoundParameters['VlanProtocol']) { $parameters['vlan-protocol'] = $VlanProtocol }
        if($PSBoundParameters['VrfVxlan']) { $parameters['vrf-vxlan'] = $VrfVxlan }
        if($PSBoundParameters['VxlanPort']) { $parameters['vxlan-port'] = $VxlanPort }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/sdn/zones/$Zone" -Parameters $parameters
    }
}

function Get-PveClusterSdnControllers
{
<#
.DESCRIPTION
SDN controllers index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Pending
Display pending config.
.PARAMETER Running
Display running config.
.PARAMETER Type
Only list sdn controllers of specific type Enum: bgp,evpn,faucet,isis
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Pending,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Running,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('bgp','evpn','faucet','isis')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Pending']) { $parameters['pending'] = $Pending }
        if($PSBoundParameters['Running']) { $parameters['running'] = $Running }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/controllers" -Parameters $parameters
    }
}

function New-PveClusterSdnControllers
{
<#
.DESCRIPTION
Create a new sdn controller object.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Asn
autonomous system number
.PARAMETER BgpMultipathAsPathRelax
--
.PARAMETER Controller
The SDN controller object identifier.
.PARAMETER Ebgp
Enable ebgp. (remote-as external)
.PARAMETER EbgpMultihop
--
.PARAMETER IsisDomain
ISIS domain.
.PARAMETER IsisIfaces
ISIS interface.
.PARAMETER IsisNet
ISIS network entity title.
.PARAMETER Loopback
source loopback interface.
.PARAMETER Node
The cluster node name.
.PARAMETER Peers
peers address list.
.PARAMETER Type
Plugin type. Enum: bgp,evpn,faucet,isis
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Asn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$BgpMultipathAsPathRelax,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Controller,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ebgp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$EbgpMultihop,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IsisDomain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IsisIfaces,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IsisNet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Loopback,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Peers,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('bgp','evpn','faucet','isis')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Asn']) { $parameters['asn'] = $Asn }
        if($PSBoundParameters['BgpMultipathAsPathRelax']) { $parameters['bgp-multipath-as-path-relax'] = $BgpMultipathAsPathRelax }
        if($PSBoundParameters['Controller']) { $parameters['controller'] = $Controller }
        if($PSBoundParameters['Ebgp']) { $parameters['ebgp'] = $Ebgp }
        if($PSBoundParameters['EbgpMultihop']) { $parameters['ebgp-multihop'] = $EbgpMultihop }
        if($PSBoundParameters['IsisDomain']) { $parameters['isis-domain'] = $IsisDomain }
        if($PSBoundParameters['IsisIfaces']) { $parameters['isis-ifaces'] = $IsisIfaces }
        if($PSBoundParameters['IsisNet']) { $parameters['isis-net'] = $IsisNet }
        if($PSBoundParameters['Loopback']) { $parameters['loopback'] = $Loopback }
        if($PSBoundParameters['Node']) { $parameters['node'] = $Node }
        if($PSBoundParameters['Peers']) { $parameters['peers'] = $Peers }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/sdn/controllers" -Parameters $parameters
    }
}

function Remove-PveClusterSdnControllers
{
<#
.DESCRIPTION
Delete sdn controller object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Controller
The SDN controller object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Controller
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/sdn/controllers/$Controller"
    }
}

function Get-PveClusterSdnControllersIdx
{
<#
.DESCRIPTION
Read sdn controller configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Controller
The SDN controller object identifier.
.PARAMETER Pending
Display pending config.
.PARAMETER Running
Display running config.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Controller,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Pending,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Running
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Pending']) { $parameters['pending'] = $Pending }
        if($PSBoundParameters['Running']) { $parameters['running'] = $Running }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/controllers/$Controller" -Parameters $parameters
    }
}

function Set-PveClusterSdnControllers
{
<#
.DESCRIPTION
Update sdn controller object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Asn
autonomous system number
.PARAMETER BgpMultipathAsPathRelax
--
.PARAMETER Controller
The SDN controller object identifier.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Ebgp
Enable ebgp. (remote-as external)
.PARAMETER EbgpMultihop
--
.PARAMETER IsisDomain
ISIS domain.
.PARAMETER IsisIfaces
ISIS interface.
.PARAMETER IsisNet
ISIS network entity title.
.PARAMETER Loopback
source loopback interface.
.PARAMETER Node
The cluster node name.
.PARAMETER Peers
peers address list.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Asn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$BgpMultipathAsPathRelax,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Controller,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ebgp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$EbgpMultihop,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IsisDomain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IsisIfaces,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IsisNet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Loopback,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Peers
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Asn']) { $parameters['asn'] = $Asn }
        if($PSBoundParameters['BgpMultipathAsPathRelax']) { $parameters['bgp-multipath-as-path-relax'] = $BgpMultipathAsPathRelax }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Ebgp']) { $parameters['ebgp'] = $Ebgp }
        if($PSBoundParameters['EbgpMultihop']) { $parameters['ebgp-multihop'] = $EbgpMultihop }
        if($PSBoundParameters['IsisDomain']) { $parameters['isis-domain'] = $IsisDomain }
        if($PSBoundParameters['IsisIfaces']) { $parameters['isis-ifaces'] = $IsisIfaces }
        if($PSBoundParameters['IsisNet']) { $parameters['isis-net'] = $IsisNet }
        if($PSBoundParameters['Loopback']) { $parameters['loopback'] = $Loopback }
        if($PSBoundParameters['Node']) { $parameters['node'] = $Node }
        if($PSBoundParameters['Peers']) { $parameters['peers'] = $Peers }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/sdn/controllers/$Controller" -Parameters $parameters
    }
}

function Get-PveClusterSdnIpams
{
<#
.DESCRIPTION
SDN ipams index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Type
Only list sdn ipams of specific type Enum: netbox,phpipam,pve
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('netbox','phpipam','pve')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/ipams" -Parameters $parameters
    }
}

function New-PveClusterSdnIpams
{
<#
.DESCRIPTION
Create a new sdn ipam object.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Ipam
The SDN ipam object identifier.
.PARAMETER Section
--
.PARAMETER Token
--
.PARAMETER Type
Plugin type. Enum: netbox,phpipam,pve
.PARAMETER Url
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ipam,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Section,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Token,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('netbox','phpipam','pve')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Url
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Ipam']) { $parameters['ipam'] = $Ipam }
        if($PSBoundParameters['Section']) { $parameters['section'] = $Section }
        if($PSBoundParameters['Token']) { $parameters['token'] = $Token }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['Url']) { $parameters['url'] = $Url }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/sdn/ipams" -Parameters $parameters
    }
}

function Remove-PveClusterSdnIpams
{
<#
.DESCRIPTION
Delete sdn ipam object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Ipam
The SDN ipam object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ipam
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/sdn/ipams/$Ipam"
    }
}

function Get-PveClusterSdnIpamsIdx
{
<#
.DESCRIPTION
Read sdn ipam configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Ipam
The SDN ipam object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ipam
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/ipams/$Ipam"
    }
}

function Set-PveClusterSdnIpams
{
<#
.DESCRIPTION
Update sdn ipam object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Ipam
The SDN ipam object identifier.
.PARAMETER Section
--
.PARAMETER Token
--
.PARAMETER Url
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ipam,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Section,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Token,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Url
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Section']) { $parameters['section'] = $Section }
        if($PSBoundParameters['Token']) { $parameters['token'] = $Token }
        if($PSBoundParameters['Url']) { $parameters['url'] = $Url }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/sdn/ipams/$Ipam" -Parameters $parameters
    }
}

function Get-PveClusterSdnIpamsStatus
{
<#
.DESCRIPTION
List PVE IPAM Entries
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Ipam
The SDN ipam object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ipam
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/ipams/$Ipam/status"
    }
}

function Get-PveClusterSdnDns
{
<#
.DESCRIPTION
SDN dns index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Type
Only list sdn dns of specific type Enum: powerdns
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('powerdns')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/dns" -Parameters $parameters
    }
}

function New-PveClusterSdnDns
{
<#
.DESCRIPTION
Create a new sdn dns object.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Dns
The SDN dns object identifier.
.PARAMETER Key
--
.PARAMETER Reversemaskv6
--
.PARAMETER Reversev6mask
--
.PARAMETER Ttl
--
.PARAMETER Type
Plugin type. Enum: powerdns
.PARAMETER Url
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Dns,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Key,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Reversemaskv6,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Reversev6mask,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Ttl,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('powerdns')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Url
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Dns']) { $parameters['dns'] = $Dns }
        if($PSBoundParameters['Key']) { $parameters['key'] = $Key }
        if($PSBoundParameters['Reversemaskv6']) { $parameters['reversemaskv6'] = $Reversemaskv6 }
        if($PSBoundParameters['Reversev6mask']) { $parameters['reversev6mask'] = $Reversev6mask }
        if($PSBoundParameters['Ttl']) { $parameters['ttl'] = $Ttl }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['Url']) { $parameters['url'] = $Url }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/cluster/sdn/dns" -Parameters $parameters
    }
}

function Remove-PveClusterSdnDns
{
<#
.DESCRIPTION
Delete sdn dns object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Dns
The SDN dns object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Dns
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/cluster/sdn/dns/$Dns"
    }
}

function Get-PveClusterSdnDnsIdx
{
<#
.DESCRIPTION
Read sdn dns configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Dns
The SDN dns object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Dns
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/sdn/dns/$Dns"
    }
}

function Set-PveClusterSdnDns
{
<#
.DESCRIPTION
Update sdn dns object configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dns
The SDN dns object identifier.
.PARAMETER Key
--
.PARAMETER Reversemaskv6
--
.PARAMETER Ttl
--
.PARAMETER Url
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Dns,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Key,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Reversemaskv6,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Ttl,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Url
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Key']) { $parameters['key'] = $Key }
        if($PSBoundParameters['Reversemaskv6']) { $parameters['reversemaskv6'] = $Reversemaskv6 }
        if($PSBoundParameters['Ttl']) { $parameters['ttl'] = $Ttl }
        if($PSBoundParameters['Url']) { $parameters['url'] = $Url }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/sdn/dns/$Dns" -Parameters $parameters
    }
}

function Get-PveClusterLog
{
<#
.DESCRIPTION
Read cluster log
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Max
Maximum number of entries.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Max
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Max']) { $parameters['max'] = $Max }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/log" -Parameters $parameters
    }
}

function Get-PveClusterResources
{
<#
.DESCRIPTION
Resources index (cluster wide).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Type
-- Enum: vm,storage,node,sdn
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('vm','storage','node','sdn')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/resources" -Parameters $parameters
    }
}

function Get-PveClusterTasks
{
<#
.DESCRIPTION
List recent tasks (cluster wide).
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/tasks"
    }
}

function Get-PveClusterOptions
{
<#
.DESCRIPTION
Get datacenter options. Without 'Sys.Audit' on '/' not all options are returned.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/options"
    }
}

function Set-PveClusterOptions
{
<#
.DESCRIPTION
Set datacenter options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bwlimit
Set I/O bandwidth limit for various operations (in KiB/s).
.PARAMETER Console
Select the default Console viewer. You can either use the builtin java applet (VNC; deprecated and maps to html5), an external virt-viewer comtatible application (SPICE), an HTML5 based vnc viewer (noVNC), or an HTML5 based console client (xtermjs). If the selected viewer is not available (e.g. SPICE not activated for the VM), the fallback is noVNC. Enum: applet,vv,html5,xtermjs
.PARAMETER Crs
Cluster resource scheduling settings.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Description
Datacenter description. Shown in the web-interface datacenter notes panel. This is saved as comment inside the configuration file.
.PARAMETER EmailFrom
Specify email address to send notification from (default is root@$hostname)
.PARAMETER Fencing
Set the fencing mode of the HA cluster. Hardware mode needs a valid configuration of fence devices in /etc/pve/ha/fence.cfg. With both all two modes are used.WARNING':' 'hardware' and 'both' are EXPERIMENTAL & WIP Enum: watchdog,hardware,both
.PARAMETER Ha
Cluster wide HA settings.
.PARAMETER HttpProxy
Specify external http proxy which is used for downloads (example':' 'http':'//username':'password@host':'port/')
.PARAMETER Keyboard
Default keybord layout for vnc server. Enum: de,de-ch,da,en-gb,en-us,es,fi,fr,fr-be,fr-ca,fr-ch,hu,is,it,ja,lt,mk,nl,no,pl,pt,pt-br,sv,sl,tr
.PARAMETER Language
Default GUI language. Enum: ar,ca,da,de,en,es,eu,fa,fr,hr,he,it,ja,ka,kr,nb,nl,nn,pl,pt_BR,ru,sl,sv,tr,ukr,zh_CN,zh_TW
.PARAMETER MacPrefix
Prefix for the auto-generated MAC addresses of virtual guests. The default 'BC':'24':'11' is the OUI assigned by the IEEE to Proxmox Server Solutions GmbH for a 24-bit large MAC block. You're allowed to use this in local networks, i.e., those not directly reachable by the public (e.g., in a LAN or behind NAT).
.PARAMETER MaxWorkers
Defines how many workers (per node) are maximal started  on actions like 'stopall VMs' or task from the ha-manager.
.PARAMETER Migration
For cluster wide migration settings.
.PARAMETER MigrationUnsecure
Migration is secure using SSH tunnel by default. For secure private networks you can disable it to speed up migration. Deprecated, use the 'migration' property instead!
.PARAMETER NextId
Control the range for the free VMID auto-selection pool.
.PARAMETER Notify
Cluster-wide notification settings.
.PARAMETER RegisteredTags
A list of tags that require a `Sys.Modify` on '/' to set and delete. Tags set here that are also in 'user-tag-access' also require `Sys.Modify`.
.PARAMETER TagStyle
Tag style options.
.PARAMETER U2f
u2f
.PARAMETER UserTagAccess
Privilege options for user-settable tags
.PARAMETER Webauthn
webauthn configuration
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('applet','vv','html5','xtermjs')]
        [string]$Console,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Crs,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$EmailFrom,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('watchdog','hardware','both')]
        [string]$Fencing,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Ha,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$HttpProxy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('de','de-ch','da','en-gb','en-us','es','fi','fr','fr-be','fr-ca','fr-ch','hu','is','it','ja','lt','mk','nl','no','pl','pt','pt-br','sv','sl','tr')]
        [string]$Keyboard,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ar','ca','da','de','en','es','eu','fa','fr','hr','he','it','ja','ka','kr','nb','nl','nn','pl','pt_BR','ru','sl','sv','tr','ukr','zh_CN','zh_TW')]
        [string]$Language,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$MacPrefix,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MaxWorkers,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Migration,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$MigrationUnsecure,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$NextId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Notify,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$RegisteredTags,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$TagStyle,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$U2f,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$UserTagAccess,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Webauthn
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Console']) { $parameters['console'] = $Console }
        if($PSBoundParameters['Crs']) { $parameters['crs'] = $Crs }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['EmailFrom']) { $parameters['email_from'] = $EmailFrom }
        if($PSBoundParameters['Fencing']) { $parameters['fencing'] = $Fencing }
        if($PSBoundParameters['Ha']) { $parameters['ha'] = $Ha }
        if($PSBoundParameters['HttpProxy']) { $parameters['http_proxy'] = $HttpProxy }
        if($PSBoundParameters['Keyboard']) { $parameters['keyboard'] = $Keyboard }
        if($PSBoundParameters['Language']) { $parameters['language'] = $Language }
        if($PSBoundParameters['MacPrefix']) { $parameters['mac_prefix'] = $MacPrefix }
        if($PSBoundParameters['MaxWorkers']) { $parameters['max_workers'] = $MaxWorkers }
        if($PSBoundParameters['Migration']) { $parameters['migration'] = $Migration }
        if($PSBoundParameters['MigrationUnsecure']) { $parameters['migration_unsecure'] = $MigrationUnsecure }
        if($PSBoundParameters['NextId']) { $parameters['next-id'] = $NextId }
        if($PSBoundParameters['Notify']) { $parameters['notify'] = $Notify }
        if($PSBoundParameters['RegisteredTags']) { $parameters['registered-tags'] = $RegisteredTags }
        if($PSBoundParameters['TagStyle']) { $parameters['tag-style'] = $TagStyle }
        if($PSBoundParameters['U2f']) { $parameters['u2f'] = $U2f }
        if($PSBoundParameters['UserTagAccess']) { $parameters['user-tag-access'] = $UserTagAccess }
        if($PSBoundParameters['Webauthn']) { $parameters['webauthn'] = $Webauthn }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/cluster/options" -Parameters $parameters
    }
}

function Get-PveClusterStatus
{
<#
.DESCRIPTION
Get cluster status information.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/status"
    }
}

function Get-PveClusterNextid
{
<#
.DESCRIPTION
Get next free VMID. Pass a VMID to assert that its free (at time of check).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/cluster/nextid" -Parameters $parameters
    }
}

function Get-PveNodes
{
<#
.DESCRIPTION
Cluster node index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes"
    }
}

function Get-PveNodesIdx
{
<#
.DESCRIPTION
Node index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node"
    }
}

function Get-PveNodesQemu
{
<#
.DESCRIPTION
Virtual machine index (per node).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Full
Determine the full status of active VMs.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Full,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Full']) { $parameters['full'] = $Full }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu" -Parameters $parameters
    }
}

function New-PveNodesQemu
{
<#
.DESCRIPTION
Create or restore a virtual machine.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Acpi
Enable/disable ACPI.
.PARAMETER Affinity
List of host cores used to execute guest processes, for example':' 0,5,8-11
.PARAMETER Agent
Enable/disable communication with the QEMU Guest Agent and its properties.
.PARAMETER Arch
Virtual processor architecture. Defaults to the host. Enum: x86_64,aarch64
.PARAMETER Archive
The backup archive. Either the file system path to a .tar or .vma file (use '-' to pipe data from stdin) or a proxmox storage backup volume identifier.
.PARAMETER Args_
Arbitrary arguments passed to kvm.
.PARAMETER Audio0
Configure a audio device, useful in combination with QXL/Spice.
.PARAMETER Autostart
Automatic restart after crash (currently ignored).
.PARAMETER Balloon
Amount of target RAM for the VM in MiB. Using zero disables the ballon driver.
.PARAMETER Bios
Select BIOS implementation. Enum: seabios,ovmf
.PARAMETER Boot
Specify guest boot order. Use the 'order=' sub-property as usage with no key or 'legacy=' is deprecated.
.PARAMETER Bootdisk
Enable booting from specified disk. Deprecated':' Use 'boot':' order=foo;bar' instead.
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Cdrom
This is an alias for option -ide2
.PARAMETER Cicustom
cloud-init':' Specify custom files to replace the automatically generated ones at start.
.PARAMETER Cipassword
cloud-init':' Password to assign the user. Using this is generally not recommended. Use ssh keys instead. Also note that older cloud-init versions do not support hashed passwords.
.PARAMETER Citype
Specifies the cloud-init configuration format. The default depends on the configured operating system type (`ostype`. We use the `nocloud` format for Linux, and `configdrive2` for windows. Enum: configdrive2,nocloud,opennebula
.PARAMETER Ciupgrade
cloud-init':' do an automatic package upgrade after the first boot.
.PARAMETER Ciuser
cloud-init':' User name to change ssh keys and password for instead of the image's configured default user.
.PARAMETER Cores
The number of cores per socket.
.PARAMETER Cpu
Emulated CPU type.
.PARAMETER Cpulimit
Limit of CPU usage.
.PARAMETER Cpuunits
CPU weight for a VM, will be clamped to \[1, 10000] in cgroup v2.
.PARAMETER Description
Description for the VM. Shown in the web-interface VM's summary. This is saved as comment inside the configuration file.
.PARAMETER Efidisk0
Configure a disk for storing EFI vars. Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Note that SIZE_IN_GiB is ignored here and that the default EFI vars are copied to the volume instead. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Force
Allow to overwrite existing VM.
.PARAMETER Freeze
Freeze CPU at startup (use 'c' monitor command to start execution).
.PARAMETER Hookscript
Script that will be executed during various steps in the vms lifetime.
.PARAMETER HostpciN
Map host PCI devices into guest.
.PARAMETER Hotplug
Selectively enable hotplug features. This is a comma separated list of hotplug features':' 'network', 'disk', 'cpu', 'memory', 'usb' and 'cloudinit'. Use '0' to disable hotplug completely. Using '1' as value is an alias for the default `network,disk,usb`. USB hotplugging is possible for guests with machine version >= 7.1 and ostype l26 or windows > 7.
.PARAMETER Hugepages
Enable/disable hugepages memory. Enum: any,2,1024
.PARAMETER IdeN
Use volume as IDE hard disk or CD-ROM (n is 0 to 3). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER IpconfigN
cloud-init':' Specify IP addresses and gateways for the corresponding interface.IP addresses use CIDR notation, gateways are optional but need an IP of the same type specified.The special string 'dhcp' can be used for IP addresses to use DHCP, in which case no explicitgateway should be provided.For IPv6 the special string 'auto' can be used to use stateless autoconfiguration. This requirescloud-init 19.4 or newer.If cloud-init is enabled and neither an IPv4 nor an IPv6 address is specified, it defaults to usingdhcp on IPv4.
.PARAMETER Ivshmem
Inter-VM shared memory. Useful for direct communication between VMs, or to the host.
.PARAMETER Keephugepages
Use together with hugepages. If enabled, hugepages will not not be deleted after VM shutdown and can be used for subsequent starts.
.PARAMETER Keyboard
Keyboard layout for VNC server. This option is generally not required and is often better handled from within the guest OS. Enum: de,de-ch,da,en-gb,en-us,es,fi,fr,fr-be,fr-ca,fr-ch,hu,is,it,ja,lt,mk,nl,no,pl,pt,pt-br,sv,sl,tr
.PARAMETER Kvm
Enable/disable KVM hardware virtualization.
.PARAMETER LiveRestore
Start the VM immediately from the backup and restore in background. PBS only.
.PARAMETER Localtime
Set the real time clock (RTC) to local time. This is enabled by default if the `ostype` indicates a Microsoft Windows OS.
.PARAMETER Lock
Lock/unlock the VM. Enum: backup,clone,create,migrate,rollback,snapshot,snapshot-delete,suspending,suspended
.PARAMETER Machine
Specifies the QEMU machine type.
.PARAMETER Memory
Memory properties.
.PARAMETER MigrateDowntime
Set maximum tolerated downtime (in seconds) for migrations.
.PARAMETER MigrateSpeed
Set maximum speed (in MB/s) for migrations. Value 0 is no limit.
.PARAMETER Name
Set a name for the VM. Only used on the configuration web interface.
.PARAMETER Nameserver
cloud-init':' Sets DNS server IP address for a container. Create will automatically use the setting from the host if neither searchdomain nor nameserver are set.
.PARAMETER NetN
Specify network devices.
.PARAMETER Node
The cluster node name.
.PARAMETER Numa
Enable/disable NUMA.
.PARAMETER NumaN
NUMA topology.
.PARAMETER Onboot
Specifies whether a VM will be started during system bootup.
.PARAMETER Ostype
Specify guest operating system. Enum: other,wxp,w2k,w2k3,w2k8,wvista,win7,win8,win10,win11,l24,l26,solaris
.PARAMETER ParallelN
Map host parallel devices (n is 0 to 2).
.PARAMETER Pool
Add the VM to the specified pool.
.PARAMETER Protection
Sets the protection flag of the VM. This will disable the remove VM and remove disk operations.
.PARAMETER Reboot
Allow reboot. If set to '0' the VM exit on reboot.
.PARAMETER Rng0
Configure a VirtIO-based Random Number Generator.
.PARAMETER SataN
Use volume as SATA hard disk or CD-ROM (n is 0 to 5). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER ScsiN
Use volume as SCSI hard disk or CD-ROM (n is 0 to 30). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Scsihw
SCSI controller model Enum: lsi,lsi53c810,virtio-scsi-pci,virtio-scsi-single,megasas,pvscsi
.PARAMETER Searchdomain
cloud-init':' Sets DNS search domains for a container. Create will automatically use the setting from the host if neither searchdomain nor nameserver are set.
.PARAMETER SerialN
Create a serial device inside the VM (n is 0 to 3)
.PARAMETER Shares
Amount of memory shares for auto-ballooning. The larger the number is, the more memory this VM gets. Number is relative to weights of all other running VMs. Using zero disables auto-ballooning. Auto-ballooning is done by pvestatd.
.PARAMETER Smbios1
Specify SMBIOS type 1 fields.
.PARAMETER Smp
The number of CPUs. Please use option -sockets instead.
.PARAMETER Sockets
The number of CPU sockets.
.PARAMETER SpiceEnhancements
Configure additional enhancements for SPICE.
.PARAMETER Sshkeys
cloud-init':' Setup public SSH keys (one key per line, OpenSSH format).
.PARAMETER Start
Start VM after it was created successfully.
.PARAMETER Startdate
Set the initial date of the real time clock. Valid format for date are':''now' or '2006-06-17T16':'01':'21' or '2006-06-17'.
.PARAMETER Startup
Startup and shutdown behavior. Order is a non-negative number defining the general startup order. Shutdown in done with reverse ordering. Additionally you can set the 'up' or 'down' delay in seconds, which specifies a delay to wait before the next VM is started or stopped.
.PARAMETER Storage
Default storage.
.PARAMETER Tablet
Enable/disable the USB tablet device.
.PARAMETER Tags
Tags of the VM. This is only meta information.
.PARAMETER Tdf
Enable/disable time drift fix.
.PARAMETER Template
Enable/disable Template.
.PARAMETER Tpmstate0
Configure a Disk for storing TPM state. The format is fixed to 'raw'. Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Note that SIZE_IN_GiB is ignored here and 4 MiB will be used instead. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Unique
Assign a unique random ethernet address.
.PARAMETER UnusedN
Reference to unused volumes. This is used internally, and should not be modified manually.
.PARAMETER UsbN
Configure an USB device (n is 0 to 4, for machine version >= 7.1 and ostype l26 or windows > 7, n can be up to 14).
.PARAMETER Vcpus
Number of hotplugged vcpus.
.PARAMETER Vga
Configure the VGA hardware.
.PARAMETER VirtioN
Use volume as VIRTIO hard disk (n is 0 to 15). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Vmgenid
Set VM Generation ID. Use '1' to autogenerate on create or update, pass '0' to disable explicitly.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Vmstatestorage
Default storage for VM state volumes/files.
.PARAMETER Watchdog
Create a virtual hardware watchdog device.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Acpi,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Affinity,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Agent,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('x86_64','aarch64')]
        [string]$Arch,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Archive,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Args_,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Audio0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Autostart,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Balloon,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('seabios','ovmf')]
        [string]$Bios,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Boot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bootdisk,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cdrom,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cicustom,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Cipassword,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('configdrive2','nocloud','opennebula')]
        [string]$Citype,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ciupgrade,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Ciuser,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cores,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cpu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Cpulimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cpuunits,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Efidisk0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Freeze,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hookscript,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$HostpciN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hotplug,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('any','2','1024')]
        [string]$Hugepages,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$IdeN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$IpconfigN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Ivshmem,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Keephugepages,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('de','de-ch','da','en-gb','en-us','es','fi','fr','fr-be','fr-ca','fr-ch','hu','is','it','ja','lt','mk','nl','no','pl','pt','pt-br','sv','sl','tr')]
        [string]$Keyboard,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Kvm,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$LiveRestore,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Localtime,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('backup','clone','create','migrate','rollback','snapshot','snapshot-delete','suspending','suspended')]
        [string]$Lock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Machine,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Memory,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$MigrateDowntime,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MigrateSpeed,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nameserver,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$NetN,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Numa,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$NumaN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Onboot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('other','wxp','w2k','w2k3','w2k8','wvista','win7','win8','win10','win11','l24','l26','solaris')]
        [string]$Ostype,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$ParallelN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Pool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Protection,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Reboot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rng0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$SataN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$ScsiN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('lsi','lsi53c810','virtio-scsi-pci','virtio-scsi-single','megasas','pvscsi')]
        [string]$Scsihw,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Searchdomain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$SerialN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Shares,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Smbios1,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Smp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Sockets,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SpiceEnhancements,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sshkeys,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Start,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Startdate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Startup,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Tablet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tags,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Tdf,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Template,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tpmstate0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Unique,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$UnusedN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$UsbN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Vcpus,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vga,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$VirtioN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vmgenid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vmstatestorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Watchdog
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Acpi']) { $parameters['acpi'] = $Acpi }
        if($PSBoundParameters['Affinity']) { $parameters['affinity'] = $Affinity }
        if($PSBoundParameters['Agent']) { $parameters['agent'] = $Agent }
        if($PSBoundParameters['Arch']) { $parameters['arch'] = $Arch }
        if($PSBoundParameters['Archive']) { $parameters['archive'] = $Archive }
        if($PSBoundParameters['Args_']) { $parameters['args'] = $Args_ }
        if($PSBoundParameters['Audio0']) { $parameters['audio0'] = $Audio0 }
        if($PSBoundParameters['Autostart']) { $parameters['autostart'] = $Autostart }
        if($PSBoundParameters['Balloon']) { $parameters['balloon'] = $Balloon }
        if($PSBoundParameters['Bios']) { $parameters['bios'] = $Bios }
        if($PSBoundParameters['Boot']) { $parameters['boot'] = $Boot }
        if($PSBoundParameters['Bootdisk']) { $parameters['bootdisk'] = $Bootdisk }
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Cdrom']) { $parameters['cdrom'] = $Cdrom }
        if($PSBoundParameters['Cicustom']) { $parameters['cicustom'] = $Cicustom }
        if($PSBoundParameters['Cipassword']) { $parameters['cipassword'] = (ConvertFrom-SecureString -SecureString $Cipassword -AsPlainText) }
        if($PSBoundParameters['Citype']) { $parameters['citype'] = $Citype }
        if($PSBoundParameters['Ciupgrade']) { $parameters['ciupgrade'] = $Ciupgrade }
        if($PSBoundParameters['Ciuser']) { $parameters['ciuser'] = $Ciuser }
        if($PSBoundParameters['Cores']) { $parameters['cores'] = $Cores }
        if($PSBoundParameters['Cpu']) { $parameters['cpu'] = $Cpu }
        if($PSBoundParameters['Cpulimit']) { $parameters['cpulimit'] = $Cpulimit }
        if($PSBoundParameters['Cpuunits']) { $parameters['cpuunits'] = $Cpuunits }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Efidisk0']) { $parameters['efidisk0'] = $Efidisk0 }
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Freeze']) { $parameters['freeze'] = $Freeze }
        if($PSBoundParameters['Hookscript']) { $parameters['hookscript'] = $Hookscript }
        if($PSBoundParameters['Hotplug']) { $parameters['hotplug'] = $Hotplug }
        if($PSBoundParameters['Hugepages']) { $parameters['hugepages'] = $Hugepages }
        if($PSBoundParameters['Ivshmem']) { $parameters['ivshmem'] = $Ivshmem }
        if($PSBoundParameters['Keephugepages']) { $parameters['keephugepages'] = $Keephugepages }
        if($PSBoundParameters['Keyboard']) { $parameters['keyboard'] = $Keyboard }
        if($PSBoundParameters['Kvm']) { $parameters['kvm'] = $Kvm }
        if($PSBoundParameters['LiveRestore']) { $parameters['live-restore'] = $LiveRestore }
        if($PSBoundParameters['Localtime']) { $parameters['localtime'] = $Localtime }
        if($PSBoundParameters['Lock']) { $parameters['lock'] = $Lock }
        if($PSBoundParameters['Machine']) { $parameters['machine'] = $Machine }
        if($PSBoundParameters['Memory']) { $parameters['memory'] = $Memory }
        if($PSBoundParameters['MigrateDowntime']) { $parameters['migrate_downtime'] = $MigrateDowntime }
        if($PSBoundParameters['MigrateSpeed']) { $parameters['migrate_speed'] = $MigrateSpeed }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Nameserver']) { $parameters['nameserver'] = $Nameserver }
        if($PSBoundParameters['Numa']) { $parameters['numa'] = $Numa }
        if($PSBoundParameters['Onboot']) { $parameters['onboot'] = $Onboot }
        if($PSBoundParameters['Ostype']) { $parameters['ostype'] = $Ostype }
        if($PSBoundParameters['Pool']) { $parameters['pool'] = $Pool }
        if($PSBoundParameters['Protection']) { $parameters['protection'] = $Protection }
        if($PSBoundParameters['Reboot']) { $parameters['reboot'] = $Reboot }
        if($PSBoundParameters['Rng0']) { $parameters['rng0'] = $Rng0 }
        if($PSBoundParameters['Scsihw']) { $parameters['scsihw'] = $Scsihw }
        if($PSBoundParameters['Searchdomain']) { $parameters['searchdomain'] = $Searchdomain }
        if($PSBoundParameters['Shares']) { $parameters['shares'] = $Shares }
        if($PSBoundParameters['Smbios1']) { $parameters['smbios1'] = $Smbios1 }
        if($PSBoundParameters['Smp']) { $parameters['smp'] = $Smp }
        if($PSBoundParameters['Sockets']) { $parameters['sockets'] = $Sockets }
        if($PSBoundParameters['SpiceEnhancements']) { $parameters['spice_enhancements'] = $SpiceEnhancements }
        if($PSBoundParameters['Sshkeys']) { $parameters['sshkeys'] = $Sshkeys }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }
        if($PSBoundParameters['Startdate']) { $parameters['startdate'] = $Startdate }
        if($PSBoundParameters['Startup']) { $parameters['startup'] = $Startup }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Tablet']) { $parameters['tablet'] = $Tablet }
        if($PSBoundParameters['Tags']) { $parameters['tags'] = $Tags }
        if($PSBoundParameters['Tdf']) { $parameters['tdf'] = $Tdf }
        if($PSBoundParameters['Template']) { $parameters['template'] = $Template }
        if($PSBoundParameters['Tpmstate0']) { $parameters['tpmstate0'] = $Tpmstate0 }
        if($PSBoundParameters['Unique']) { $parameters['unique'] = $Unique }
        if($PSBoundParameters['Vcpus']) { $parameters['vcpus'] = $Vcpus }
        if($PSBoundParameters['Vga']) { $parameters['vga'] = $Vga }
        if($PSBoundParameters['Vmgenid']) { $parameters['vmgenid'] = $Vmgenid }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }
        if($PSBoundParameters['Vmstatestorage']) { $parameters['vmstatestorage'] = $Vmstatestorage }
        if($PSBoundParameters['Watchdog']) { $parameters['watchdog'] = $Watchdog }

        if($PSBoundParameters['HostpciN']) { $HostpciN.keys | ForEach-Object { $parameters['hostpci' + $_] = $HostpciN[$_] } }
        if($PSBoundParameters['IdeN']) { $IdeN.keys | ForEach-Object { $parameters['ide' + $_] = $IdeN[$_] } }
        if($PSBoundParameters['IpconfigN']) { $IpconfigN.keys | ForEach-Object { $parameters['ipconfig' + $_] = $IpconfigN[$_] } }
        if($PSBoundParameters['NetN']) { $NetN.keys | ForEach-Object { $parameters['net' + $_] = $NetN[$_] } }
        if($PSBoundParameters['NumaN']) { $NumaN.keys | ForEach-Object { $parameters['numa' + $_] = $NumaN[$_] } }
        if($PSBoundParameters['ParallelN']) { $ParallelN.keys | ForEach-Object { $parameters['parallel' + $_] = $ParallelN[$_] } }
        if($PSBoundParameters['SataN']) { $SataN.keys | ForEach-Object { $parameters['sata' + $_] = $SataN[$_] } }
        if($PSBoundParameters['ScsiN']) { $ScsiN.keys | ForEach-Object { $parameters['scsi' + $_] = $ScsiN[$_] } }
        if($PSBoundParameters['SerialN']) { $SerialN.keys | ForEach-Object { $parameters['serial' + $_] = $SerialN[$_] } }
        if($PSBoundParameters['UnusedN']) { $UnusedN.keys | ForEach-Object { $parameters['unused' + $_] = $UnusedN[$_] } }
        if($PSBoundParameters['UsbN']) { $UsbN.keys | ForEach-Object { $parameters['usb' + $_] = $UsbN[$_] } }
        if($PSBoundParameters['VirtioN']) { $VirtioN.keys | ForEach-Object { $parameters['virtio' + $_] = $VirtioN[$_] } }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu" -Parameters $parameters
    }
}

function Remove-PveNodesQemu
{
<#
.DESCRIPTION
Destroy the VM and  all used/owned volumes. Removes any VM specific permissions and firewall rules
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER DestroyUnreferencedDisks
If set, destroy additionally all disks not referenced in the config but with a matching VMID from all enabled storages.
.PARAMETER Node
The cluster node name.
.PARAMETER Purge
Remove VMID from configurations, like backup & replication jobs and HA.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$DestroyUnreferencedDisks,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Purge,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['DestroyUnreferencedDisks']) { $parameters['destroy-unreferenced-disks'] = $DestroyUnreferencedDisks }
        if($PSBoundParameters['Purge']) { $parameters['purge'] = $Purge }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/qemu/$Vmid" -Parameters $parameters
    }
}

function Get-PveNodesQemuIdx
{
<#
.DESCRIPTION
Directory index
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid"
    }
}

function Get-PveNodesQemuFirewall
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall"
    }
}

function Get-PveNodesQemuFirewallRules
{
<#
.DESCRIPTION
List rules.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/rules"
    }
}

function New-PveNodesQemuFirewallRules
{
<#
.DESCRIPTION
Create new rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('in','out','group')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Pos']) { $parameters['pos'] = $Pos }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/firewall/rules" -Parameters $parameters
    }
}

function Remove-PveNodesQemuFirewallRules
{
<#
.DESCRIPTION
Delete rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/qemu/$Vmid/firewall/rules/$Pos" -Parameters $parameters
    }
}

function Get-PveNodesQemuFirewallRulesIdx
{
<#
.DESCRIPTION
Get single rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/rules/$Pos"
    }
}

function Set-PveNodesQemuFirewallRules
{
<#
.DESCRIPTION
Modify rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Moveto
Move rule to new position <moveto>. Other arguments are ignored.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Moveto,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('in','out','group')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Moveto']) { $parameters['moveto'] = $Moveto }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/firewall/rules/$Pos" -Parameters $parameters
    }
}

function Get-PveNodesQemuFirewallAliases
{
<#
.DESCRIPTION
List aliases
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/aliases"
    }
}

function New-PveNodesQemuFirewallAliases
{
<#
.DESCRIPTION
Create IP or Network Alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Name
Alias name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/firewall/aliases" -Parameters $parameters
    }
}

function Remove-PveNodesQemuFirewallAliases
{
<#
.DESCRIPTION
Remove IP or Network alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
Alias name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/qemu/$Vmid/firewall/aliases/$Name" -Parameters $parameters
    }
}

function Get-PveNodesQemuFirewallAliasesIdx
{
<#
.DESCRIPTION
Read alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
Alias name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/aliases/$Name"
    }
}

function Set-PveNodesQemuFirewallAliases
{
<#
.DESCRIPTION
Update IP or Network alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
Alias name.
.PARAMETER Node
The cluster node name.
.PARAMETER Rename
Rename an existing alias.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rename,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Rename']) { $parameters['rename'] = $Rename }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/firewall/aliases/$Name" -Parameters $parameters
    }
}

function Get-PveNodesQemuFirewallIpset
{
<#
.DESCRIPTION
List IPSets
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/ipset"
    }
}

function New-PveNodesQemuFirewallIpset
{
<#
.DESCRIPTION
Create new IPSet
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Rename
Rename an existing IPSet. You can set 'rename' to the same value as 'name' to update the 'comment' of an existing IPSet.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rename,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Rename']) { $parameters['rename'] = $Rename }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/firewall/ipset" -Parameters $parameters
    }
}

function Remove-PveNodesQemuFirewallIpset
{
<#
.DESCRIPTION
Delete IPSet
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
Delete all members of the IPSet, if there are any.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/qemu/$Vmid/firewall/ipset/$Name" -Parameters $parameters
    }
}

function Get-PveNodesQemuFirewallIpsetIdx
{
<#
.DESCRIPTION
List IPSet content
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/ipset/$Name"
    }
}

function New-PveNodesQemuFirewallIpsetIdx
{
<#
.DESCRIPTION
Add IP or Network to IPSet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Nomatch
--
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nomatch,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Nomatch']) { $parameters['nomatch'] = $Nomatch }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/firewall/ipset/$Name" -Parameters $parameters
    }
}

function Remove-PveNodesQemuFirewallIpsetIdx
{
<#
.DESCRIPTION
Remove IP or Network from IPSet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/qemu/$Vmid/firewall/ipset/$Name/$Cidr" -Parameters $parameters
    }
}

function Get-PveNodesQemuFirewallIpsetIdx
{
<#
.DESCRIPTION
Read IP or Network settings from IPSet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/ipset/$Name/$Cidr"
    }
}

function Set-PveNodesQemuFirewallIpset
{
<#
.DESCRIPTION
Update IP or Network settings
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Nomatch
--
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nomatch,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Nomatch']) { $parameters['nomatch'] = $Nomatch }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/firewall/ipset/$Name/$Cidr" -Parameters $parameters
    }
}

function Get-PveNodesQemuFirewallOptions
{
<#
.DESCRIPTION
Get VM firewall options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/options"
    }
}

function Set-PveNodesQemuFirewallOptions
{
<#
.DESCRIPTION
Set Firewall options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Dhcp
Enable DHCP.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Enable
Enable/disable firewall rules.
.PARAMETER Ipfilter
Enable default IP filters. This is equivalent to adding an empty ipfilter-net<id> ipset for every interface. Such ipsets implicitly contain sane default restrictions such as restricting IPv6 link local addresses to the one derived from the interface's MAC address. For containers the configured IP addresses will be implicitly added.
.PARAMETER LogLevelIn
Log level for incoming traffic. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER LogLevelOut
Log level for outgoing traffic. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macfilter
Enable/disable MAC address filter.
.PARAMETER Ndp
Enable NDP (Neighbor Discovery Protocol).
.PARAMETER Node
The cluster node name.
.PARAMETER PolicyIn
Input policy. Enum: ACCEPT,REJECT,DROP
.PARAMETER PolicyOut
Output policy. Enum: ACCEPT,REJECT,DROP
.PARAMETER Radv
Allow sending Router Advertisement.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Dhcp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ipfilter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$LogLevelIn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$LogLevelOut,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Macfilter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ndp,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ACCEPT','REJECT','DROP')]
        [string]$PolicyIn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ACCEPT','REJECT','DROP')]
        [string]$PolicyOut,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Radv,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Dhcp']) { $parameters['dhcp'] = $Dhcp }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['Ipfilter']) { $parameters['ipfilter'] = $Ipfilter }
        if($PSBoundParameters['LogLevelIn']) { $parameters['log_level_in'] = $LogLevelIn }
        if($PSBoundParameters['LogLevelOut']) { $parameters['log_level_out'] = $LogLevelOut }
        if($PSBoundParameters['Macfilter']) { $parameters['macfilter'] = $Macfilter }
        if($PSBoundParameters['Ndp']) { $parameters['ndp'] = $Ndp }
        if($PSBoundParameters['PolicyIn']) { $parameters['policy_in'] = $PolicyIn }
        if($PSBoundParameters['PolicyOut']) { $parameters['policy_out'] = $PolicyOut }
        if($PSBoundParameters['Radv']) { $parameters['radv'] = $Radv }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/firewall/options" -Parameters $parameters
    }
}

function Get-PveNodesQemuFirewallLog
{
<#
.DESCRIPTION
Read firewall log
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Limit
--
.PARAMETER Node
The cluster node name.
.PARAMETER Since
Display log since this UNIX epoch.
.PARAMETER Start
--
.PARAMETER Until
Display log until this UNIX epoch.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Limit,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Since,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Start,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Until,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Limit']) { $parameters['limit'] = $Limit }
        if($PSBoundParameters['Since']) { $parameters['since'] = $Since }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }
        if($PSBoundParameters['Until']) { $parameters['until'] = $Until }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/log" -Parameters $parameters
    }
}

function Get-PveNodesQemuFirewallRefs
{
<#
.DESCRIPTION
Lists possible IPSet/Alias reference which are allowed in source/dest properties.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Type
Only list references of specified type. Enum: alias,ipset
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('alias','ipset')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/firewall/refs" -Parameters $parameters
    }
}

function Get-PveNodesQemuAgent
{
<#
.DESCRIPTION
QEMU Guest Agent command index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent"
    }
}

function New-PveNodesQemuAgent
{
<#
.DESCRIPTION
Execute QEMU Guest Agent commands.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Command
The QGA command. Enum: fsfreeze-freeze,fsfreeze-status,fsfreeze-thaw,fstrim,get-fsinfo,get-host-name,get-memory-block-info,get-memory-blocks,get-osinfo,get-time,get-timezone,get-users,get-vcpus,info,network-get-interfaces,ping,shutdown,suspend-disk,suspend-hybrid,suspend-ram
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('fsfreeze-freeze','fsfreeze-status','fsfreeze-thaw','fstrim','get-fsinfo','get-host-name','get-memory-block-info','get-memory-blocks','get-osinfo','get-time','get-timezone','get-users','get-vcpus','info','network-get-interfaces','ping','shutdown','suspend-disk','suspend-hybrid','suspend-ram')]
        [string]$Command,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Command']) { $parameters['command'] = $Command }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent" -Parameters $parameters
    }
}

function New-PveNodesQemuAgentFsfreezeFreeze
{
<#
.DESCRIPTION
Execute fsfreeze-freeze.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/fsfreeze-freeze"
    }
}

function New-PveNodesQemuAgentFsfreezeStatus
{
<#
.DESCRIPTION
Execute fsfreeze-status.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/fsfreeze-status"
    }
}

function New-PveNodesQemuAgentFsfreezeThaw
{
<#
.DESCRIPTION
Execute fsfreeze-thaw.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/fsfreeze-thaw"
    }
}

function New-PveNodesQemuAgentFstrim
{
<#
.DESCRIPTION
Execute fstrim.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/fstrim"
    }
}

function Get-PveNodesQemuAgentGetFsinfo
{
<#
.DESCRIPTION
Execute get-fsinfo.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/get-fsinfo"
    }
}

function Get-PveNodesQemuAgentGetHostName
{
<#
.DESCRIPTION
Execute get-host-name.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/get-host-name"
    }
}

function Get-PveNodesQemuAgentGetMemoryBlockInfo
{
<#
.DESCRIPTION
Execute get-memory-block-info.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/get-memory-block-info"
    }
}

function Get-PveNodesQemuAgentGetMemoryBlocks
{
<#
.DESCRIPTION
Execute get-memory-blocks.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/get-memory-blocks"
    }
}

function Get-PveNodesQemuAgentGetOsinfo
{
<#
.DESCRIPTION
Execute get-osinfo.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/get-osinfo"
    }
}

function Get-PveNodesQemuAgentGetTime
{
<#
.DESCRIPTION
Execute get-time.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/get-time"
    }
}

function Get-PveNodesQemuAgentGetTimezone
{
<#
.DESCRIPTION
Execute get-timezone.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/get-timezone"
    }
}

function Get-PveNodesQemuAgentGetUsers
{
<#
.DESCRIPTION
Execute get-users.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/get-users"
    }
}

function Get-PveNodesQemuAgentGetVcpus
{
<#
.DESCRIPTION
Execute get-vcpus.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/get-vcpus"
    }
}

function Get-PveNodesQemuAgentInfo
{
<#
.DESCRIPTION
Execute info.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/info"
    }
}

function Get-PveNodesQemuAgentNetworkGetInterfaces
{
<#
.DESCRIPTION
Execute network-get-interfaces.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/network-get-interfaces"
    }
}

function New-PveNodesQemuAgentPing
{
<#
.DESCRIPTION
Execute ping.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/ping"
    }
}

function New-PveNodesQemuAgentShutdown
{
<#
.DESCRIPTION
Execute shutdown.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/shutdown"
    }
}

function New-PveNodesQemuAgentSuspendDisk
{
<#
.DESCRIPTION
Execute suspend-disk.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/suspend-disk"
    }
}

function New-PveNodesQemuAgentSuspendHybrid
{
<#
.DESCRIPTION
Execute suspend-hybrid.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/suspend-hybrid"
    }
}

function New-PveNodesQemuAgentSuspendRam
{
<#
.DESCRIPTION
Execute suspend-ram.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/suspend-ram"
    }
}

function New-PveNodesQemuAgentSetUserPassword
{
<#
.DESCRIPTION
Sets the password for the given user to the given password
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Crypted
set to 1 if the password has already been passed through crypt()
.PARAMETER Node
The cluster node name.
.PARAMETER Password
The new password.
.PARAMETER Username
The user to set the password for.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Crypted,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Username,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Crypted']) { $parameters['crypted'] = $Crypted }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Username']) { $parameters['username'] = $Username }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/set-user-password" -Parameters $parameters
    }
}

function New-PveNodesQemuAgentExec
{
<#
.DESCRIPTION
Executes the given command in the vm via the guest-agent and returns an object with the pid.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Command
The command as a list of program + arguments.
.PARAMETER InputData
Data to pass as 'input-data' to the guest. Usually treated as STDIN to 'command'.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [array]$Command,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$InputData,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Command']) { $parameters['command'] = $Command }
        if($PSBoundParameters['InputData']) { $parameters['input-data'] = $InputData }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/exec" -Parameters $parameters
    }
}

function Get-PveNodesQemuAgentExecStatus
{
<#
.DESCRIPTION
Gets the status of the given pid started by the guest-agent
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Pid_
The PID to query
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Pid_,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Pid_']) { $parameters['pid'] = $Pid_ }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/exec-status" -Parameters $parameters
    }
}

function Get-PveNodesQemuAgentFileRead
{
<#
.DESCRIPTION
Reads the given file via guest agent. Is limited to 16777216 bytes.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER File
The path to the file
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$File,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['File']) { $parameters['file'] = $File }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/agent/file-read" -Parameters $parameters
    }
}

function New-PveNodesQemuAgentFileWrite
{
<#
.DESCRIPTION
Writes the given file via guest agent.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Content
The content to write into the file.
.PARAMETER Encode
If set, the content will be encoded as base64 (required by QEMU).Otherwise the content needs to be encoded beforehand - defaults to true.
.PARAMETER File
The path to the file.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Content,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Encode,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$File,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Content']) { $parameters['content'] = $Content }
        if($PSBoundParameters['Encode']) { $parameters['encode'] = $Encode }
        if($PSBoundParameters['File']) { $parameters['file'] = $File }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/agent/file-write" -Parameters $parameters
    }
}

function Get-PveNodesQemuRrd
{
<#
.DESCRIPTION
Read VM RRD statistics (returns PNG)
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cf
The RRD consolidation function Enum: AVERAGE,MAX
.PARAMETER Ds
The list of datasources you want to display.
.PARAMETER Node
The cluster node name.
.PARAMETER Timeframe
Specify the time frame you are interested in. Enum: hour,day,week,month,year
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('AVERAGE','MAX')]
        [string]$Cf,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ds,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('hour','day','week','month','year')]
        [string]$Timeframe,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cf']) { $parameters['cf'] = $Cf }
        if($PSBoundParameters['Ds']) { $parameters['ds'] = $Ds }
        if($PSBoundParameters['Timeframe']) { $parameters['timeframe'] = $Timeframe }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/rrd" -Parameters $parameters
    }
}

function Get-PveNodesQemuRrddata
{
<#
.DESCRIPTION
Read VM RRD statistics
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cf
The RRD consolidation function Enum: AVERAGE,MAX
.PARAMETER Node
The cluster node name.
.PARAMETER Timeframe
Specify the time frame you are interested in. Enum: hour,day,week,month,year
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('AVERAGE','MAX')]
        [string]$Cf,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('hour','day','week','month','year')]
        [string]$Timeframe,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cf']) { $parameters['cf'] = $Cf }
        if($PSBoundParameters['Timeframe']) { $parameters['timeframe'] = $Timeframe }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/rrddata" -Parameters $parameters
    }
}

function Get-PveNodesQemuConfig
{
<#
.DESCRIPTION
Get the virtual machine configuration with pending configuration changes applied. Set the 'current' parameter to get the current configuration instead.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Current
Get current values (instead of pending values).
.PARAMETER Node
The cluster node name.
.PARAMETER Snapshot
Fetch config values from given snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Current,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Snapshot,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Current']) { $parameters['current'] = $Current }
        if($PSBoundParameters['Snapshot']) { $parameters['snapshot'] = $Snapshot }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/config" -Parameters $parameters
    }
}

function New-PveNodesQemuConfig
{
<#
.DESCRIPTION
Set virtual machine options (asynchrounous API).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Acpi
Enable/disable ACPI.
.PARAMETER Affinity
List of host cores used to execute guest processes, for example':' 0,5,8-11
.PARAMETER Agent
Enable/disable communication with the QEMU Guest Agent and its properties.
.PARAMETER Arch
Virtual processor architecture. Defaults to the host. Enum: x86_64,aarch64
.PARAMETER Args_
Arbitrary arguments passed to kvm.
.PARAMETER Audio0
Configure a audio device, useful in combination with QXL/Spice.
.PARAMETER Autostart
Automatic restart after crash (currently ignored).
.PARAMETER BackgroundDelay
Time to wait for the task to finish. We return 'null' if the task finish within that time.
.PARAMETER Balloon
Amount of target RAM for the VM in MiB. Using zero disables the ballon driver.
.PARAMETER Bios
Select BIOS implementation. Enum: seabios,ovmf
.PARAMETER Boot
Specify guest boot order. Use the 'order=' sub-property as usage with no key or 'legacy=' is deprecated.
.PARAMETER Bootdisk
Enable booting from specified disk. Deprecated':' Use 'boot':' order=foo;bar' instead.
.PARAMETER Cdrom
This is an alias for option -ide2
.PARAMETER Cicustom
cloud-init':' Specify custom files to replace the automatically generated ones at start.
.PARAMETER Cipassword
cloud-init':' Password to assign the user. Using this is generally not recommended. Use ssh keys instead. Also note that older cloud-init versions do not support hashed passwords.
.PARAMETER Citype
Specifies the cloud-init configuration format. The default depends on the configured operating system type (`ostype`. We use the `nocloud` format for Linux, and `configdrive2` for windows. Enum: configdrive2,nocloud,opennebula
.PARAMETER Ciupgrade
cloud-init':' do an automatic package upgrade after the first boot.
.PARAMETER Ciuser
cloud-init':' User name to change ssh keys and password for instead of the image's configured default user.
.PARAMETER Cores
The number of cores per socket.
.PARAMETER Cpu
Emulated CPU type.
.PARAMETER Cpulimit
Limit of CPU usage.
.PARAMETER Cpuunits
CPU weight for a VM, will be clamped to \[1, 10000] in cgroup v2.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Description
Description for the VM. Shown in the web-interface VM's summary. This is saved as comment inside the configuration file.
.PARAMETER Digest
Prevent changes if current configuration file has different SHA1 digest. This can be used to prevent concurrent modifications.
.PARAMETER Efidisk0
Configure a disk for storing EFI vars. Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Note that SIZE_IN_GiB is ignored here and that the default EFI vars are copied to the volume instead. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Force
Force physical removal. Without this, we simple remove the disk from the config file and create an additional configuration entry called 'unused\[n]', which contains the volume ID. Unlink of unused\[n] always cause physical removal.
.PARAMETER Freeze
Freeze CPU at startup (use 'c' monitor command to start execution).
.PARAMETER Hookscript
Script that will be executed during various steps in the vms lifetime.
.PARAMETER HostpciN
Map host PCI devices into guest.
.PARAMETER Hotplug
Selectively enable hotplug features. This is a comma separated list of hotplug features':' 'network', 'disk', 'cpu', 'memory', 'usb' and 'cloudinit'. Use '0' to disable hotplug completely. Using '1' as value is an alias for the default `network,disk,usb`. USB hotplugging is possible for guests with machine version >= 7.1 and ostype l26 or windows > 7.
.PARAMETER Hugepages
Enable/disable hugepages memory. Enum: any,2,1024
.PARAMETER IdeN
Use volume as IDE hard disk or CD-ROM (n is 0 to 3). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER IpconfigN
cloud-init':' Specify IP addresses and gateways for the corresponding interface.IP addresses use CIDR notation, gateways are optional but need an IP of the same type specified.The special string 'dhcp' can be used for IP addresses to use DHCP, in which case no explicitgateway should be provided.For IPv6 the special string 'auto' can be used to use stateless autoconfiguration. This requirescloud-init 19.4 or newer.If cloud-init is enabled and neither an IPv4 nor an IPv6 address is specified, it defaults to usingdhcp on IPv4.
.PARAMETER Ivshmem
Inter-VM shared memory. Useful for direct communication between VMs, or to the host.
.PARAMETER Keephugepages
Use together with hugepages. If enabled, hugepages will not not be deleted after VM shutdown and can be used for subsequent starts.
.PARAMETER Keyboard
Keyboard layout for VNC server. This option is generally not required and is often better handled from within the guest OS. Enum: de,de-ch,da,en-gb,en-us,es,fi,fr,fr-be,fr-ca,fr-ch,hu,is,it,ja,lt,mk,nl,no,pl,pt,pt-br,sv,sl,tr
.PARAMETER Kvm
Enable/disable KVM hardware virtualization.
.PARAMETER Localtime
Set the real time clock (RTC) to local time. This is enabled by default if the `ostype` indicates a Microsoft Windows OS.
.PARAMETER Lock
Lock/unlock the VM. Enum: backup,clone,create,migrate,rollback,snapshot,snapshot-delete,suspending,suspended
.PARAMETER Machine
Specifies the QEMU machine type.
.PARAMETER Memory
Memory properties.
.PARAMETER MigrateDowntime
Set maximum tolerated downtime (in seconds) for migrations.
.PARAMETER MigrateSpeed
Set maximum speed (in MB/s) for migrations. Value 0 is no limit.
.PARAMETER Name
Set a name for the VM. Only used on the configuration web interface.
.PARAMETER Nameserver
cloud-init':' Sets DNS server IP address for a container. Create will automatically use the setting from the host if neither searchdomain nor nameserver are set.
.PARAMETER NetN
Specify network devices.
.PARAMETER Node
The cluster node name.
.PARAMETER Numa
Enable/disable NUMA.
.PARAMETER NumaN
NUMA topology.
.PARAMETER Onboot
Specifies whether a VM will be started during system bootup.
.PARAMETER Ostype
Specify guest operating system. Enum: other,wxp,w2k,w2k3,w2k8,wvista,win7,win8,win10,win11,l24,l26,solaris
.PARAMETER ParallelN
Map host parallel devices (n is 0 to 2).
.PARAMETER Protection
Sets the protection flag of the VM. This will disable the remove VM and remove disk operations.
.PARAMETER Reboot
Allow reboot. If set to '0' the VM exit on reboot.
.PARAMETER Revert
Revert a pending change.
.PARAMETER Rng0
Configure a VirtIO-based Random Number Generator.
.PARAMETER SataN
Use volume as SATA hard disk or CD-ROM (n is 0 to 5). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER ScsiN
Use volume as SCSI hard disk or CD-ROM (n is 0 to 30). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Scsihw
SCSI controller model Enum: lsi,lsi53c810,virtio-scsi-pci,virtio-scsi-single,megasas,pvscsi
.PARAMETER Searchdomain
cloud-init':' Sets DNS search domains for a container. Create will automatically use the setting from the host if neither searchdomain nor nameserver are set.
.PARAMETER SerialN
Create a serial device inside the VM (n is 0 to 3)
.PARAMETER Shares
Amount of memory shares for auto-ballooning. The larger the number is, the more memory this VM gets. Number is relative to weights of all other running VMs. Using zero disables auto-ballooning. Auto-ballooning is done by pvestatd.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Smbios1
Specify SMBIOS type 1 fields.
.PARAMETER Smp
The number of CPUs. Please use option -sockets instead.
.PARAMETER Sockets
The number of CPU sockets.
.PARAMETER SpiceEnhancements
Configure additional enhancements for SPICE.
.PARAMETER Sshkeys
cloud-init':' Setup public SSH keys (one key per line, OpenSSH format).
.PARAMETER Startdate
Set the initial date of the real time clock. Valid format for date are':''now' or '2006-06-17T16':'01':'21' or '2006-06-17'.
.PARAMETER Startup
Startup and shutdown behavior. Order is a non-negative number defining the general startup order. Shutdown in done with reverse ordering. Additionally you can set the 'up' or 'down' delay in seconds, which specifies a delay to wait before the next VM is started or stopped.
.PARAMETER Tablet
Enable/disable the USB tablet device.
.PARAMETER Tags
Tags of the VM. This is only meta information.
.PARAMETER Tdf
Enable/disable time drift fix.
.PARAMETER Template
Enable/disable Template.
.PARAMETER Tpmstate0
Configure a Disk for storing TPM state. The format is fixed to 'raw'. Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Note that SIZE_IN_GiB is ignored here and 4 MiB will be used instead. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER UnusedN
Reference to unused volumes. This is used internally, and should not be modified manually.
.PARAMETER UsbN
Configure an USB device (n is 0 to 4, for machine version >= 7.1 and ostype l26 or windows > 7, n can be up to 14).
.PARAMETER Vcpus
Number of hotplugged vcpus.
.PARAMETER Vga
Configure the VGA hardware.
.PARAMETER VirtioN
Use volume as VIRTIO hard disk (n is 0 to 15). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Vmgenid
Set VM Generation ID. Use '1' to autogenerate on create or update, pass '0' to disable explicitly.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Vmstatestorage
Default storage for VM state volumes/files.
.PARAMETER Watchdog
Create a virtual hardware watchdog device.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Acpi,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Affinity,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Agent,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('x86_64','aarch64')]
        [string]$Arch,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Args_,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Audio0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Autostart,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$BackgroundDelay,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Balloon,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('seabios','ovmf')]
        [string]$Bios,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Boot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bootdisk,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cdrom,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cicustom,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Cipassword,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('configdrive2','nocloud','opennebula')]
        [string]$Citype,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ciupgrade,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Ciuser,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cores,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cpu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Cpulimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cpuunits,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Efidisk0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Freeze,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hookscript,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$HostpciN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hotplug,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('any','2','1024')]
        [string]$Hugepages,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$IdeN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$IpconfigN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Ivshmem,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Keephugepages,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('de','de-ch','da','en-gb','en-us','es','fi','fr','fr-be','fr-ca','fr-ch','hu','is','it','ja','lt','mk','nl','no','pl','pt','pt-br','sv','sl','tr')]
        [string]$Keyboard,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Kvm,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Localtime,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('backup','clone','create','migrate','rollback','snapshot','snapshot-delete','suspending','suspended')]
        [string]$Lock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Machine,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Memory,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$MigrateDowntime,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MigrateSpeed,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nameserver,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$NetN,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Numa,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$NumaN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Onboot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('other','wxp','w2k','w2k3','w2k8','wvista','win7','win8','win10','win11','l24','l26','solaris')]
        [string]$Ostype,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$ParallelN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Protection,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Reboot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Revert,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rng0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$SataN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$ScsiN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('lsi','lsi53c810','virtio-scsi-pci','virtio-scsi-single','megasas','pvscsi')]
        [string]$Scsihw,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Searchdomain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$SerialN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Shares,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Smbios1,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Smp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Sockets,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SpiceEnhancements,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sshkeys,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Startdate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Startup,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Tablet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tags,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Tdf,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Template,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tpmstate0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$UnusedN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$UsbN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Vcpus,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vga,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$VirtioN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vmgenid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vmstatestorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Watchdog
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Acpi']) { $parameters['acpi'] = $Acpi }
        if($PSBoundParameters['Affinity']) { $parameters['affinity'] = $Affinity }
        if($PSBoundParameters['Agent']) { $parameters['agent'] = $Agent }
        if($PSBoundParameters['Arch']) { $parameters['arch'] = $Arch }
        if($PSBoundParameters['Args_']) { $parameters['args'] = $Args_ }
        if($PSBoundParameters['Audio0']) { $parameters['audio0'] = $Audio0 }
        if($PSBoundParameters['Autostart']) { $parameters['autostart'] = $Autostart }
        if($PSBoundParameters['BackgroundDelay']) { $parameters['background_delay'] = $BackgroundDelay }
        if($PSBoundParameters['Balloon']) { $parameters['balloon'] = $Balloon }
        if($PSBoundParameters['Bios']) { $parameters['bios'] = $Bios }
        if($PSBoundParameters['Boot']) { $parameters['boot'] = $Boot }
        if($PSBoundParameters['Bootdisk']) { $parameters['bootdisk'] = $Bootdisk }
        if($PSBoundParameters['Cdrom']) { $parameters['cdrom'] = $Cdrom }
        if($PSBoundParameters['Cicustom']) { $parameters['cicustom'] = $Cicustom }
        if($PSBoundParameters['Cipassword']) { $parameters['cipassword'] = (ConvertFrom-SecureString -SecureString $Cipassword -AsPlainText) }
        if($PSBoundParameters['Citype']) { $parameters['citype'] = $Citype }
        if($PSBoundParameters['Ciupgrade']) { $parameters['ciupgrade'] = $Ciupgrade }
        if($PSBoundParameters['Ciuser']) { $parameters['ciuser'] = $Ciuser }
        if($PSBoundParameters['Cores']) { $parameters['cores'] = $Cores }
        if($PSBoundParameters['Cpu']) { $parameters['cpu'] = $Cpu }
        if($PSBoundParameters['Cpulimit']) { $parameters['cpulimit'] = $Cpulimit }
        if($PSBoundParameters['Cpuunits']) { $parameters['cpuunits'] = $Cpuunits }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Efidisk0']) { $parameters['efidisk0'] = $Efidisk0 }
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Freeze']) { $parameters['freeze'] = $Freeze }
        if($PSBoundParameters['Hookscript']) { $parameters['hookscript'] = $Hookscript }
        if($PSBoundParameters['Hotplug']) { $parameters['hotplug'] = $Hotplug }
        if($PSBoundParameters['Hugepages']) { $parameters['hugepages'] = $Hugepages }
        if($PSBoundParameters['Ivshmem']) { $parameters['ivshmem'] = $Ivshmem }
        if($PSBoundParameters['Keephugepages']) { $parameters['keephugepages'] = $Keephugepages }
        if($PSBoundParameters['Keyboard']) { $parameters['keyboard'] = $Keyboard }
        if($PSBoundParameters['Kvm']) { $parameters['kvm'] = $Kvm }
        if($PSBoundParameters['Localtime']) { $parameters['localtime'] = $Localtime }
        if($PSBoundParameters['Lock']) { $parameters['lock'] = $Lock }
        if($PSBoundParameters['Machine']) { $parameters['machine'] = $Machine }
        if($PSBoundParameters['Memory']) { $parameters['memory'] = $Memory }
        if($PSBoundParameters['MigrateDowntime']) { $parameters['migrate_downtime'] = $MigrateDowntime }
        if($PSBoundParameters['MigrateSpeed']) { $parameters['migrate_speed'] = $MigrateSpeed }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Nameserver']) { $parameters['nameserver'] = $Nameserver }
        if($PSBoundParameters['Numa']) { $parameters['numa'] = $Numa }
        if($PSBoundParameters['Onboot']) { $parameters['onboot'] = $Onboot }
        if($PSBoundParameters['Ostype']) { $parameters['ostype'] = $Ostype }
        if($PSBoundParameters['Protection']) { $parameters['protection'] = $Protection }
        if($PSBoundParameters['Reboot']) { $parameters['reboot'] = $Reboot }
        if($PSBoundParameters['Revert']) { $parameters['revert'] = $Revert }
        if($PSBoundParameters['Rng0']) { $parameters['rng0'] = $Rng0 }
        if($PSBoundParameters['Scsihw']) { $parameters['scsihw'] = $Scsihw }
        if($PSBoundParameters['Searchdomain']) { $parameters['searchdomain'] = $Searchdomain }
        if($PSBoundParameters['Shares']) { $parameters['shares'] = $Shares }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }
        if($PSBoundParameters['Smbios1']) { $parameters['smbios1'] = $Smbios1 }
        if($PSBoundParameters['Smp']) { $parameters['smp'] = $Smp }
        if($PSBoundParameters['Sockets']) { $parameters['sockets'] = $Sockets }
        if($PSBoundParameters['SpiceEnhancements']) { $parameters['spice_enhancements'] = $SpiceEnhancements }
        if($PSBoundParameters['Sshkeys']) { $parameters['sshkeys'] = $Sshkeys }
        if($PSBoundParameters['Startdate']) { $parameters['startdate'] = $Startdate }
        if($PSBoundParameters['Startup']) { $parameters['startup'] = $Startup }
        if($PSBoundParameters['Tablet']) { $parameters['tablet'] = $Tablet }
        if($PSBoundParameters['Tags']) { $parameters['tags'] = $Tags }
        if($PSBoundParameters['Tdf']) { $parameters['tdf'] = $Tdf }
        if($PSBoundParameters['Template']) { $parameters['template'] = $Template }
        if($PSBoundParameters['Tpmstate0']) { $parameters['tpmstate0'] = $Tpmstate0 }
        if($PSBoundParameters['Vcpus']) { $parameters['vcpus'] = $Vcpus }
        if($PSBoundParameters['Vga']) { $parameters['vga'] = $Vga }
        if($PSBoundParameters['Vmgenid']) { $parameters['vmgenid'] = $Vmgenid }
        if($PSBoundParameters['Vmstatestorage']) { $parameters['vmstatestorage'] = $Vmstatestorage }
        if($PSBoundParameters['Watchdog']) { $parameters['watchdog'] = $Watchdog }

        if($PSBoundParameters['HostpciN']) { $HostpciN.keys | ForEach-Object { $parameters['hostpci' + $_] = $HostpciN[$_] } }
        if($PSBoundParameters['IdeN']) { $IdeN.keys | ForEach-Object { $parameters['ide' + $_] = $IdeN[$_] } }
        if($PSBoundParameters['IpconfigN']) { $IpconfigN.keys | ForEach-Object { $parameters['ipconfig' + $_] = $IpconfigN[$_] } }
        if($PSBoundParameters['NetN']) { $NetN.keys | ForEach-Object { $parameters['net' + $_] = $NetN[$_] } }
        if($PSBoundParameters['NumaN']) { $NumaN.keys | ForEach-Object { $parameters['numa' + $_] = $NumaN[$_] } }
        if($PSBoundParameters['ParallelN']) { $ParallelN.keys | ForEach-Object { $parameters['parallel' + $_] = $ParallelN[$_] } }
        if($PSBoundParameters['SataN']) { $SataN.keys | ForEach-Object { $parameters['sata' + $_] = $SataN[$_] } }
        if($PSBoundParameters['ScsiN']) { $ScsiN.keys | ForEach-Object { $parameters['scsi' + $_] = $ScsiN[$_] } }
        if($PSBoundParameters['SerialN']) { $SerialN.keys | ForEach-Object { $parameters['serial' + $_] = $SerialN[$_] } }
        if($PSBoundParameters['UnusedN']) { $UnusedN.keys | ForEach-Object { $parameters['unused' + $_] = $UnusedN[$_] } }
        if($PSBoundParameters['UsbN']) { $UsbN.keys | ForEach-Object { $parameters['usb' + $_] = $UsbN[$_] } }
        if($PSBoundParameters['VirtioN']) { $VirtioN.keys | ForEach-Object { $parameters['virtio' + $_] = $VirtioN[$_] } }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/config" -Parameters $parameters
    }
}

function Set-PveNodesQemuConfig
{
<#
.DESCRIPTION
Set virtual machine options (synchrounous API) - You should consider using the POST method instead for any actions involving hotplug or storage allocation.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Acpi
Enable/disable ACPI.
.PARAMETER Affinity
List of host cores used to execute guest processes, for example':' 0,5,8-11
.PARAMETER Agent
Enable/disable communication with the QEMU Guest Agent and its properties.
.PARAMETER Arch
Virtual processor architecture. Defaults to the host. Enum: x86_64,aarch64
.PARAMETER Args_
Arbitrary arguments passed to kvm.
.PARAMETER Audio0
Configure a audio device, useful in combination with QXL/Spice.
.PARAMETER Autostart
Automatic restart after crash (currently ignored).
.PARAMETER Balloon
Amount of target RAM for the VM in MiB. Using zero disables the ballon driver.
.PARAMETER Bios
Select BIOS implementation. Enum: seabios,ovmf
.PARAMETER Boot
Specify guest boot order. Use the 'order=' sub-property as usage with no key or 'legacy=' is deprecated.
.PARAMETER Bootdisk
Enable booting from specified disk. Deprecated':' Use 'boot':' order=foo;bar' instead.
.PARAMETER Cdrom
This is an alias for option -ide2
.PARAMETER Cicustom
cloud-init':' Specify custom files to replace the automatically generated ones at start.
.PARAMETER Cipassword
cloud-init':' Password to assign the user. Using this is generally not recommended. Use ssh keys instead. Also note that older cloud-init versions do not support hashed passwords.
.PARAMETER Citype
Specifies the cloud-init configuration format. The default depends on the configured operating system type (`ostype`. We use the `nocloud` format for Linux, and `configdrive2` for windows. Enum: configdrive2,nocloud,opennebula
.PARAMETER Ciupgrade
cloud-init':' do an automatic package upgrade after the first boot.
.PARAMETER Ciuser
cloud-init':' User name to change ssh keys and password for instead of the image's configured default user.
.PARAMETER Cores
The number of cores per socket.
.PARAMETER Cpu
Emulated CPU type.
.PARAMETER Cpulimit
Limit of CPU usage.
.PARAMETER Cpuunits
CPU weight for a VM, will be clamped to \[1, 10000] in cgroup v2.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Description
Description for the VM. Shown in the web-interface VM's summary. This is saved as comment inside the configuration file.
.PARAMETER Digest
Prevent changes if current configuration file has different SHA1 digest. This can be used to prevent concurrent modifications.
.PARAMETER Efidisk0
Configure a disk for storing EFI vars. Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Note that SIZE_IN_GiB is ignored here and that the default EFI vars are copied to the volume instead. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Force
Force physical removal. Without this, we simple remove the disk from the config file and create an additional configuration entry called 'unused\[n]', which contains the volume ID. Unlink of unused\[n] always cause physical removal.
.PARAMETER Freeze
Freeze CPU at startup (use 'c' monitor command to start execution).
.PARAMETER Hookscript
Script that will be executed during various steps in the vms lifetime.
.PARAMETER HostpciN
Map host PCI devices into guest.
.PARAMETER Hotplug
Selectively enable hotplug features. This is a comma separated list of hotplug features':' 'network', 'disk', 'cpu', 'memory', 'usb' and 'cloudinit'. Use '0' to disable hotplug completely. Using '1' as value is an alias for the default `network,disk,usb`. USB hotplugging is possible for guests with machine version >= 7.1 and ostype l26 or windows > 7.
.PARAMETER Hugepages
Enable/disable hugepages memory. Enum: any,2,1024
.PARAMETER IdeN
Use volume as IDE hard disk or CD-ROM (n is 0 to 3). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER IpconfigN
cloud-init':' Specify IP addresses and gateways for the corresponding interface.IP addresses use CIDR notation, gateways are optional but need an IP of the same type specified.The special string 'dhcp' can be used for IP addresses to use DHCP, in which case no explicitgateway should be provided.For IPv6 the special string 'auto' can be used to use stateless autoconfiguration. This requirescloud-init 19.4 or newer.If cloud-init is enabled and neither an IPv4 nor an IPv6 address is specified, it defaults to usingdhcp on IPv4.
.PARAMETER Ivshmem
Inter-VM shared memory. Useful for direct communication between VMs, or to the host.
.PARAMETER Keephugepages
Use together with hugepages. If enabled, hugepages will not not be deleted after VM shutdown and can be used for subsequent starts.
.PARAMETER Keyboard
Keyboard layout for VNC server. This option is generally not required and is often better handled from within the guest OS. Enum: de,de-ch,da,en-gb,en-us,es,fi,fr,fr-be,fr-ca,fr-ch,hu,is,it,ja,lt,mk,nl,no,pl,pt,pt-br,sv,sl,tr
.PARAMETER Kvm
Enable/disable KVM hardware virtualization.
.PARAMETER Localtime
Set the real time clock (RTC) to local time. This is enabled by default if the `ostype` indicates a Microsoft Windows OS.
.PARAMETER Lock
Lock/unlock the VM. Enum: backup,clone,create,migrate,rollback,snapshot,snapshot-delete,suspending,suspended
.PARAMETER Machine
Specifies the QEMU machine type.
.PARAMETER Memory
Memory properties.
.PARAMETER MigrateDowntime
Set maximum tolerated downtime (in seconds) for migrations.
.PARAMETER MigrateSpeed
Set maximum speed (in MB/s) for migrations. Value 0 is no limit.
.PARAMETER Name
Set a name for the VM. Only used on the configuration web interface.
.PARAMETER Nameserver
cloud-init':' Sets DNS server IP address for a container. Create will automatically use the setting from the host if neither searchdomain nor nameserver are set.
.PARAMETER NetN
Specify network devices.
.PARAMETER Node
The cluster node name.
.PARAMETER Numa
Enable/disable NUMA.
.PARAMETER NumaN
NUMA topology.
.PARAMETER Onboot
Specifies whether a VM will be started during system bootup.
.PARAMETER Ostype
Specify guest operating system. Enum: other,wxp,w2k,w2k3,w2k8,wvista,win7,win8,win10,win11,l24,l26,solaris
.PARAMETER ParallelN
Map host parallel devices (n is 0 to 2).
.PARAMETER Protection
Sets the protection flag of the VM. This will disable the remove VM and remove disk operations.
.PARAMETER Reboot
Allow reboot. If set to '0' the VM exit on reboot.
.PARAMETER Revert
Revert a pending change.
.PARAMETER Rng0
Configure a VirtIO-based Random Number Generator.
.PARAMETER SataN
Use volume as SATA hard disk or CD-ROM (n is 0 to 5). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER ScsiN
Use volume as SCSI hard disk or CD-ROM (n is 0 to 30). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Scsihw
SCSI controller model Enum: lsi,lsi53c810,virtio-scsi-pci,virtio-scsi-single,megasas,pvscsi
.PARAMETER Searchdomain
cloud-init':' Sets DNS search domains for a container. Create will automatically use the setting from the host if neither searchdomain nor nameserver are set.
.PARAMETER SerialN
Create a serial device inside the VM (n is 0 to 3)
.PARAMETER Shares
Amount of memory shares for auto-ballooning. The larger the number is, the more memory this VM gets. Number is relative to weights of all other running VMs. Using zero disables auto-ballooning. Auto-ballooning is done by pvestatd.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Smbios1
Specify SMBIOS type 1 fields.
.PARAMETER Smp
The number of CPUs. Please use option -sockets instead.
.PARAMETER Sockets
The number of CPU sockets.
.PARAMETER SpiceEnhancements
Configure additional enhancements for SPICE.
.PARAMETER Sshkeys
cloud-init':' Setup public SSH keys (one key per line, OpenSSH format).
.PARAMETER Startdate
Set the initial date of the real time clock. Valid format for date are':''now' or '2006-06-17T16':'01':'21' or '2006-06-17'.
.PARAMETER Startup
Startup and shutdown behavior. Order is a non-negative number defining the general startup order. Shutdown in done with reverse ordering. Additionally you can set the 'up' or 'down' delay in seconds, which specifies a delay to wait before the next VM is started or stopped.
.PARAMETER Tablet
Enable/disable the USB tablet device.
.PARAMETER Tags
Tags of the VM. This is only meta information.
.PARAMETER Tdf
Enable/disable time drift fix.
.PARAMETER Template
Enable/disable Template.
.PARAMETER Tpmstate0
Configure a Disk for storing TPM state. The format is fixed to 'raw'. Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Note that SIZE_IN_GiB is ignored here and 4 MiB will be used instead. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER UnusedN
Reference to unused volumes. This is used internally, and should not be modified manually.
.PARAMETER UsbN
Configure an USB device (n is 0 to 4, for machine version >= 7.1 and ostype l26 or windows > 7, n can be up to 14).
.PARAMETER Vcpus
Number of hotplugged vcpus.
.PARAMETER Vga
Configure the VGA hardware.
.PARAMETER VirtioN
Use volume as VIRTIO hard disk (n is 0 to 15). Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume. Use STORAGE_ID':'0 and the 'import-from' parameter to import from an existing volume.
.PARAMETER Vmgenid
Set VM Generation ID. Use '1' to autogenerate on create or update, pass '0' to disable explicitly.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Vmstatestorage
Default storage for VM state volumes/files.
.PARAMETER Watchdog
Create a virtual hardware watchdog device.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Acpi,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Affinity,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Agent,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('x86_64','aarch64')]
        [string]$Arch,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Args_,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Audio0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Autostart,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Balloon,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('seabios','ovmf')]
        [string]$Bios,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Boot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bootdisk,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cdrom,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cicustom,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Cipassword,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('configdrive2','nocloud','opennebula')]
        [string]$Citype,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ciupgrade,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Ciuser,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cores,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cpu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Cpulimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cpuunits,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Efidisk0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Freeze,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hookscript,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$HostpciN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hotplug,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('any','2','1024')]
        [string]$Hugepages,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$IdeN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$IpconfigN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Ivshmem,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Keephugepages,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('de','de-ch','da','en-gb','en-us','es','fi','fr','fr-be','fr-ca','fr-ch','hu','is','it','ja','lt','mk','nl','no','pl','pt','pt-br','sv','sl','tr')]
        [string]$Keyboard,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Kvm,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Localtime,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('backup','clone','create','migrate','rollback','snapshot','snapshot-delete','suspending','suspended')]
        [string]$Lock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Machine,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Memory,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$MigrateDowntime,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MigrateSpeed,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nameserver,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$NetN,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Numa,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$NumaN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Onboot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('other','wxp','w2k','w2k3','w2k8','wvista','win7','win8','win10','win11','l24','l26','solaris')]
        [string]$Ostype,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$ParallelN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Protection,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Reboot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Revert,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rng0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$SataN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$ScsiN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('lsi','lsi53c810','virtio-scsi-pci','virtio-scsi-single','megasas','pvscsi')]
        [string]$Scsihw,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Searchdomain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$SerialN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Shares,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Smbios1,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Smp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Sockets,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SpiceEnhancements,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sshkeys,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Startdate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Startup,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Tablet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tags,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Tdf,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Template,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tpmstate0,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$UnusedN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$UsbN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Vcpus,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vga,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$VirtioN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vmgenid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vmstatestorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Watchdog
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Acpi']) { $parameters['acpi'] = $Acpi }
        if($PSBoundParameters['Affinity']) { $parameters['affinity'] = $Affinity }
        if($PSBoundParameters['Agent']) { $parameters['agent'] = $Agent }
        if($PSBoundParameters['Arch']) { $parameters['arch'] = $Arch }
        if($PSBoundParameters['Args_']) { $parameters['args'] = $Args_ }
        if($PSBoundParameters['Audio0']) { $parameters['audio0'] = $Audio0 }
        if($PSBoundParameters['Autostart']) { $parameters['autostart'] = $Autostart }
        if($PSBoundParameters['Balloon']) { $parameters['balloon'] = $Balloon }
        if($PSBoundParameters['Bios']) { $parameters['bios'] = $Bios }
        if($PSBoundParameters['Boot']) { $parameters['boot'] = $Boot }
        if($PSBoundParameters['Bootdisk']) { $parameters['bootdisk'] = $Bootdisk }
        if($PSBoundParameters['Cdrom']) { $parameters['cdrom'] = $Cdrom }
        if($PSBoundParameters['Cicustom']) { $parameters['cicustom'] = $Cicustom }
        if($PSBoundParameters['Cipassword']) { $parameters['cipassword'] = (ConvertFrom-SecureString -SecureString $Cipassword -AsPlainText) }
        if($PSBoundParameters['Citype']) { $parameters['citype'] = $Citype }
        if($PSBoundParameters['Ciupgrade']) { $parameters['ciupgrade'] = $Ciupgrade }
        if($PSBoundParameters['Ciuser']) { $parameters['ciuser'] = $Ciuser }
        if($PSBoundParameters['Cores']) { $parameters['cores'] = $Cores }
        if($PSBoundParameters['Cpu']) { $parameters['cpu'] = $Cpu }
        if($PSBoundParameters['Cpulimit']) { $parameters['cpulimit'] = $Cpulimit }
        if($PSBoundParameters['Cpuunits']) { $parameters['cpuunits'] = $Cpuunits }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Efidisk0']) { $parameters['efidisk0'] = $Efidisk0 }
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Freeze']) { $parameters['freeze'] = $Freeze }
        if($PSBoundParameters['Hookscript']) { $parameters['hookscript'] = $Hookscript }
        if($PSBoundParameters['Hotplug']) { $parameters['hotplug'] = $Hotplug }
        if($PSBoundParameters['Hugepages']) { $parameters['hugepages'] = $Hugepages }
        if($PSBoundParameters['Ivshmem']) { $parameters['ivshmem'] = $Ivshmem }
        if($PSBoundParameters['Keephugepages']) { $parameters['keephugepages'] = $Keephugepages }
        if($PSBoundParameters['Keyboard']) { $parameters['keyboard'] = $Keyboard }
        if($PSBoundParameters['Kvm']) { $parameters['kvm'] = $Kvm }
        if($PSBoundParameters['Localtime']) { $parameters['localtime'] = $Localtime }
        if($PSBoundParameters['Lock']) { $parameters['lock'] = $Lock }
        if($PSBoundParameters['Machine']) { $parameters['machine'] = $Machine }
        if($PSBoundParameters['Memory']) { $parameters['memory'] = $Memory }
        if($PSBoundParameters['MigrateDowntime']) { $parameters['migrate_downtime'] = $MigrateDowntime }
        if($PSBoundParameters['MigrateSpeed']) { $parameters['migrate_speed'] = $MigrateSpeed }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Nameserver']) { $parameters['nameserver'] = $Nameserver }
        if($PSBoundParameters['Numa']) { $parameters['numa'] = $Numa }
        if($PSBoundParameters['Onboot']) { $parameters['onboot'] = $Onboot }
        if($PSBoundParameters['Ostype']) { $parameters['ostype'] = $Ostype }
        if($PSBoundParameters['Protection']) { $parameters['protection'] = $Protection }
        if($PSBoundParameters['Reboot']) { $parameters['reboot'] = $Reboot }
        if($PSBoundParameters['Revert']) { $parameters['revert'] = $Revert }
        if($PSBoundParameters['Rng0']) { $parameters['rng0'] = $Rng0 }
        if($PSBoundParameters['Scsihw']) { $parameters['scsihw'] = $Scsihw }
        if($PSBoundParameters['Searchdomain']) { $parameters['searchdomain'] = $Searchdomain }
        if($PSBoundParameters['Shares']) { $parameters['shares'] = $Shares }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }
        if($PSBoundParameters['Smbios1']) { $parameters['smbios1'] = $Smbios1 }
        if($PSBoundParameters['Smp']) { $parameters['smp'] = $Smp }
        if($PSBoundParameters['Sockets']) { $parameters['sockets'] = $Sockets }
        if($PSBoundParameters['SpiceEnhancements']) { $parameters['spice_enhancements'] = $SpiceEnhancements }
        if($PSBoundParameters['Sshkeys']) { $parameters['sshkeys'] = $Sshkeys }
        if($PSBoundParameters['Startdate']) { $parameters['startdate'] = $Startdate }
        if($PSBoundParameters['Startup']) { $parameters['startup'] = $Startup }
        if($PSBoundParameters['Tablet']) { $parameters['tablet'] = $Tablet }
        if($PSBoundParameters['Tags']) { $parameters['tags'] = $Tags }
        if($PSBoundParameters['Tdf']) { $parameters['tdf'] = $Tdf }
        if($PSBoundParameters['Template']) { $parameters['template'] = $Template }
        if($PSBoundParameters['Tpmstate0']) { $parameters['tpmstate0'] = $Tpmstate0 }
        if($PSBoundParameters['Vcpus']) { $parameters['vcpus'] = $Vcpus }
        if($PSBoundParameters['Vga']) { $parameters['vga'] = $Vga }
        if($PSBoundParameters['Vmgenid']) { $parameters['vmgenid'] = $Vmgenid }
        if($PSBoundParameters['Vmstatestorage']) { $parameters['vmstatestorage'] = $Vmstatestorage }
        if($PSBoundParameters['Watchdog']) { $parameters['watchdog'] = $Watchdog }

        if($PSBoundParameters['HostpciN']) { $HostpciN.keys | ForEach-Object { $parameters['hostpci' + $_] = $HostpciN[$_] } }
        if($PSBoundParameters['IdeN']) { $IdeN.keys | ForEach-Object { $parameters['ide' + $_] = $IdeN[$_] } }
        if($PSBoundParameters['IpconfigN']) { $IpconfigN.keys | ForEach-Object { $parameters['ipconfig' + $_] = $IpconfigN[$_] } }
        if($PSBoundParameters['NetN']) { $NetN.keys | ForEach-Object { $parameters['net' + $_] = $NetN[$_] } }
        if($PSBoundParameters['NumaN']) { $NumaN.keys | ForEach-Object { $parameters['numa' + $_] = $NumaN[$_] } }
        if($PSBoundParameters['ParallelN']) { $ParallelN.keys | ForEach-Object { $parameters['parallel' + $_] = $ParallelN[$_] } }
        if($PSBoundParameters['SataN']) { $SataN.keys | ForEach-Object { $parameters['sata' + $_] = $SataN[$_] } }
        if($PSBoundParameters['ScsiN']) { $ScsiN.keys | ForEach-Object { $parameters['scsi' + $_] = $ScsiN[$_] } }
        if($PSBoundParameters['SerialN']) { $SerialN.keys | ForEach-Object { $parameters['serial' + $_] = $SerialN[$_] } }
        if($PSBoundParameters['UnusedN']) { $UnusedN.keys | ForEach-Object { $parameters['unused' + $_] = $UnusedN[$_] } }
        if($PSBoundParameters['UsbN']) { $UsbN.keys | ForEach-Object { $parameters['usb' + $_] = $UsbN[$_] } }
        if($PSBoundParameters['VirtioN']) { $VirtioN.keys | ForEach-Object { $parameters['virtio' + $_] = $VirtioN[$_] } }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/config" -Parameters $parameters
    }
}

function Get-PveNodesQemuPending
{
<#
.DESCRIPTION
Get the virtual machine configuration with both current and pending values.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/pending"
    }
}

function Get-PveNodesQemuCloudinit
{
<#
.DESCRIPTION
Get the cloudinit configuration with both current and pending values.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/cloudinit"
    }
}

function Set-PveNodesQemuCloudinit
{
<#
.DESCRIPTION
Regenerate and change cloudinit config drive.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/cloudinit"
    }
}

function Get-PveNodesQemuCloudinitDump
{
<#
.DESCRIPTION
Get automatically generated cloudinit config.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Type
Config type. Enum: user,network,meta
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('user','network','meta')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/cloudinit/dump" -Parameters $parameters
    }
}

function Set-PveNodesQemuUnlink
{
<#
.DESCRIPTION
Unlink/delete disk images.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
Force physical removal. Without this, we simple remove the disk from the config file and create an additional configuration entry called 'unused\[n]', which contains the volume ID. Unlink of unused\[n] always cause physical removal.
.PARAMETER Idlist
A list of disk IDs you want to delete.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Idlist,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Idlist']) { $parameters['idlist'] = $Idlist }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/unlink" -Parameters $parameters
    }
}

function New-PveNodesQemuVncproxy
{
<#
.DESCRIPTION
Creates a TCP VNC proxy connections.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER GeneratePassword
Generates a random password to be used as ticket instead of the API ticket.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Websocket
Prepare for websocket upgrade (only required when using serial terminal, otherwise upgrade is always possible).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$GeneratePassword,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Websocket
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['GeneratePassword']) { $parameters['generate-password'] = $GeneratePassword }
        if($PSBoundParameters['Websocket']) { $parameters['websocket'] = $Websocket }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/vncproxy" -Parameters $parameters
    }
}

function New-PveNodesQemuTermproxy
{
<#
.DESCRIPTION
Creates a TCP proxy connections.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Serial
opens a serial terminal (defaults to display) Enum: serial0,serial1,serial2,serial3
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('serial0','serial1','serial2','serial3')]
        [string]$Serial,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Serial']) { $parameters['serial'] = $Serial }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/termproxy" -Parameters $parameters
    }
}

function Get-PveNodesQemuVncwebsocket
{
<#
.DESCRIPTION
Opens a weksocket for VNC traffic.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Port
Port number returned by previous vncproxy call.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Vncticket
Ticket from previous call to vncproxy.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vncticket
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Vncticket']) { $parameters['vncticket'] = $Vncticket }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/vncwebsocket" -Parameters $parameters
    }
}

function New-PveNodesQemuSpiceproxy
{
<#
.DESCRIPTION
Returns a SPICE configuration to connect to the VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Proxy
SPICE proxy server. This can be used by the client to specify the proxy server. All nodes in a cluster runs 'spiceproxy', so it is up to the client to choose one. By default, we return the node where the VM is currently running. As reasonable setting is to use same node you use to connect to the API (This is window.location.hostname for the JS GUI).
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proxy,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Proxy']) { $parameters['proxy'] = $Proxy }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/spiceproxy" -Parameters $parameters
    }
}

function Get-PveNodesQemuStatus
{
<#
.DESCRIPTION
Directory index
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/status"
    }
}

function Get-PveNodesQemuStatusCurrent
{
<#
.DESCRIPTION
Get virtual machine status.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/status/current"
    }
}

function New-PveNodesQemuStatusStart
{
<#
.DESCRIPTION
Start virtual machine.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER ForceCpu
Override QEMU's -cpu argument with the given string.
.PARAMETER Machine
Specifies the QEMU machine type.
.PARAMETER Migratedfrom
The cluster node name.
.PARAMETER MigrationNetwork
CIDR of the (sub) network that is used for migration.
.PARAMETER MigrationType
Migration traffic is encrypted using an SSH tunnel by default. On secure, completely private networks this can be disabled to increase performance. Enum: secure,insecure
.PARAMETER Node
The cluster node name.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Stateuri
Some command save/restore state from this location.
.PARAMETER Targetstorage
Mapping from source to target storages. Providing only a single storage ID maps all source storages to that storage. Providing the special value '1' will map each source storage to itself.
.PARAMETER Timeout
Wait maximal timeout seconds.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ForceCpu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Machine,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Migratedfrom,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$MigrationNetwork,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('secure','insecure')]
        [string]$MigrationType,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Stateuri,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Targetstorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['ForceCpu']) { $parameters['force-cpu'] = $ForceCpu }
        if($PSBoundParameters['Machine']) { $parameters['machine'] = $Machine }
        if($PSBoundParameters['Migratedfrom']) { $parameters['migratedfrom'] = $Migratedfrom }
        if($PSBoundParameters['MigrationNetwork']) { $parameters['migration_network'] = $MigrationNetwork }
        if($PSBoundParameters['MigrationType']) { $parameters['migration_type'] = $MigrationType }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }
        if($PSBoundParameters['Stateuri']) { $parameters['stateuri'] = $Stateuri }
        if($PSBoundParameters['Targetstorage']) { $parameters['targetstorage'] = $Targetstorage }
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/status/start" -Parameters $parameters
    }
}

function New-PveNodesQemuStatusStop
{
<#
.DESCRIPTION
Stop virtual machine. The qemu process will exit immediately. Thisis akin to pulling the power plug of a running computer and may damage the VM data
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Keepactive
Do not deactivate storage volumes.
.PARAMETER Migratedfrom
The cluster node name.
.PARAMETER Node
The cluster node name.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Timeout
Wait maximal timeout seconds.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Keepactive,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Migratedfrom,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Keepactive']) { $parameters['keepActive'] = $Keepactive }
        if($PSBoundParameters['Migratedfrom']) { $parameters['migratedfrom'] = $Migratedfrom }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/status/stop" -Parameters $parameters
    }
}

function New-PveNodesQemuStatusReset
{
<#
.DESCRIPTION
Reset virtual machine.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/status/reset" -Parameters $parameters
    }
}

function New-PveNodesQemuStatusShutdown
{
<#
.DESCRIPTION
Shutdown virtual machine. This is similar to pressing the power button on a physical machine.This will send an ACPI event for the guest OS, which should then proceed to a clean shutdown.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Forcestop
Make sure the VM stops.
.PARAMETER Keepactive
Do not deactivate storage volumes.
.PARAMETER Node
The cluster node name.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Timeout
Wait maximal timeout seconds.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Forcestop,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Keepactive,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Forcestop']) { $parameters['forceStop'] = $Forcestop }
        if($PSBoundParameters['Keepactive']) { $parameters['keepActive'] = $Keepactive }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/status/shutdown" -Parameters $parameters
    }
}

function New-PveNodesQemuStatusReboot
{
<#
.DESCRIPTION
Reboot the VM by shutting it down, and starting it again. Applies pending changes.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Timeout
Wait maximal timeout seconds for the shutdown.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/status/reboot" -Parameters $parameters
    }
}

function New-PveNodesQemuStatusSuspend
{
<#
.DESCRIPTION
Suspend virtual machine.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Statestorage
The storage for the VM state
.PARAMETER Todisk
If set, suspends the VM to disk. Will be resumed on next VM start.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Statestorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Todisk,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }
        if($PSBoundParameters['Statestorage']) { $parameters['statestorage'] = $Statestorage }
        if($PSBoundParameters['Todisk']) { $parameters['todisk'] = $Todisk }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/status/suspend" -Parameters $parameters
    }
}

function New-PveNodesQemuStatusResume
{
<#
.DESCRIPTION
Resume virtual machine.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Nocheck
--
.PARAMETER Node
The cluster node name.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nocheck,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Nocheck']) { $parameters['nocheck'] = $Nocheck }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/status/resume" -Parameters $parameters
    }
}

function Set-PveNodesQemuSendkey
{
<#
.DESCRIPTION
Send key event to virtual machine.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Key
The key (qemu monitor encoding).
.PARAMETER Node
The cluster node name.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Key,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Key']) { $parameters['key'] = $Key }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/sendkey" -Parameters $parameters
    }
}

function Get-PveNodesQemuFeature
{
<#
.DESCRIPTION
Check if feature for virtual machine is available.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Feature
Feature to check. Enum: snapshot,clone,copy
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('snapshot','clone','copy')]
        [string]$Feature,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Feature']) { $parameters['feature'] = $Feature }
        if($PSBoundParameters['Snapname']) { $parameters['snapname'] = $Snapname }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/feature" -Parameters $parameters
    }
}

function New-PveNodesQemuClone
{
<#
.DESCRIPTION
Create a copy of virtual machine/template.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Description
Description for the new VM.
.PARAMETER Format
Target format for file storage. Only valid for full clone. Enum: raw,qcow2,vmdk
.PARAMETER Full
Create a full copy of all disks. This is always done when you clone a normal VM. For VM templates, we try to create a linked clone by default.
.PARAMETER Name
Set a name for the new VM.
.PARAMETER Newid
VMID for the clone.
.PARAMETER Node
The cluster node name.
.PARAMETER Pool
Add the new VM to the specified pool.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Storage
Target storage for full clone.
.PARAMETER Target
Target node. Only allowed if the original VM is on shared storage.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('raw','qcow2','vmdk')]
        [string]$Format,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Full,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Newid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Pool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Target,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Format']) { $parameters['format'] = $Format }
        if($PSBoundParameters['Full']) { $parameters['full'] = $Full }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Newid']) { $parameters['newid'] = $Newid }
        if($PSBoundParameters['Pool']) { $parameters['pool'] = $Pool }
        if($PSBoundParameters['Snapname']) { $parameters['snapname'] = $Snapname }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/clone" -Parameters $parameters
    }
}

function New-PveNodesQemuMoveDisk
{
<#
.DESCRIPTION
Move volume to different storage or to a different VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Delete
Delete the original disk after successful copy. By default the original disk is kept as unused disk.
.PARAMETER Digest
Prevent changes if current configuration file has different SHA1"		    ." digest. This can be used to prevent concurrent modifications.
.PARAMETER Disk
The disk you want to move. Enum: ide0,ide1,ide2,ide3,scsi0,scsi1,scsi2,scsi3,scsi4,scsi5,scsi6,scsi7,scsi8,scsi9,scsi10,scsi11,scsi12,scsi13,scsi14,scsi15,scsi16,scsi17,scsi18,scsi19,scsi20,scsi21,scsi22,scsi23,scsi24,scsi25,scsi26,scsi27,scsi28,scsi29,scsi30,virtio0,virtio1,virtio2,virtio3,virtio4,virtio5,virtio6,virtio7,virtio8,virtio9,virtio10,virtio11,virtio12,virtio13,virtio14,virtio15,sata0,sata1,sata2,sata3,sata4,sata5,efidisk0,tpmstate0,unused0,unused1,unused2,unused3,unused4,unused5,unused6,unused7,unused8,unused9,unused10,unused11,unused12,unused13,unused14,unused15,unused16,unused17,unused18,unused19,unused20,unused21,unused22,unused23,unused24,unused25,unused26,unused27,unused28,unused29,unused30,unused31,unused32,unused33,unused34,unused35,unused36,unused37,unused38,unused39,unused40,unused41,unused42,unused43,unused44,unused45,unused46,unused47,unused48,unused49,unused50,unused51,unused52,unused53,unused54,unused55,unused56,unused57,unused58,unused59,unused60,unused61,unused62,unused63,unused64,unused65,unused66,unused67,unused68,unused69,unused70,unused71,unused72,unused73,unused74,unused75,unused76,unused77,unused78,unused79,unused80,unused81,unused82,unused83,unused84,unused85,unused86,unused87,unused88,unused89,unused90,unused91,unused92,unused93,unused94,unused95,unused96,unused97,unused98,unused99,unused100,unused101,unused102,unused103,unused104,unused105,unused106,unused107,unused108,unused109,unused110,unused111,unused112,unused113,unused114,unused115,unused116,unused117,unused118,unused119,unused120,unused121,unused122,unused123,unused124,unused125,unused126,unused127,unused128,unused129,unused130,unused131,unused132,unused133,unused134,unused135,unused136,unused137,unused138,unused139,unused140,unused141,unused142,unused143,unused144,unused145,unused146,unused147,unused148,unused149,unused150,unused151,unused152,unused153,unused154,unused155,unused156,unused157,unused158,unused159,unused160,unused161,unused162,unused163,unused164,unused165,unused166,unused167,unused168,unused169,unused170,unused171,unused172,unused173,unused174,unused175,unused176,unused177,unused178,unused179,unused180,unused181,unused182,unused183,unused184,unused185,unused186,unused187,unused188,unused189,unused190,unused191,unused192,unused193,unused194,unused195,unused196,unused197,unused198,unused199,unused200,unused201,unused202,unused203,unused204,unused205,unused206,unused207,unused208,unused209,unused210,unused211,unused212,unused213,unused214,unused215,unused216,unused217,unused218,unused219,unused220,unused221,unused222,unused223,unused224,unused225,unused226,unused227,unused228,unused229,unused230,unused231,unused232,unused233,unused234,unused235,unused236,unused237,unused238,unused239,unused240,unused241,unused242,unused243,unused244,unused245,unused246,unused247,unused248,unused249,unused250,unused251,unused252,unused253,unused254,unused255
.PARAMETER Format
Target Format. Enum: raw,qcow2,vmdk
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
Target storage.
.PARAMETER TargetDigest
Prevent changes if the current config file of the target VM has a"		    ." different SHA1 digest. This can be used to detect concurrent modifications.
.PARAMETER TargetDisk
The config key the disk will be moved to on the target VM (for example, ide0 or scsi1). Default is the source disk key. Enum: ide0,ide1,ide2,ide3,scsi0,scsi1,scsi2,scsi3,scsi4,scsi5,scsi6,scsi7,scsi8,scsi9,scsi10,scsi11,scsi12,scsi13,scsi14,scsi15,scsi16,scsi17,scsi18,scsi19,scsi20,scsi21,scsi22,scsi23,scsi24,scsi25,scsi26,scsi27,scsi28,scsi29,scsi30,virtio0,virtio1,virtio2,virtio3,virtio4,virtio5,virtio6,virtio7,virtio8,virtio9,virtio10,virtio11,virtio12,virtio13,virtio14,virtio15,sata0,sata1,sata2,sata3,sata4,sata5,efidisk0,tpmstate0,unused0,unused1,unused2,unused3,unused4,unused5,unused6,unused7,unused8,unused9,unused10,unused11,unused12,unused13,unused14,unused15,unused16,unused17,unused18,unused19,unused20,unused21,unused22,unused23,unused24,unused25,unused26,unused27,unused28,unused29,unused30,unused31,unused32,unused33,unused34,unused35,unused36,unused37,unused38,unused39,unused40,unused41,unused42,unused43,unused44,unused45,unused46,unused47,unused48,unused49,unused50,unused51,unused52,unused53,unused54,unused55,unused56,unused57,unused58,unused59,unused60,unused61,unused62,unused63,unused64,unused65,unused66,unused67,unused68,unused69,unused70,unused71,unused72,unused73,unused74,unused75,unused76,unused77,unused78,unused79,unused80,unused81,unused82,unused83,unused84,unused85,unused86,unused87,unused88,unused89,unused90,unused91,unused92,unused93,unused94,unused95,unused96,unused97,unused98,unused99,unused100,unused101,unused102,unused103,unused104,unused105,unused106,unused107,unused108,unused109,unused110,unused111,unused112,unused113,unused114,unused115,unused116,unused117,unused118,unused119,unused120,unused121,unused122,unused123,unused124,unused125,unused126,unused127,unused128,unused129,unused130,unused131,unused132,unused133,unused134,unused135,unused136,unused137,unused138,unused139,unused140,unused141,unused142,unused143,unused144,unused145,unused146,unused147,unused148,unused149,unused150,unused151,unused152,unused153,unused154,unused155,unused156,unused157,unused158,unused159,unused160,unused161,unused162,unused163,unused164,unused165,unused166,unused167,unused168,unused169,unused170,unused171,unused172,unused173,unused174,unused175,unused176,unused177,unused178,unused179,unused180,unused181,unused182,unused183,unused184,unused185,unused186,unused187,unused188,unused189,unused190,unused191,unused192,unused193,unused194,unused195,unused196,unused197,unused198,unused199,unused200,unused201,unused202,unused203,unused204,unused205,unused206,unused207,unused208,unused209,unused210,unused211,unused212,unused213,unused214,unused215,unused216,unused217,unused218,unused219,unused220,unused221,unused222,unused223,unused224,unused225,unused226,unused227,unused228,unused229,unused230,unused231,unused232,unused233,unused234,unused235,unused236,unused237,unused238,unused239,unused240,unused241,unused242,unused243,unused244,unused245,unused246,unused247,unused248,unused249,unused250,unused251,unused252,unused253,unused254,unused255
.PARAMETER TargetVmid
The (unique) ID of the VM.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('ide0','ide1','ide2','ide3','scsi0','scsi1','scsi2','scsi3','scsi4','scsi5','scsi6','scsi7','scsi8','scsi9','scsi10','scsi11','scsi12','scsi13','scsi14','scsi15','scsi16','scsi17','scsi18','scsi19','scsi20','scsi21','scsi22','scsi23','scsi24','scsi25','scsi26','scsi27','scsi28','scsi29','scsi30','virtio0','virtio1','virtio2','virtio3','virtio4','virtio5','virtio6','virtio7','virtio8','virtio9','virtio10','virtio11','virtio12','virtio13','virtio14','virtio15','sata0','sata1','sata2','sata3','sata4','sata5','efidisk0','tpmstate0','unused0','unused1','unused2','unused3','unused4','unused5','unused6','unused7','unused8','unused9','unused10','unused11','unused12','unused13','unused14','unused15','unused16','unused17','unused18','unused19','unused20','unused21','unused22','unused23','unused24','unused25','unused26','unused27','unused28','unused29','unused30','unused31','unused32','unused33','unused34','unused35','unused36','unused37','unused38','unused39','unused40','unused41','unused42','unused43','unused44','unused45','unused46','unused47','unused48','unused49','unused50','unused51','unused52','unused53','unused54','unused55','unused56','unused57','unused58','unused59','unused60','unused61','unused62','unused63','unused64','unused65','unused66','unused67','unused68','unused69','unused70','unused71','unused72','unused73','unused74','unused75','unused76','unused77','unused78','unused79','unused80','unused81','unused82','unused83','unused84','unused85','unused86','unused87','unused88','unused89','unused90','unused91','unused92','unused93','unused94','unused95','unused96','unused97','unused98','unused99','unused100','unused101','unused102','unused103','unused104','unused105','unused106','unused107','unused108','unused109','unused110','unused111','unused112','unused113','unused114','unused115','unused116','unused117','unused118','unused119','unused120','unused121','unused122','unused123','unused124','unused125','unused126','unused127','unused128','unused129','unused130','unused131','unused132','unused133','unused134','unused135','unused136','unused137','unused138','unused139','unused140','unused141','unused142','unused143','unused144','unused145','unused146','unused147','unused148','unused149','unused150','unused151','unused152','unused153','unused154','unused155','unused156','unused157','unused158','unused159','unused160','unused161','unused162','unused163','unused164','unused165','unused166','unused167','unused168','unused169','unused170','unused171','unused172','unused173','unused174','unused175','unused176','unused177','unused178','unused179','unused180','unused181','unused182','unused183','unused184','unused185','unused186','unused187','unused188','unused189','unused190','unused191','unused192','unused193','unused194','unused195','unused196','unused197','unused198','unused199','unused200','unused201','unused202','unused203','unused204','unused205','unused206','unused207','unused208','unused209','unused210','unused211','unused212','unused213','unused214','unused215','unused216','unused217','unused218','unused219','unused220','unused221','unused222','unused223','unused224','unused225','unused226','unused227','unused228','unused229','unused230','unused231','unused232','unused233','unused234','unused235','unused236','unused237','unused238','unused239','unused240','unused241','unused242','unused243','unused244','unused245','unused246','unused247','unused248','unused249','unused250','unused251','unused252','unused253','unused254','unused255')]
        [string]$Disk,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('raw','qcow2','vmdk')]
        [string]$Format,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$TargetDigest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ide0','ide1','ide2','ide3','scsi0','scsi1','scsi2','scsi3','scsi4','scsi5','scsi6','scsi7','scsi8','scsi9','scsi10','scsi11','scsi12','scsi13','scsi14','scsi15','scsi16','scsi17','scsi18','scsi19','scsi20','scsi21','scsi22','scsi23','scsi24','scsi25','scsi26','scsi27','scsi28','scsi29','scsi30','virtio0','virtio1','virtio2','virtio3','virtio4','virtio5','virtio6','virtio7','virtio8','virtio9','virtio10','virtio11','virtio12','virtio13','virtio14','virtio15','sata0','sata1','sata2','sata3','sata4','sata5','efidisk0','tpmstate0','unused0','unused1','unused2','unused3','unused4','unused5','unused6','unused7','unused8','unused9','unused10','unused11','unused12','unused13','unused14','unused15','unused16','unused17','unused18','unused19','unused20','unused21','unused22','unused23','unused24','unused25','unused26','unused27','unused28','unused29','unused30','unused31','unused32','unused33','unused34','unused35','unused36','unused37','unused38','unused39','unused40','unused41','unused42','unused43','unused44','unused45','unused46','unused47','unused48','unused49','unused50','unused51','unused52','unused53','unused54','unused55','unused56','unused57','unused58','unused59','unused60','unused61','unused62','unused63','unused64','unused65','unused66','unused67','unused68','unused69','unused70','unused71','unused72','unused73','unused74','unused75','unused76','unused77','unused78','unused79','unused80','unused81','unused82','unused83','unused84','unused85','unused86','unused87','unused88','unused89','unused90','unused91','unused92','unused93','unused94','unused95','unused96','unused97','unused98','unused99','unused100','unused101','unused102','unused103','unused104','unused105','unused106','unused107','unused108','unused109','unused110','unused111','unused112','unused113','unused114','unused115','unused116','unused117','unused118','unused119','unused120','unused121','unused122','unused123','unused124','unused125','unused126','unused127','unused128','unused129','unused130','unused131','unused132','unused133','unused134','unused135','unused136','unused137','unused138','unused139','unused140','unused141','unused142','unused143','unused144','unused145','unused146','unused147','unused148','unused149','unused150','unused151','unused152','unused153','unused154','unused155','unused156','unused157','unused158','unused159','unused160','unused161','unused162','unused163','unused164','unused165','unused166','unused167','unused168','unused169','unused170','unused171','unused172','unused173','unused174','unused175','unused176','unused177','unused178','unused179','unused180','unused181','unused182','unused183','unused184','unused185','unused186','unused187','unused188','unused189','unused190','unused191','unused192','unused193','unused194','unused195','unused196','unused197','unused198','unused199','unused200','unused201','unused202','unused203','unused204','unused205','unused206','unused207','unused208','unused209','unused210','unused211','unused212','unused213','unused214','unused215','unused216','unused217','unused218','unused219','unused220','unused221','unused222','unused223','unused224','unused225','unused226','unused227','unused228','unused229','unused230','unused231','unused232','unused233','unused234','unused235','unused236','unused237','unused238','unused239','unused240','unused241','unused242','unused243','unused244','unused245','unused246','unused247','unused248','unused249','unused250','unused251','unused252','unused253','unused254','unused255')]
        [string]$TargetDisk,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$TargetVmid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disk']) { $parameters['disk'] = $Disk }
        if($PSBoundParameters['Format']) { $parameters['format'] = $Format }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['TargetDigest']) { $parameters['target-digest'] = $TargetDigest }
        if($PSBoundParameters['TargetDisk']) { $parameters['target-disk'] = $TargetDisk }
        if($PSBoundParameters['TargetVmid']) { $parameters['target-vmid'] = $TargetVmid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/move_disk" -Parameters $parameters
    }
}

function Get-PveNodesQemuMigrate
{
<#
.DESCRIPTION
Get preconditions for migration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Target
Target node.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Target,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/migrate" -Parameters $parameters
    }
}

function New-PveNodesQemuMigrate
{
<#
.DESCRIPTION
Migrate virtual machine. Creates a new migration task.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Force
Allow to migrate VMs which use local devices. Only root may use this option.
.PARAMETER MigrationNetwork
CIDR of the (sub) network that is used for migration.
.PARAMETER MigrationType
Migration traffic is encrypted using an SSH tunnel by default. On secure, completely private networks this can be disabled to increase performance. Enum: secure,insecure
.PARAMETER Node
The cluster node name.
.PARAMETER Online
Use online/live migration if VM is running. Ignored if VM is stopped.
.PARAMETER Target
Target node.
.PARAMETER Targetstorage
Mapping from source to target storages. Providing only a single storage ID maps all source storages to that storage. Providing the special value '1' will map each source storage to itself.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER WithLocalDisks
Enable live storage migration for local disk
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$MigrationNetwork,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('secure','insecure')]
        [string]$MigrationType,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Online,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Target,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Targetstorage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$WithLocalDisks
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['MigrationNetwork']) { $parameters['migration_network'] = $MigrationNetwork }
        if($PSBoundParameters['MigrationType']) { $parameters['migration_type'] = $MigrationType }
        if($PSBoundParameters['Online']) { $parameters['online'] = $Online }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }
        if($PSBoundParameters['Targetstorage']) { $parameters['targetstorage'] = $Targetstorage }
        if($PSBoundParameters['WithLocalDisks']) { $parameters['with-local-disks'] = $WithLocalDisks }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/migrate" -Parameters $parameters
    }
}

function New-PveNodesQemuRemoteMigrate
{
<#
.DESCRIPTION
Migrate virtual machine to a remote cluster. Creates a new migration task. EXPERIMENTAL feature!
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Delete
Delete the original VM and related data after successful migration. By default the original VM is kept on the source cluster in a stopped state.
.PARAMETER Node
The cluster node name.
.PARAMETER Online
Use online/live migration if VM is running. Ignored if VM is stopped.
.PARAMETER TargetBridge
Mapping from source to target bridges. Providing only a single bridge ID maps all source bridges to that bridge. Providing the special value '1' will map each source bridge to itself.
.PARAMETER TargetEndpoint
Remote target endpoint
.PARAMETER TargetStorage
Mapping from source to target storages. Providing only a single storage ID maps all source storages to that storage. Providing the special value '1' will map each source storage to itself.
.PARAMETER TargetVmid
The (unique) ID of the VM.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Delete,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Online,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$TargetBridge,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$TargetEndpoint,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$TargetStorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$TargetVmid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Online']) { $parameters['online'] = $Online }
        if($PSBoundParameters['TargetBridge']) { $parameters['target-bridge'] = $TargetBridge }
        if($PSBoundParameters['TargetEndpoint']) { $parameters['target-endpoint'] = $TargetEndpoint }
        if($PSBoundParameters['TargetStorage']) { $parameters['target-storage'] = $TargetStorage }
        if($PSBoundParameters['TargetVmid']) { $parameters['target-vmid'] = $TargetVmid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/remote_migrate" -Parameters $parameters
    }
}

function New-PveNodesQemuMonitor
{
<#
.DESCRIPTION
Execute QEMU monitor commands.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Command
The monitor command.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Command,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Command']) { $parameters['command'] = $Command }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/monitor" -Parameters $parameters
    }
}

function Set-PveNodesQemuResize
{
<#
.DESCRIPTION
Extend volume size.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has different SHA1 digest. This can be used to prevent concurrent modifications.
.PARAMETER Disk
The disk you want to resize. Enum: ide0,ide1,ide2,ide3,scsi0,scsi1,scsi2,scsi3,scsi4,scsi5,scsi6,scsi7,scsi8,scsi9,scsi10,scsi11,scsi12,scsi13,scsi14,scsi15,scsi16,scsi17,scsi18,scsi19,scsi20,scsi21,scsi22,scsi23,scsi24,scsi25,scsi26,scsi27,scsi28,scsi29,scsi30,virtio0,virtio1,virtio2,virtio3,virtio4,virtio5,virtio6,virtio7,virtio8,virtio9,virtio10,virtio11,virtio12,virtio13,virtio14,virtio15,sata0,sata1,sata2,sata3,sata4,sata5,efidisk0,tpmstate0
.PARAMETER Node
The cluster node name.
.PARAMETER Size
The new size. With the `+` sign the value is added to the actual size of the volume and without it, the value is taken as an absolute one. Shrinking disk size is not supported.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('ide0','ide1','ide2','ide3','scsi0','scsi1','scsi2','scsi3','scsi4','scsi5','scsi6','scsi7','scsi8','scsi9','scsi10','scsi11','scsi12','scsi13','scsi14','scsi15','scsi16','scsi17','scsi18','scsi19','scsi20','scsi21','scsi22','scsi23','scsi24','scsi25','scsi26','scsi27','scsi28','scsi29','scsi30','virtio0','virtio1','virtio2','virtio3','virtio4','virtio5','virtio6','virtio7','virtio8','virtio9','virtio10','virtio11','virtio12','virtio13','virtio14','virtio15','sata0','sata1','sata2','sata3','sata4','sata5','efidisk0','tpmstate0')]
        [string]$Disk,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Size,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disk']) { $parameters['disk'] = $Disk }
        if($PSBoundParameters['Size']) { $parameters['size'] = $Size }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/resize" -Parameters $parameters
    }
}

function Get-PveNodesQemuSnapshot
{
<#
.DESCRIPTION
List all snapshots.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/snapshot"
    }
}

function New-PveNodesQemuSnapshot
{
<#
.DESCRIPTION
Snapshot a VM.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Description
A textual description or comment.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Vmstate
Save the vmstate
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Vmstate
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Snapname']) { $parameters['snapname'] = $Snapname }
        if($PSBoundParameters['Vmstate']) { $parameters['vmstate'] = $Vmstate }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/snapshot" -Parameters $parameters
    }
}

function Remove-PveNodesQemuSnapshot
{
<#
.DESCRIPTION
Delete a VM snapshot.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
For removal from config file, even if removing disk snapshots fails.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/qemu/$Vmid/snapshot/$Snapname" -Parameters $parameters
    }
}

function Get-PveNodesQemuSnapshotIdx
{
<#
.DESCRIPTION
--
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/snapshot/$Snapname"
    }
}

function Get-PveNodesQemuSnapshotConfig
{
<#
.DESCRIPTION
Get snapshot configuration
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/snapshot/$Snapname/config"
    }
}

function Set-PveNodesQemuSnapshotConfig
{
<#
.DESCRIPTION
Update snapshot metadata.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Description
A textual description or comment.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/qemu/$Vmid/snapshot/$Snapname/config" -Parameters $parameters
    }
}

function New-PveNodesQemuSnapshotRollback
{
<#
.DESCRIPTION
Rollback VM state to specified snapshot.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Start
Whether the VM should get started after rolling back successfully. (Note':' VMs will be automatically started if the snapshot includes RAM.)
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Start,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/snapshot/$Snapname/rollback" -Parameters $parameters
    }
}

function New-PveNodesQemuTemplate
{
<#
.DESCRIPTION
Create a Template.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Disk
If you want to convert only 1 disk to base image. Enum: ide0,ide1,ide2,ide3,scsi0,scsi1,scsi2,scsi3,scsi4,scsi5,scsi6,scsi7,scsi8,scsi9,scsi10,scsi11,scsi12,scsi13,scsi14,scsi15,scsi16,scsi17,scsi18,scsi19,scsi20,scsi21,scsi22,scsi23,scsi24,scsi25,scsi26,scsi27,scsi28,scsi29,scsi30,virtio0,virtio1,virtio2,virtio3,virtio4,virtio5,virtio6,virtio7,virtio8,virtio9,virtio10,virtio11,virtio12,virtio13,virtio14,virtio15,sata0,sata1,sata2,sata3,sata4,sata5,efidisk0,tpmstate0
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ide0','ide1','ide2','ide3','scsi0','scsi1','scsi2','scsi3','scsi4','scsi5','scsi6','scsi7','scsi8','scsi9','scsi10','scsi11','scsi12','scsi13','scsi14','scsi15','scsi16','scsi17','scsi18','scsi19','scsi20','scsi21','scsi22','scsi23','scsi24','scsi25','scsi26','scsi27','scsi28','scsi29','scsi30','virtio0','virtio1','virtio2','virtio3','virtio4','virtio5','virtio6','virtio7','virtio8','virtio9','virtio10','virtio11','virtio12','virtio13','virtio14','virtio15','sata0','sata1','sata2','sata3','sata4','sata5','efidisk0','tpmstate0')]
        [string]$Disk,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Disk']) { $parameters['disk'] = $Disk }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/template" -Parameters $parameters
    }
}

function New-PveNodesQemuMtunnel
{
<#
.DESCRIPTION
Migration tunnel endpoint - only for internal use by VM migration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bridges
List of network bridges to check availability. Will be checked again for actually used bridges during migration.
.PARAMETER Node
The cluster node name.
.PARAMETER Storages
List of storages to check permission and availability. Will be checked again for all actually used storages during migration.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bridges,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storages,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bridges']) { $parameters['bridges'] = $Bridges }
        if($PSBoundParameters['Storages']) { $parameters['storages'] = $Storages }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/qemu/$Vmid/mtunnel" -Parameters $parameters
    }
}

function Get-PveNodesQemuMtunnelwebsocket
{
<#
.DESCRIPTION
Migration tunnel endpoint for websocket upgrade - only for internal use by VM migration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Socket
unix socket to forward to
.PARAMETER Ticket
ticket return by initial 'mtunnel' API call, or retrieved via 'ticket' tunnel command
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Socket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ticket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Socket']) { $parameters['socket'] = $Socket }
        if($PSBoundParameters['Ticket']) { $parameters['ticket'] = $Ticket }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/qemu/$Vmid/mtunnelwebsocket" -Parameters $parameters
    }
}

function Get-PveNodesLxc
{
<#
.DESCRIPTION
LXC container index (per node).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc"
    }
}

function New-PveNodesLxc
{
<#
.DESCRIPTION
Create or restore a container.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Arch
OS architecture type. Enum: amd64,i386,arm64,armhf,riscv32,riscv64
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Cmode
Console mode. By default, the console command tries to open a connection to one of the available tty devices. By setting cmode to 'console' it tries to attach to /dev/console instead. If you set cmode to 'shell', it simply invokes a shell inside the container (no login). Enum: shell,console,tty
.PARAMETER Console
Attach a console device (/dev/console) to the container.
.PARAMETER Cores
The number of cores assigned to the container. A container can use all available cores by default.
.PARAMETER Cpulimit
Limit of CPU usage.NOTE':' If the computer has 2 CPUs, it has a total of '2' CPU time. Value '0' indicates no CPU limit.
.PARAMETER Cpuunits
CPU weight for a container, will be clamped to \[1, 10000] in cgroup v2.
.PARAMETER Debug_
Try to be more verbose. For now this only enables debug log-level on start.
.PARAMETER Description
Description for the Container. Shown in the web-interface CT's summary. This is saved as comment inside the configuration file.
.PARAMETER DevN
Device to pass through to the container
.PARAMETER Features
Allow containers access to advanced features.
.PARAMETER Force
Allow to overwrite existing container.
.PARAMETER Hookscript
Script that will be exectued during various steps in the containers lifetime.
.PARAMETER Hostname
Set a host name for the container.
.PARAMETER IgnoreUnpackErrors
Ignore errors when extracting the template.
.PARAMETER Lock
Lock/unlock the container. Enum: backup,create,destroyed,disk,fstrim,migrate,mounted,rollback,snapshot,snapshot-delete
.PARAMETER Memory
Amount of RAM for the container in MB.
.PARAMETER MpN
Use volume as container mount point. Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume.
.PARAMETER Nameserver
Sets DNS server IP address for a container. Create will automatically use the setting from the host if you neither set searchdomain nor nameserver.
.PARAMETER NetN
Specifies network interfaces for the container.
.PARAMETER Node
The cluster node name.
.PARAMETER Onboot
Specifies whether a container will be started during system bootup.
.PARAMETER Ostemplate
The OS template or backup file.
.PARAMETER Ostype
OS type. This is used to setup configuration inside the container, and corresponds to lxc setup scripts in /usr/share/lxc/config/<ostype>.common.conf. Value 'unmanaged' can be used to skip and OS specific setup. Enum: debian,devuan,ubuntu,centos,fedora,opensuse,archlinux,alpine,gentoo,nixos,unmanaged
.PARAMETER Password
Sets root password inside container.
.PARAMETER Pool
Add the VM to the specified pool.
.PARAMETER Protection
Sets the protection flag of the container. This will prevent the CT or CT's disk remove/update operation.
.PARAMETER Restore
Mark this as restore task.
.PARAMETER Rootfs
Use volume as container root.
.PARAMETER Searchdomain
Sets DNS search domains for a container. Create will automatically use the setting from the host if you neither set searchdomain nor nameserver.
.PARAMETER SshPublicKeys
Setup public SSH keys (one key per line, OpenSSH format).
.PARAMETER Start
Start the CT after its creation finished successfully.
.PARAMETER Startup
Startup and shutdown behavior. Order is a non-negative number defining the general startup order. Shutdown in done with reverse ordering. Additionally you can set the 'up' or 'down' delay in seconds, which specifies a delay to wait before the next VM is started or stopped.
.PARAMETER Storage
Default Storage.
.PARAMETER Swap
Amount of SWAP for the container in MB.
.PARAMETER Tags
Tags of the Container. This is only meta information.
.PARAMETER Template
Enable/disable Template.
.PARAMETER Timezone
Time zone to use in the container. If option isn't set, then nothing will be done. Can be set to 'host' to match the host time zone, or an arbitrary time zone option from /usr/share/zoneinfo/zone.tab
.PARAMETER Tty
Specify the number of tty available to the container
.PARAMETER Unique
Assign a unique random ethernet address.
.PARAMETER Unprivileged
Makes the container run as unprivileged user. (Should not be modified manually.)
.PARAMETER UnusedN
Reference to unused volumes. This is used internally, and should not be modified manually.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('amd64','i386','arm64','armhf','riscv32','riscv64')]
        [string]$Arch,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('shell','console','tty')]
        [string]$Cmode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Console,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cores,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Cpulimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cpuunits,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Debug_,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$DevN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Features,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hookscript,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hostname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$IgnoreUnpackErrors,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('backup','create','destroyed','disk','fstrim','migrate','mounted','rollback','snapshot','snapshot-delete')]
        [string]$Lock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Memory,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$MpN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nameserver,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$NetN,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Onboot,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ostemplate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('debian','devuan','ubuntu','centos','fedora','opensuse','archlinux','alpine','gentoo','nixos','unmanaged')]
        [string]$Ostype,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Pool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Protection,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Restore,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rootfs,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Searchdomain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SshPublicKeys,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Start,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Startup,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Swap,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tags,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Template,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Timezone,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Tty,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Unique,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Unprivileged,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$UnusedN,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Arch']) { $parameters['arch'] = $Arch }
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Cmode']) { $parameters['cmode'] = $Cmode }
        if($PSBoundParameters['Console']) { $parameters['console'] = $Console }
        if($PSBoundParameters['Cores']) { $parameters['cores'] = $Cores }
        if($PSBoundParameters['Cpulimit']) { $parameters['cpulimit'] = $Cpulimit }
        if($PSBoundParameters['Cpuunits']) { $parameters['cpuunits'] = $Cpuunits }
        if($PSBoundParameters['Debug_']) { $parameters['debug'] = $Debug_ }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Features']) { $parameters['features'] = $Features }
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Hookscript']) { $parameters['hookscript'] = $Hookscript }
        if($PSBoundParameters['Hostname']) { $parameters['hostname'] = $Hostname }
        if($PSBoundParameters['IgnoreUnpackErrors']) { $parameters['ignore-unpack-errors'] = $IgnoreUnpackErrors }
        if($PSBoundParameters['Lock']) { $parameters['lock'] = $Lock }
        if($PSBoundParameters['Memory']) { $parameters['memory'] = $Memory }
        if($PSBoundParameters['Nameserver']) { $parameters['nameserver'] = $Nameserver }
        if($PSBoundParameters['Onboot']) { $parameters['onboot'] = $Onboot }
        if($PSBoundParameters['Ostemplate']) { $parameters['ostemplate'] = $Ostemplate }
        if($PSBoundParameters['Ostype']) { $parameters['ostype'] = $Ostype }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Pool']) { $parameters['pool'] = $Pool }
        if($PSBoundParameters['Protection']) { $parameters['protection'] = $Protection }
        if($PSBoundParameters['Restore']) { $parameters['restore'] = $Restore }
        if($PSBoundParameters['Rootfs']) { $parameters['rootfs'] = $Rootfs }
        if($PSBoundParameters['Searchdomain']) { $parameters['searchdomain'] = $Searchdomain }
        if($PSBoundParameters['SshPublicKeys']) { $parameters['ssh-public-keys'] = $SshPublicKeys }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }
        if($PSBoundParameters['Startup']) { $parameters['startup'] = $Startup }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Swap']) { $parameters['swap'] = $Swap }
        if($PSBoundParameters['Tags']) { $parameters['tags'] = $Tags }
        if($PSBoundParameters['Template']) { $parameters['template'] = $Template }
        if($PSBoundParameters['Timezone']) { $parameters['timezone'] = $Timezone }
        if($PSBoundParameters['Tty']) { $parameters['tty'] = $Tty }
        if($PSBoundParameters['Unique']) { $parameters['unique'] = $Unique }
        if($PSBoundParameters['Unprivileged']) { $parameters['unprivileged'] = $Unprivileged }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }

        if($PSBoundParameters['DevN']) { $DevN.keys | ForEach-Object { $parameters['dev' + $_] = $DevN[$_] } }
        if($PSBoundParameters['MpN']) { $MpN.keys | ForEach-Object { $parameters['mp' + $_] = $MpN[$_] } }
        if($PSBoundParameters['NetN']) { $NetN.keys | ForEach-Object { $parameters['net' + $_] = $NetN[$_] } }
        if($PSBoundParameters['UnusedN']) { $UnusedN.keys | ForEach-Object { $parameters['unused' + $_] = $UnusedN[$_] } }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc" -Parameters $parameters
    }
}

function Remove-PveNodesLxc
{
<#
.DESCRIPTION
Destroy the container (also delete all uses files).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER DestroyUnreferencedDisks
If set, destroy additionally all disks with the VMID from all enabled storages which are not referenced in the config.
.PARAMETER Force
Force destroy, even if running.
.PARAMETER Node
The cluster node name.
.PARAMETER Purge
Remove container from all related configurations. For example, backup jobs, replication jobs or HA. Related ACLs and Firewall entries will *always* be removed.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$DestroyUnreferencedDisks,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Purge,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['DestroyUnreferencedDisks']) { $parameters['destroy-unreferenced-disks'] = $DestroyUnreferencedDisks }
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Purge']) { $parameters['purge'] = $Purge }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/lxc/$Vmid" -Parameters $parameters
    }
}

function Get-PveNodesLxcIdx
{
<#
.DESCRIPTION
Directory index
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid"
    }
}

function Get-PveNodesLxcConfig
{
<#
.DESCRIPTION
Get container configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Current
Get current values (instead of pending values).
.PARAMETER Node
The cluster node name.
.PARAMETER Snapshot
Fetch config values from given snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Current,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Snapshot,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Current']) { $parameters['current'] = $Current }
        if($PSBoundParameters['Snapshot']) { $parameters['snapshot'] = $Snapshot }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/config" -Parameters $parameters
    }
}

function Set-PveNodesLxcConfig
{
<#
.DESCRIPTION
Set container options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Arch
OS architecture type. Enum: amd64,i386,arm64,armhf,riscv32,riscv64
.PARAMETER Cmode
Console mode. By default, the console command tries to open a connection to one of the available tty devices. By setting cmode to 'console' it tries to attach to /dev/console instead. If you set cmode to 'shell', it simply invokes a shell inside the container (no login). Enum: shell,console,tty
.PARAMETER Console
Attach a console device (/dev/console) to the container.
.PARAMETER Cores
The number of cores assigned to the container. A container can use all available cores by default.
.PARAMETER Cpulimit
Limit of CPU usage.NOTE':' If the computer has 2 CPUs, it has a total of '2' CPU time. Value '0' indicates no CPU limit.
.PARAMETER Cpuunits
CPU weight for a container, will be clamped to \[1, 10000] in cgroup v2.
.PARAMETER Debug_
Try to be more verbose. For now this only enables debug log-level on start.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Description
Description for the Container. Shown in the web-interface CT's summary. This is saved as comment inside the configuration file.
.PARAMETER DevN
Device to pass through to the container
.PARAMETER Digest
Prevent changes if current configuration file has different SHA1 digest. This can be used to prevent concurrent modifications.
.PARAMETER Features
Allow containers access to advanced features.
.PARAMETER Hookscript
Script that will be exectued during various steps in the containers lifetime.
.PARAMETER Hostname
Set a host name for the container.
.PARAMETER Lock
Lock/unlock the container. Enum: backup,create,destroyed,disk,fstrim,migrate,mounted,rollback,snapshot,snapshot-delete
.PARAMETER Memory
Amount of RAM for the container in MB.
.PARAMETER MpN
Use volume as container mount point. Use the special syntax STORAGE_ID':'SIZE_IN_GiB to allocate a new volume.
.PARAMETER Nameserver
Sets DNS server IP address for a container. Create will automatically use the setting from the host if you neither set searchdomain nor nameserver.
.PARAMETER NetN
Specifies network interfaces for the container.
.PARAMETER Node
The cluster node name.
.PARAMETER Onboot
Specifies whether a container will be started during system bootup.
.PARAMETER Ostype
OS type. This is used to setup configuration inside the container, and corresponds to lxc setup scripts in /usr/share/lxc/config/<ostype>.common.conf. Value 'unmanaged' can be used to skip and OS specific setup. Enum: debian,devuan,ubuntu,centos,fedora,opensuse,archlinux,alpine,gentoo,nixos,unmanaged
.PARAMETER Protection
Sets the protection flag of the container. This will prevent the CT or CT's disk remove/update operation.
.PARAMETER Revert
Revert a pending change.
.PARAMETER Rootfs
Use volume as container root.
.PARAMETER Searchdomain
Sets DNS search domains for a container. Create will automatically use the setting from the host if you neither set searchdomain nor nameserver.
.PARAMETER Startup
Startup and shutdown behavior. Order is a non-negative number defining the general startup order. Shutdown in done with reverse ordering. Additionally you can set the 'up' or 'down' delay in seconds, which specifies a delay to wait before the next VM is started or stopped.
.PARAMETER Swap
Amount of SWAP for the container in MB.
.PARAMETER Tags
Tags of the Container. This is only meta information.
.PARAMETER Template
Enable/disable Template.
.PARAMETER Timezone
Time zone to use in the container. If option isn't set, then nothing will be done. Can be set to 'host' to match the host time zone, or an arbitrary time zone option from /usr/share/zoneinfo/zone.tab
.PARAMETER Tty
Specify the number of tty available to the container
.PARAMETER Unprivileged
Makes the container run as unprivileged user. (Should not be modified manually.)
.PARAMETER UnusedN
Reference to unused volumes. This is used internally, and should not be modified manually.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('amd64','i386','arm64','armhf','riscv32','riscv64')]
        [string]$Arch,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('shell','console','tty')]
        [string]$Cmode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Console,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cores,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Cpulimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Cpuunits,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Debug_,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$DevN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Features,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hookscript,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hostname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('backup','create','destroyed','disk','fstrim','migrate','mounted','rollback','snapshot','snapshot-delete')]
        [string]$Lock,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Memory,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$MpN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nameserver,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$NetN,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Onboot,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('debian','devuan','ubuntu','centos','fedora','opensuse','archlinux','alpine','gentoo','nixos','unmanaged')]
        [string]$Ostype,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Protection,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Revert,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rootfs,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Searchdomain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Startup,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Swap,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tags,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Template,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Timezone,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Tty,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Unprivileged,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$UnusedN,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Arch']) { $parameters['arch'] = $Arch }
        if($PSBoundParameters['Cmode']) { $parameters['cmode'] = $Cmode }
        if($PSBoundParameters['Console']) { $parameters['console'] = $Console }
        if($PSBoundParameters['Cores']) { $parameters['cores'] = $Cores }
        if($PSBoundParameters['Cpulimit']) { $parameters['cpulimit'] = $Cpulimit }
        if($PSBoundParameters['Cpuunits']) { $parameters['cpuunits'] = $Cpuunits }
        if($PSBoundParameters['Debug_']) { $parameters['debug'] = $Debug_ }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Features']) { $parameters['features'] = $Features }
        if($PSBoundParameters['Hookscript']) { $parameters['hookscript'] = $Hookscript }
        if($PSBoundParameters['Hostname']) { $parameters['hostname'] = $Hostname }
        if($PSBoundParameters['Lock']) { $parameters['lock'] = $Lock }
        if($PSBoundParameters['Memory']) { $parameters['memory'] = $Memory }
        if($PSBoundParameters['Nameserver']) { $parameters['nameserver'] = $Nameserver }
        if($PSBoundParameters['Onboot']) { $parameters['onboot'] = $Onboot }
        if($PSBoundParameters['Ostype']) { $parameters['ostype'] = $Ostype }
        if($PSBoundParameters['Protection']) { $parameters['protection'] = $Protection }
        if($PSBoundParameters['Revert']) { $parameters['revert'] = $Revert }
        if($PSBoundParameters['Rootfs']) { $parameters['rootfs'] = $Rootfs }
        if($PSBoundParameters['Searchdomain']) { $parameters['searchdomain'] = $Searchdomain }
        if($PSBoundParameters['Startup']) { $parameters['startup'] = $Startup }
        if($PSBoundParameters['Swap']) { $parameters['swap'] = $Swap }
        if($PSBoundParameters['Tags']) { $parameters['tags'] = $Tags }
        if($PSBoundParameters['Template']) { $parameters['template'] = $Template }
        if($PSBoundParameters['Timezone']) { $parameters['timezone'] = $Timezone }
        if($PSBoundParameters['Tty']) { $parameters['tty'] = $Tty }
        if($PSBoundParameters['Unprivileged']) { $parameters['unprivileged'] = $Unprivileged }

        if($PSBoundParameters['DevN']) { $DevN.keys | ForEach-Object { $parameters['dev' + $_] = $DevN[$_] } }
        if($PSBoundParameters['MpN']) { $MpN.keys | ForEach-Object { $parameters['mp' + $_] = $MpN[$_] } }
        if($PSBoundParameters['NetN']) { $NetN.keys | ForEach-Object { $parameters['net' + $_] = $NetN[$_] } }
        if($PSBoundParameters['UnusedN']) { $UnusedN.keys | ForEach-Object { $parameters['unused' + $_] = $UnusedN[$_] } }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/lxc/$Vmid/config" -Parameters $parameters
    }
}

function Get-PveNodesLxcStatus
{
<#
.DESCRIPTION
Directory index
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/status"
    }
}

function Get-PveNodesLxcStatusCurrent
{
<#
.DESCRIPTION
Get virtual machine status.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/status/current"
    }
}

function New-PveNodesLxcStatusStart
{
<#
.DESCRIPTION
Start the container.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Debug_
If set, enables very verbose debug log-level on start.
.PARAMETER Node
The cluster node name.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Debug_,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Debug_']) { $parameters['debug'] = $Debug_ }
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/status/start" -Parameters $parameters
    }
}

function New-PveNodesLxcStatusStop
{
<#
.DESCRIPTION
Stop the container. This will abruptly stop all processes running in the container.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Skiplock
Ignore locks - only root is allowed to use this option.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skiplock,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Skiplock']) { $parameters['skiplock'] = $Skiplock }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/status/stop" -Parameters $parameters
    }
}

function New-PveNodesLxcStatusShutdown
{
<#
.DESCRIPTION
Shutdown the container. This will trigger a clean shutdown of the container, see lxc-stop(1) for details.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Forcestop
Make sure the Container stops.
.PARAMETER Node
The cluster node name.
.PARAMETER Timeout
Wait maximal timeout seconds.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Forcestop,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Forcestop']) { $parameters['forceStop'] = $Forcestop }
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/status/shutdown" -Parameters $parameters
    }
}

function New-PveNodesLxcStatusSuspend
{
<#
.DESCRIPTION
Suspend the container. This is experimental.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/status/suspend"
    }
}

function New-PveNodesLxcStatusResume
{
<#
.DESCRIPTION
Resume the container.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/status/resume"
    }
}

function New-PveNodesLxcStatusReboot
{
<#
.DESCRIPTION
Reboot the container by shutting it down, and starting it again. Applies pending changes.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Timeout
Wait maximal timeout seconds for the shutdown.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/status/reboot" -Parameters $parameters
    }
}

function Get-PveNodesLxcSnapshot
{
<#
.DESCRIPTION
List all snapshots.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/snapshot"
    }
}

function New-PveNodesLxcSnapshot
{
<#
.DESCRIPTION
Snapshot a container.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Description
A textual description or comment.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Snapname']) { $parameters['snapname'] = $Snapname }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/snapshot" -Parameters $parameters
    }
}

function Remove-PveNodesLxcSnapshot
{
<#
.DESCRIPTION
Delete a LXC snapshot.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
For removal from config file, even if removing disk snapshots fails.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/lxc/$Vmid/snapshot/$Snapname" -Parameters $parameters
    }
}

function Get-PveNodesLxcSnapshotIdx
{
<#
.DESCRIPTION
--
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/snapshot/$Snapname"
    }
}

function New-PveNodesLxcSnapshotRollback
{
<#
.DESCRIPTION
Rollback LXC state to specified snapshot.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Start
Whether the container should get started after rolling back successfully
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Start,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/snapshot/$Snapname/rollback" -Parameters $parameters
    }
}

function Get-PveNodesLxcSnapshotConfig
{
<#
.DESCRIPTION
Get snapshot configuration
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/snapshot/$Snapname/config"
    }
}

function Set-PveNodesLxcSnapshotConfig
{
<#
.DESCRIPTION
Update snapshot metadata.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Description
A textual description or comment.
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/lxc/$Vmid/snapshot/$Snapname/config" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewall
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall"
    }
}

function Get-PveNodesLxcFirewallRules
{
<#
.DESCRIPTION
List rules.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/rules"
    }
}

function New-PveNodesLxcFirewallRules
{
<#
.DESCRIPTION
Create new rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('in','out','group')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Pos']) { $parameters['pos'] = $Pos }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/firewall/rules" -Parameters $parameters
    }
}

function Remove-PveNodesLxcFirewallRules
{
<#
.DESCRIPTION
Delete rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/lxc/$Vmid/firewall/rules/$Pos" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewallRulesIdx
{
<#
.DESCRIPTION
Get single rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/rules/$Pos"
    }
}

function Set-PveNodesLxcFirewallRules
{
<#
.DESCRIPTION
Modify rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Moveto
Move rule to new position <moveto>. Other arguments are ignored.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Moveto,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('in','out','group')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Moveto']) { $parameters['moveto'] = $Moveto }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/lxc/$Vmid/firewall/rules/$Pos" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewallAliases
{
<#
.DESCRIPTION
List aliases
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/aliases"
    }
}

function New-PveNodesLxcFirewallAliases
{
<#
.DESCRIPTION
Create IP or Network Alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Name
Alias name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/firewall/aliases" -Parameters $parameters
    }
}

function Remove-PveNodesLxcFirewallAliases
{
<#
.DESCRIPTION
Remove IP or Network alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
Alias name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/lxc/$Vmid/firewall/aliases/$Name" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewallAliasesIdx
{
<#
.DESCRIPTION
Read alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
Alias name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/aliases/$Name"
    }
}

function Set-PveNodesLxcFirewallAliases
{
<#
.DESCRIPTION
Update IP or Network alias.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
Alias name.
.PARAMETER Node
The cluster node name.
.PARAMETER Rename
Rename an existing alias.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rename,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Rename']) { $parameters['rename'] = $Rename }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/lxc/$Vmid/firewall/aliases/$Name" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewallIpset
{
<#
.DESCRIPTION
List IPSets
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/ipset"
    }
}

function New-PveNodesLxcFirewallIpset
{
<#
.DESCRIPTION
Create new IPSet
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Rename
Rename an existing IPSet. You can set 'rename' to the same value as 'name' to update the 'comment' of an existing IPSet.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Rename,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Rename']) { $parameters['rename'] = $Rename }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/firewall/ipset" -Parameters $parameters
    }
}

function Remove-PveNodesLxcFirewallIpset
{
<#
.DESCRIPTION
Delete IPSet
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
Delete all members of the IPSet, if there are any.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/lxc/$Vmid/firewall/ipset/$Name" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewallIpsetIdx
{
<#
.DESCRIPTION
List IPSet content
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/ipset/$Name"
    }
}

function New-PveNodesLxcFirewallIpsetIdx
{
<#
.DESCRIPTION
Add IP or Network to IPSet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Nomatch
--
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nomatch,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Nomatch']) { $parameters['nomatch'] = $Nomatch }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/firewall/ipset/$Name" -Parameters $parameters
    }
}

function Remove-PveNodesLxcFirewallIpsetIdx
{
<#
.DESCRIPTION
Remove IP or Network from IPSet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/lxc/$Vmid/firewall/ipset/$Name/$Cidr" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewallIpsetIdx
{
<#
.DESCRIPTION
Read IP or Network settings from IPSet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/ipset/$Name/$Cidr"
    }
}

function Set-PveNodesLxcFirewallIpset
{
<#
.DESCRIPTION
Update IP or Network settings
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cidr
Network/IP specification in CIDR format.
.PARAMETER Comment
--
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Name
IP set name.
.PARAMETER Node
The cluster node name.
.PARAMETER Nomatch
--
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nomatch,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Nomatch']) { $parameters['nomatch'] = $Nomatch }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/lxc/$Vmid/firewall/ipset/$Name/$Cidr" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewallOptions
{
<#
.DESCRIPTION
Get VM firewall options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/options"
    }
}

function Set-PveNodesLxcFirewallOptions
{
<#
.DESCRIPTION
Set Firewall options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Dhcp
Enable DHCP.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Enable
Enable/disable firewall rules.
.PARAMETER Ipfilter
Enable default IP filters. This is equivalent to adding an empty ipfilter-net<id> ipset for every interface. Such ipsets implicitly contain sane default restrictions such as restricting IPv6 link local addresses to the one derived from the interface's MAC address. For containers the configured IP addresses will be implicitly added.
.PARAMETER LogLevelIn
Log level for incoming traffic. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER LogLevelOut
Log level for outgoing traffic. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macfilter
Enable/disable MAC address filter.
.PARAMETER Ndp
Enable NDP (Neighbor Discovery Protocol).
.PARAMETER Node
The cluster node name.
.PARAMETER PolicyIn
Input policy. Enum: ACCEPT,REJECT,DROP
.PARAMETER PolicyOut
Output policy. Enum: ACCEPT,REJECT,DROP
.PARAMETER Radv
Allow sending Router Advertisement.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Dhcp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ipfilter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$LogLevelIn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$LogLevelOut,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Macfilter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ndp,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ACCEPT','REJECT','DROP')]
        [string]$PolicyIn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ACCEPT','REJECT','DROP')]
        [string]$PolicyOut,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Radv,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Dhcp']) { $parameters['dhcp'] = $Dhcp }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['Ipfilter']) { $parameters['ipfilter'] = $Ipfilter }
        if($PSBoundParameters['LogLevelIn']) { $parameters['log_level_in'] = $LogLevelIn }
        if($PSBoundParameters['LogLevelOut']) { $parameters['log_level_out'] = $LogLevelOut }
        if($PSBoundParameters['Macfilter']) { $parameters['macfilter'] = $Macfilter }
        if($PSBoundParameters['Ndp']) { $parameters['ndp'] = $Ndp }
        if($PSBoundParameters['PolicyIn']) { $parameters['policy_in'] = $PolicyIn }
        if($PSBoundParameters['PolicyOut']) { $parameters['policy_out'] = $PolicyOut }
        if($PSBoundParameters['Radv']) { $parameters['radv'] = $Radv }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/lxc/$Vmid/firewall/options" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewallLog
{
<#
.DESCRIPTION
Read firewall log
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Limit
--
.PARAMETER Node
The cluster node name.
.PARAMETER Since
Display log since this UNIX epoch.
.PARAMETER Start
--
.PARAMETER Until
Display log until this UNIX epoch.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Limit,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Since,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Start,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Until,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Limit']) { $parameters['limit'] = $Limit }
        if($PSBoundParameters['Since']) { $parameters['since'] = $Since }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }
        if($PSBoundParameters['Until']) { $parameters['until'] = $Until }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/log" -Parameters $parameters
    }
}

function Get-PveNodesLxcFirewallRefs
{
<#
.DESCRIPTION
Lists possible IPSet/Alias reference which are allowed in source/dest properties.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Type
Only list references of specified type. Enum: alias,ipset
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('alias','ipset')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/firewall/refs" -Parameters $parameters
    }
}

function Get-PveNodesLxcRrd
{
<#
.DESCRIPTION
Read VM RRD statistics (returns PNG)
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cf
The RRD consolidation function Enum: AVERAGE,MAX
.PARAMETER Ds
The list of datasources you want to display.
.PARAMETER Node
The cluster node name.
.PARAMETER Timeframe
Specify the time frame you are interested in. Enum: hour,day,week,month,year
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('AVERAGE','MAX')]
        [string]$Cf,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ds,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('hour','day','week','month','year')]
        [string]$Timeframe,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cf']) { $parameters['cf'] = $Cf }
        if($PSBoundParameters['Ds']) { $parameters['ds'] = $Ds }
        if($PSBoundParameters['Timeframe']) { $parameters['timeframe'] = $Timeframe }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/rrd" -Parameters $parameters
    }
}

function Get-PveNodesLxcRrddata
{
<#
.DESCRIPTION
Read VM RRD statistics
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cf
The RRD consolidation function Enum: AVERAGE,MAX
.PARAMETER Node
The cluster node name.
.PARAMETER Timeframe
Specify the time frame you are interested in. Enum: hour,day,week,month,year
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('AVERAGE','MAX')]
        [string]$Cf,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('hour','day','week','month','year')]
        [string]$Timeframe,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cf']) { $parameters['cf'] = $Cf }
        if($PSBoundParameters['Timeframe']) { $parameters['timeframe'] = $Timeframe }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/rrddata" -Parameters $parameters
    }
}

function New-PveNodesLxcVncproxy
{
<#
.DESCRIPTION
Creates a TCP VNC proxy connections.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Height
sets the height of the console in pixels.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Websocket
use websocket instead of standard VNC.
.PARAMETER Width
sets the width of the console in pixels.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Height,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Websocket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Width
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Height']) { $parameters['height'] = $Height }
        if($PSBoundParameters['Websocket']) { $parameters['websocket'] = $Websocket }
        if($PSBoundParameters['Width']) { $parameters['width'] = $Width }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/vncproxy" -Parameters $parameters
    }
}

function New-PveNodesLxcTermproxy
{
<#
.DESCRIPTION
Creates a TCP proxy connection.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/termproxy"
    }
}

function Get-PveNodesLxcVncwebsocket
{
<#
.DESCRIPTION
Opens a weksocket for VNC traffic.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Port
Port number returned by previous vncproxy call.
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Vncticket
Ticket from previous call to vncproxy.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vncticket
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Vncticket']) { $parameters['vncticket'] = $Vncticket }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/vncwebsocket" -Parameters $parameters
    }
}

function New-PveNodesLxcSpiceproxy
{
<#
.DESCRIPTION
Returns a SPICE configuration to connect to the CT.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Proxy
SPICE proxy server. This can be used by the client to specify the proxy server. All nodes in a cluster runs 'spiceproxy', so it is up to the client to choose one. By default, we return the node where the VM is currently running. As reasonable setting is to use same node you use to connect to the API (This is window.location.hostname for the JS GUI).
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proxy,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Proxy']) { $parameters['proxy'] = $Proxy }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/spiceproxy" -Parameters $parameters
    }
}

function New-PveNodesLxcRemoteMigrate
{
<#
.DESCRIPTION
Migrate the container to another cluster. Creates a new migration task. EXPERIMENTAL feature!
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Delete
Delete the original CT and related data after successful migration. By default the original CT is kept on the source cluster in a stopped state.
.PARAMETER Node
The cluster node name.
.PARAMETER Online
Use online/live migration.
.PARAMETER Restart
Use restart migration
.PARAMETER TargetBridge
Mapping from source to target bridges. Providing only a single bridge ID maps all source bridges to that bridge. Providing the special value '1' will map each source bridge to itself.
.PARAMETER TargetEndpoint
Remote target endpoint
.PARAMETER TargetStorage
Mapping from source to target storages. Providing only a single storage ID maps all source storages to that storage. Providing the special value '1' will map each source storage to itself.
.PARAMETER TargetVmid
The (unique) ID of the VM.
.PARAMETER Timeout
Timeout in seconds for shutdown for restart migration
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Delete,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Online,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Restart,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$TargetBridge,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$TargetEndpoint,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$TargetStorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$TargetVmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Online']) { $parameters['online'] = $Online }
        if($PSBoundParameters['Restart']) { $parameters['restart'] = $Restart }
        if($PSBoundParameters['TargetBridge']) { $parameters['target-bridge'] = $TargetBridge }
        if($PSBoundParameters['TargetEndpoint']) { $parameters['target-endpoint'] = $TargetEndpoint }
        if($PSBoundParameters['TargetStorage']) { $parameters['target-storage'] = $TargetStorage }
        if($PSBoundParameters['TargetVmid']) { $parameters['target-vmid'] = $TargetVmid }
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/remote_migrate" -Parameters $parameters
    }
}

function New-PveNodesLxcMigrate
{
<#
.DESCRIPTION
Migrate the container to another node. Creates a new migration task.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Node
The cluster node name.
.PARAMETER Online
Use online/live migration.
.PARAMETER Restart
Use restart migration
.PARAMETER Target
Target node.
.PARAMETER TargetStorage
Mapping from source to target storages. Providing only a single storage ID maps all source storages to that storage. Providing the special value '1' will map each source storage to itself.
.PARAMETER Timeout
Timeout in seconds for shutdown for restart migration
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Bwlimit,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Online,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Restart,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Target,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$TargetStorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Online']) { $parameters['online'] = $Online }
        if($PSBoundParameters['Restart']) { $parameters['restart'] = $Restart }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }
        if($PSBoundParameters['TargetStorage']) { $parameters['target-storage'] = $TargetStorage }
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/migrate" -Parameters $parameters
    }
}

function Get-PveNodesLxcFeature
{
<#
.DESCRIPTION
Check if feature for virtual machine is available.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Feature
Feature to check. Enum: snapshot,clone,copy
.PARAMETER Node
The cluster node name.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('snapshot','clone','copy')]
        [string]$Feature,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Feature']) { $parameters['feature'] = $Feature }
        if($PSBoundParameters['Snapname']) { $parameters['snapname'] = $Snapname }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/feature" -Parameters $parameters
    }
}

function New-PveNodesLxcTemplate
{
<#
.DESCRIPTION
Create a Template.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/template"
    }
}

function New-PveNodesLxcClone
{
<#
.DESCRIPTION
Create a container clone/copy
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Description
Description for the new CT.
.PARAMETER Full
Create a full copy of all disks. This is always done when you clone a normal CT. For CT templates, we try to create a linked clone by default.
.PARAMETER Hostname
Set a hostname for the new CT.
.PARAMETER Newid
VMID for the clone.
.PARAMETER Node
The cluster node name.
.PARAMETER Pool
Add the new CT to the specified pool.
.PARAMETER Snapname
The name of the snapshot.
.PARAMETER Storage
Target storage for full clone.
.PARAMETER Target
Target node. Only allowed if the original VM is on shared storage.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Full,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Hostname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Newid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Pool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Snapname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Target,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Full']) { $parameters['full'] = $Full }
        if($PSBoundParameters['Hostname']) { $parameters['hostname'] = $Hostname }
        if($PSBoundParameters['Newid']) { $parameters['newid'] = $Newid }
        if($PSBoundParameters['Pool']) { $parameters['pool'] = $Pool }
        if($PSBoundParameters['Snapname']) { $parameters['snapname'] = $Snapname }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/clone" -Parameters $parameters
    }
}

function Set-PveNodesLxcResize
{
<#
.DESCRIPTION
Resize a container mount point.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has different SHA1 digest. This can be used to prevent concurrent modifications.
.PARAMETER Disk
The disk you want to resize. Enum: rootfs,mp0,mp1,mp2,mp3,mp4,mp5,mp6,mp7,mp8,mp9,mp10,mp11,mp12,mp13,mp14,mp15,mp16,mp17,mp18,mp19,mp20,mp21,mp22,mp23,mp24,mp25,mp26,mp27,mp28,mp29,mp30,mp31,mp32,mp33,mp34,mp35,mp36,mp37,mp38,mp39,mp40,mp41,mp42,mp43,mp44,mp45,mp46,mp47,mp48,mp49,mp50,mp51,mp52,mp53,mp54,mp55,mp56,mp57,mp58,mp59,mp60,mp61,mp62,mp63,mp64,mp65,mp66,mp67,mp68,mp69,mp70,mp71,mp72,mp73,mp74,mp75,mp76,mp77,mp78,mp79,mp80,mp81,mp82,mp83,mp84,mp85,mp86,mp87,mp88,mp89,mp90,mp91,mp92,mp93,mp94,mp95,mp96,mp97,mp98,mp99,mp100,mp101,mp102,mp103,mp104,mp105,mp106,mp107,mp108,mp109,mp110,mp111,mp112,mp113,mp114,mp115,mp116,mp117,mp118,mp119,mp120,mp121,mp122,mp123,mp124,mp125,mp126,mp127,mp128,mp129,mp130,mp131,mp132,mp133,mp134,mp135,mp136,mp137,mp138,mp139,mp140,mp141,mp142,mp143,mp144,mp145,mp146,mp147,mp148,mp149,mp150,mp151,mp152,mp153,mp154,mp155,mp156,mp157,mp158,mp159,mp160,mp161,mp162,mp163,mp164,mp165,mp166,mp167,mp168,mp169,mp170,mp171,mp172,mp173,mp174,mp175,mp176,mp177,mp178,mp179,mp180,mp181,mp182,mp183,mp184,mp185,mp186,mp187,mp188,mp189,mp190,mp191,mp192,mp193,mp194,mp195,mp196,mp197,mp198,mp199,mp200,mp201,mp202,mp203,mp204,mp205,mp206,mp207,mp208,mp209,mp210,mp211,mp212,mp213,mp214,mp215,mp216,mp217,mp218,mp219,mp220,mp221,mp222,mp223,mp224,mp225,mp226,mp227,mp228,mp229,mp230,mp231,mp232,mp233,mp234,mp235,mp236,mp237,mp238,mp239,mp240,mp241,mp242,mp243,mp244,mp245,mp246,mp247,mp248,mp249,mp250,mp251,mp252,mp253,mp254,mp255
.PARAMETER Node
The cluster node name.
.PARAMETER Size
The new size. With the '+' sign the value is added to the actual size of the volume and without it, the value is taken as an absolute one. Shrinking disk size is not supported.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('rootfs','mp0','mp1','mp2','mp3','mp4','mp5','mp6','mp7','mp8','mp9','mp10','mp11','mp12','mp13','mp14','mp15','mp16','mp17','mp18','mp19','mp20','mp21','mp22','mp23','mp24','mp25','mp26','mp27','mp28','mp29','mp30','mp31','mp32','mp33','mp34','mp35','mp36','mp37','mp38','mp39','mp40','mp41','mp42','mp43','mp44','mp45','mp46','mp47','mp48','mp49','mp50','mp51','mp52','mp53','mp54','mp55','mp56','mp57','mp58','mp59','mp60','mp61','mp62','mp63','mp64','mp65','mp66','mp67','mp68','mp69','mp70','mp71','mp72','mp73','mp74','mp75','mp76','mp77','mp78','mp79','mp80','mp81','mp82','mp83','mp84','mp85','mp86','mp87','mp88','mp89','mp90','mp91','mp92','mp93','mp94','mp95','mp96','mp97','mp98','mp99','mp100','mp101','mp102','mp103','mp104','mp105','mp106','mp107','mp108','mp109','mp110','mp111','mp112','mp113','mp114','mp115','mp116','mp117','mp118','mp119','mp120','mp121','mp122','mp123','mp124','mp125','mp126','mp127','mp128','mp129','mp130','mp131','mp132','mp133','mp134','mp135','mp136','mp137','mp138','mp139','mp140','mp141','mp142','mp143','mp144','mp145','mp146','mp147','mp148','mp149','mp150','mp151','mp152','mp153','mp154','mp155','mp156','mp157','mp158','mp159','mp160','mp161','mp162','mp163','mp164','mp165','mp166','mp167','mp168','mp169','mp170','mp171','mp172','mp173','mp174','mp175','mp176','mp177','mp178','mp179','mp180','mp181','mp182','mp183','mp184','mp185','mp186','mp187','mp188','mp189','mp190','mp191','mp192','mp193','mp194','mp195','mp196','mp197','mp198','mp199','mp200','mp201','mp202','mp203','mp204','mp205','mp206','mp207','mp208','mp209','mp210','mp211','mp212','mp213','mp214','mp215','mp216','mp217','mp218','mp219','mp220','mp221','mp222','mp223','mp224','mp225','mp226','mp227','mp228','mp229','mp230','mp231','mp232','mp233','mp234','mp235','mp236','mp237','mp238','mp239','mp240','mp241','mp242','mp243','mp244','mp245','mp246','mp247','mp248','mp249','mp250','mp251','mp252','mp253','mp254','mp255')]
        [string]$Disk,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Size,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disk']) { $parameters['disk'] = $Disk }
        if($PSBoundParameters['Size']) { $parameters['size'] = $Size }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/lxc/$Vmid/resize" -Parameters $parameters
    }
}

function New-PveNodesLxcMoveVolume
{
<#
.DESCRIPTION
Move a rootfs-/mp-volume to a different storage or to a different container.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bwlimit
Override I/O bandwidth limit (in KiB/s).
.PARAMETER Delete
Delete the original volume after successful copy. By default the original is kept as an unused volume entry.
.PARAMETER Digest
Prevent changes if current configuration file has different SHA1 " .		    "digest. This can be used to prevent concurrent modifications.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
Target Storage.
.PARAMETER TargetDigest
Prevent changes if current configuration file of the target " .		    "container has a different SHA1 digest. This can be used to prevent " .		    "concurrent modifications.
.PARAMETER TargetVmid
The (unique) ID of the VM.
.PARAMETER TargetVolume
The config key the volume will be moved to. Default is the source volume key. Enum: rootfs,mp0,mp1,mp2,mp3,mp4,mp5,mp6,mp7,mp8,mp9,mp10,mp11,mp12,mp13,mp14,mp15,mp16,mp17,mp18,mp19,mp20,mp21,mp22,mp23,mp24,mp25,mp26,mp27,mp28,mp29,mp30,mp31,mp32,mp33,mp34,mp35,mp36,mp37,mp38,mp39,mp40,mp41,mp42,mp43,mp44,mp45,mp46,mp47,mp48,mp49,mp50,mp51,mp52,mp53,mp54,mp55,mp56,mp57,mp58,mp59,mp60,mp61,mp62,mp63,mp64,mp65,mp66,mp67,mp68,mp69,mp70,mp71,mp72,mp73,mp74,mp75,mp76,mp77,mp78,mp79,mp80,mp81,mp82,mp83,mp84,mp85,mp86,mp87,mp88,mp89,mp90,mp91,mp92,mp93,mp94,mp95,mp96,mp97,mp98,mp99,mp100,mp101,mp102,mp103,mp104,mp105,mp106,mp107,mp108,mp109,mp110,mp111,mp112,mp113,mp114,mp115,mp116,mp117,mp118,mp119,mp120,mp121,mp122,mp123,mp124,mp125,mp126,mp127,mp128,mp129,mp130,mp131,mp132,mp133,mp134,mp135,mp136,mp137,mp138,mp139,mp140,mp141,mp142,mp143,mp144,mp145,mp146,mp147,mp148,mp149,mp150,mp151,mp152,mp153,mp154,mp155,mp156,mp157,mp158,mp159,mp160,mp161,mp162,mp163,mp164,mp165,mp166,mp167,mp168,mp169,mp170,mp171,mp172,mp173,mp174,mp175,mp176,mp177,mp178,mp179,mp180,mp181,mp182,mp183,mp184,mp185,mp186,mp187,mp188,mp189,mp190,mp191,mp192,mp193,mp194,mp195,mp196,mp197,mp198,mp199,mp200,mp201,mp202,mp203,mp204,mp205,mp206,mp207,mp208,mp209,mp210,mp211,mp212,mp213,mp214,mp215,mp216,mp217,mp218,mp219,mp220,mp221,mp222,mp223,mp224,mp225,mp226,mp227,mp228,mp229,mp230,mp231,mp232,mp233,mp234,mp235,mp236,mp237,mp238,mp239,mp240,mp241,mp242,mp243,mp244,mp245,mp246,mp247,mp248,mp249,mp250,mp251,mp252,mp253,mp254,mp255,unused0,unused1,unused2,unused3,unused4,unused5,unused6,unused7,unused8,unused9,unused10,unused11,unused12,unused13,unused14,unused15,unused16,unused17,unused18,unused19,unused20,unused21,unused22,unused23,unused24,unused25,unused26,unused27,unused28,unused29,unused30,unused31,unused32,unused33,unused34,unused35,unused36,unused37,unused38,unused39,unused40,unused41,unused42,unused43,unused44,unused45,unused46,unused47,unused48,unused49,unused50,unused51,unused52,unused53,unused54,unused55,unused56,unused57,unused58,unused59,unused60,unused61,unused62,unused63,unused64,unused65,unused66,unused67,unused68,unused69,unused70,unused71,unused72,unused73,unused74,unused75,unused76,unused77,unused78,unused79,unused80,unused81,unused82,unused83,unused84,unused85,unused86,unused87,unused88,unused89,unused90,unused91,unused92,unused93,unused94,unused95,unused96,unused97,unused98,unused99,unused100,unused101,unused102,unused103,unused104,unused105,unused106,unused107,unused108,unused109,unused110,unused111,unused112,unused113,unused114,unused115,unused116,unused117,unused118,unused119,unused120,unused121,unused122,unused123,unused124,unused125,unused126,unused127,unused128,unused129,unused130,unused131,unused132,unused133,unused134,unused135,unused136,unused137,unused138,unused139,unused140,unused141,unused142,unused143,unused144,unused145,unused146,unused147,unused148,unused149,unused150,unused151,unused152,unused153,unused154,unused155,unused156,unused157,unused158,unused159,unused160,unused161,unused162,unused163,unused164,unused165,unused166,unused167,unused168,unused169,unused170,unused171,unused172,unused173,unused174,unused175,unused176,unused177,unused178,unused179,unused180,unused181,unused182,unused183,unused184,unused185,unused186,unused187,unused188,unused189,unused190,unused191,unused192,unused193,unused194,unused195,unused196,unused197,unused198,unused199,unused200,unused201,unused202,unused203,unused204,unused205,unused206,unused207,unused208,unused209,unused210,unused211,unused212,unused213,unused214,unused215,unused216,unused217,unused218,unused219,unused220,unused221,unused222,unused223,unused224,unused225,unused226,unused227,unused228,unused229,unused230,unused231,unused232,unused233,unused234,unused235,unused236,unused237,unused238,unused239,unused240,unused241,unused242,unused243,unused244,unused245,unused246,unused247,unused248,unused249,unused250,unused251,unused252,unused253,unused254,unused255
.PARAMETER Vmid
The (unique) ID of the VM.
.PARAMETER Volume
Volume which will be moved. Enum: rootfs,mp0,mp1,mp2,mp3,mp4,mp5,mp6,mp7,mp8,mp9,mp10,mp11,mp12,mp13,mp14,mp15,mp16,mp17,mp18,mp19,mp20,mp21,mp22,mp23,mp24,mp25,mp26,mp27,mp28,mp29,mp30,mp31,mp32,mp33,mp34,mp35,mp36,mp37,mp38,mp39,mp40,mp41,mp42,mp43,mp44,mp45,mp46,mp47,mp48,mp49,mp50,mp51,mp52,mp53,mp54,mp55,mp56,mp57,mp58,mp59,mp60,mp61,mp62,mp63,mp64,mp65,mp66,mp67,mp68,mp69,mp70,mp71,mp72,mp73,mp74,mp75,mp76,mp77,mp78,mp79,mp80,mp81,mp82,mp83,mp84,mp85,mp86,mp87,mp88,mp89,mp90,mp91,mp92,mp93,mp94,mp95,mp96,mp97,mp98,mp99,mp100,mp101,mp102,mp103,mp104,mp105,mp106,mp107,mp108,mp109,mp110,mp111,mp112,mp113,mp114,mp115,mp116,mp117,mp118,mp119,mp120,mp121,mp122,mp123,mp124,mp125,mp126,mp127,mp128,mp129,mp130,mp131,mp132,mp133,mp134,mp135,mp136,mp137,mp138,mp139,mp140,mp141,mp142,mp143,mp144,mp145,mp146,mp147,mp148,mp149,mp150,mp151,mp152,mp153,mp154,mp155,mp156,mp157,mp158,mp159,mp160,mp161,mp162,mp163,mp164,mp165,mp166,mp167,mp168,mp169,mp170,mp171,mp172,mp173,mp174,mp175,mp176,mp177,mp178,mp179,mp180,mp181,mp182,mp183,mp184,mp185,mp186,mp187,mp188,mp189,mp190,mp191,mp192,mp193,mp194,mp195,mp196,mp197,mp198,mp199,mp200,mp201,mp202,mp203,mp204,mp205,mp206,mp207,mp208,mp209,mp210,mp211,mp212,mp213,mp214,mp215,mp216,mp217,mp218,mp219,mp220,mp221,mp222,mp223,mp224,mp225,mp226,mp227,mp228,mp229,mp230,mp231,mp232,mp233,mp234,mp235,mp236,mp237,mp238,mp239,mp240,mp241,mp242,mp243,mp244,mp245,mp246,mp247,mp248,mp249,mp250,mp251,mp252,mp253,mp254,mp255,unused0,unused1,unused2,unused3,unused4,unused5,unused6,unused7,unused8,unused9,unused10,unused11,unused12,unused13,unused14,unused15,unused16,unused17,unused18,unused19,unused20,unused21,unused22,unused23,unused24,unused25,unused26,unused27,unused28,unused29,unused30,unused31,unused32,unused33,unused34,unused35,unused36,unused37,unused38,unused39,unused40,unused41,unused42,unused43,unused44,unused45,unused46,unused47,unused48,unused49,unused50,unused51,unused52,unused53,unused54,unused55,unused56,unused57,unused58,unused59,unused60,unused61,unused62,unused63,unused64,unused65,unused66,unused67,unused68,unused69,unused70,unused71,unused72,unused73,unused74,unused75,unused76,unused77,unused78,unused79,unused80,unused81,unused82,unused83,unused84,unused85,unused86,unused87,unused88,unused89,unused90,unused91,unused92,unused93,unused94,unused95,unused96,unused97,unused98,unused99,unused100,unused101,unused102,unused103,unused104,unused105,unused106,unused107,unused108,unused109,unused110,unused111,unused112,unused113,unused114,unused115,unused116,unused117,unused118,unused119,unused120,unused121,unused122,unused123,unused124,unused125,unused126,unused127,unused128,unused129,unused130,unused131,unused132,unused133,unused134,unused135,unused136,unused137,unused138,unused139,unused140,unused141,unused142,unused143,unused144,unused145,unused146,unused147,unused148,unused149,unused150,unused151,unused152,unused153,unused154,unused155,unused156,unused157,unused158,unused159,unused160,unused161,unused162,unused163,unused164,unused165,unused166,unused167,unused168,unused169,unused170,unused171,unused172,unused173,unused174,unused175,unused176,unused177,unused178,unused179,unused180,unused181,unused182,unused183,unused184,unused185,unused186,unused187,unused188,unused189,unused190,unused191,unused192,unused193,unused194,unused195,unused196,unused197,unused198,unused199,unused200,unused201,unused202,unused203,unused204,unused205,unused206,unused207,unused208,unused209,unused210,unused211,unused212,unused213,unused214,unused215,unused216,unused217,unused218,unused219,unused220,unused221,unused222,unused223,unused224,unused225,unused226,unused227,unused228,unused229,unused230,unused231,unused232,unused233,unused234,unused235,unused236,unused237,unused238,unused239,unused240,unused241,unused242,unused243,unused244,unused245,unused246,unused247,unused248,unused249,unused250,unused251,unused252,unused253,unused254,unused255
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$TargetDigest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$TargetVmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('rootfs','mp0','mp1','mp2','mp3','mp4','mp5','mp6','mp7','mp8','mp9','mp10','mp11','mp12','mp13','mp14','mp15','mp16','mp17','mp18','mp19','mp20','mp21','mp22','mp23','mp24','mp25','mp26','mp27','mp28','mp29','mp30','mp31','mp32','mp33','mp34','mp35','mp36','mp37','mp38','mp39','mp40','mp41','mp42','mp43','mp44','mp45','mp46','mp47','mp48','mp49','mp50','mp51','mp52','mp53','mp54','mp55','mp56','mp57','mp58','mp59','mp60','mp61','mp62','mp63','mp64','mp65','mp66','mp67','mp68','mp69','mp70','mp71','mp72','mp73','mp74','mp75','mp76','mp77','mp78','mp79','mp80','mp81','mp82','mp83','mp84','mp85','mp86','mp87','mp88','mp89','mp90','mp91','mp92','mp93','mp94','mp95','mp96','mp97','mp98','mp99','mp100','mp101','mp102','mp103','mp104','mp105','mp106','mp107','mp108','mp109','mp110','mp111','mp112','mp113','mp114','mp115','mp116','mp117','mp118','mp119','mp120','mp121','mp122','mp123','mp124','mp125','mp126','mp127','mp128','mp129','mp130','mp131','mp132','mp133','mp134','mp135','mp136','mp137','mp138','mp139','mp140','mp141','mp142','mp143','mp144','mp145','mp146','mp147','mp148','mp149','mp150','mp151','mp152','mp153','mp154','mp155','mp156','mp157','mp158','mp159','mp160','mp161','mp162','mp163','mp164','mp165','mp166','mp167','mp168','mp169','mp170','mp171','mp172','mp173','mp174','mp175','mp176','mp177','mp178','mp179','mp180','mp181','mp182','mp183','mp184','mp185','mp186','mp187','mp188','mp189','mp190','mp191','mp192','mp193','mp194','mp195','mp196','mp197','mp198','mp199','mp200','mp201','mp202','mp203','mp204','mp205','mp206','mp207','mp208','mp209','mp210','mp211','mp212','mp213','mp214','mp215','mp216','mp217','mp218','mp219','mp220','mp221','mp222','mp223','mp224','mp225','mp226','mp227','mp228','mp229','mp230','mp231','mp232','mp233','mp234','mp235','mp236','mp237','mp238','mp239','mp240','mp241','mp242','mp243','mp244','mp245','mp246','mp247','mp248','mp249','mp250','mp251','mp252','mp253','mp254','mp255','unused0','unused1','unused2','unused3','unused4','unused5','unused6','unused7','unused8','unused9','unused10','unused11','unused12','unused13','unused14','unused15','unused16','unused17','unused18','unused19','unused20','unused21','unused22','unused23','unused24','unused25','unused26','unused27','unused28','unused29','unused30','unused31','unused32','unused33','unused34','unused35','unused36','unused37','unused38','unused39','unused40','unused41','unused42','unused43','unused44','unused45','unused46','unused47','unused48','unused49','unused50','unused51','unused52','unused53','unused54','unused55','unused56','unused57','unused58','unused59','unused60','unused61','unused62','unused63','unused64','unused65','unused66','unused67','unused68','unused69','unused70','unused71','unused72','unused73','unused74','unused75','unused76','unused77','unused78','unused79','unused80','unused81','unused82','unused83','unused84','unused85','unused86','unused87','unused88','unused89','unused90','unused91','unused92','unused93','unused94','unused95','unused96','unused97','unused98','unused99','unused100','unused101','unused102','unused103','unused104','unused105','unused106','unused107','unused108','unused109','unused110','unused111','unused112','unused113','unused114','unused115','unused116','unused117','unused118','unused119','unused120','unused121','unused122','unused123','unused124','unused125','unused126','unused127','unused128','unused129','unused130','unused131','unused132','unused133','unused134','unused135','unused136','unused137','unused138','unused139','unused140','unused141','unused142','unused143','unused144','unused145','unused146','unused147','unused148','unused149','unused150','unused151','unused152','unused153','unused154','unused155','unused156','unused157','unused158','unused159','unused160','unused161','unused162','unused163','unused164','unused165','unused166','unused167','unused168','unused169','unused170','unused171','unused172','unused173','unused174','unused175','unused176','unused177','unused178','unused179','unused180','unused181','unused182','unused183','unused184','unused185','unused186','unused187','unused188','unused189','unused190','unused191','unused192','unused193','unused194','unused195','unused196','unused197','unused198','unused199','unused200','unused201','unused202','unused203','unused204','unused205','unused206','unused207','unused208','unused209','unused210','unused211','unused212','unused213','unused214','unused215','unused216','unused217','unused218','unused219','unused220','unused221','unused222','unused223','unused224','unused225','unused226','unused227','unused228','unused229','unused230','unused231','unused232','unused233','unused234','unused235','unused236','unused237','unused238','unused239','unused240','unused241','unused242','unused243','unused244','unused245','unused246','unused247','unused248','unused249','unused250','unused251','unused252','unused253','unused254','unused255')]
        [string]$TargetVolume,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('rootfs','mp0','mp1','mp2','mp3','mp4','mp5','mp6','mp7','mp8','mp9','mp10','mp11','mp12','mp13','mp14','mp15','mp16','mp17','mp18','mp19','mp20','mp21','mp22','mp23','mp24','mp25','mp26','mp27','mp28','mp29','mp30','mp31','mp32','mp33','mp34','mp35','mp36','mp37','mp38','mp39','mp40','mp41','mp42','mp43','mp44','mp45','mp46','mp47','mp48','mp49','mp50','mp51','mp52','mp53','mp54','mp55','mp56','mp57','mp58','mp59','mp60','mp61','mp62','mp63','mp64','mp65','mp66','mp67','mp68','mp69','mp70','mp71','mp72','mp73','mp74','mp75','mp76','mp77','mp78','mp79','mp80','mp81','mp82','mp83','mp84','mp85','mp86','mp87','mp88','mp89','mp90','mp91','mp92','mp93','mp94','mp95','mp96','mp97','mp98','mp99','mp100','mp101','mp102','mp103','mp104','mp105','mp106','mp107','mp108','mp109','mp110','mp111','mp112','mp113','mp114','mp115','mp116','mp117','mp118','mp119','mp120','mp121','mp122','mp123','mp124','mp125','mp126','mp127','mp128','mp129','mp130','mp131','mp132','mp133','mp134','mp135','mp136','mp137','mp138','mp139','mp140','mp141','mp142','mp143','mp144','mp145','mp146','mp147','mp148','mp149','mp150','mp151','mp152','mp153','mp154','mp155','mp156','mp157','mp158','mp159','mp160','mp161','mp162','mp163','mp164','mp165','mp166','mp167','mp168','mp169','mp170','mp171','mp172','mp173','mp174','mp175','mp176','mp177','mp178','mp179','mp180','mp181','mp182','mp183','mp184','mp185','mp186','mp187','mp188','mp189','mp190','mp191','mp192','mp193','mp194','mp195','mp196','mp197','mp198','mp199','mp200','mp201','mp202','mp203','mp204','mp205','mp206','mp207','mp208','mp209','mp210','mp211','mp212','mp213','mp214','mp215','mp216','mp217','mp218','mp219','mp220','mp221','mp222','mp223','mp224','mp225','mp226','mp227','mp228','mp229','mp230','mp231','mp232','mp233','mp234','mp235','mp236','mp237','mp238','mp239','mp240','mp241','mp242','mp243','mp244','mp245','mp246','mp247','mp248','mp249','mp250','mp251','mp252','mp253','mp254','mp255','unused0','unused1','unused2','unused3','unused4','unused5','unused6','unused7','unused8','unused9','unused10','unused11','unused12','unused13','unused14','unused15','unused16','unused17','unused18','unused19','unused20','unused21','unused22','unused23','unused24','unused25','unused26','unused27','unused28','unused29','unused30','unused31','unused32','unused33','unused34','unused35','unused36','unused37','unused38','unused39','unused40','unused41','unused42','unused43','unused44','unused45','unused46','unused47','unused48','unused49','unused50','unused51','unused52','unused53','unused54','unused55','unused56','unused57','unused58','unused59','unused60','unused61','unused62','unused63','unused64','unused65','unused66','unused67','unused68','unused69','unused70','unused71','unused72','unused73','unused74','unused75','unused76','unused77','unused78','unused79','unused80','unused81','unused82','unused83','unused84','unused85','unused86','unused87','unused88','unused89','unused90','unused91','unused92','unused93','unused94','unused95','unused96','unused97','unused98','unused99','unused100','unused101','unused102','unused103','unused104','unused105','unused106','unused107','unused108','unused109','unused110','unused111','unused112','unused113','unused114','unused115','unused116','unused117','unused118','unused119','unused120','unused121','unused122','unused123','unused124','unused125','unused126','unused127','unused128','unused129','unused130','unused131','unused132','unused133','unused134','unused135','unused136','unused137','unused138','unused139','unused140','unused141','unused142','unused143','unused144','unused145','unused146','unused147','unused148','unused149','unused150','unused151','unused152','unused153','unused154','unused155','unused156','unused157','unused158','unused159','unused160','unused161','unused162','unused163','unused164','unused165','unused166','unused167','unused168','unused169','unused170','unused171','unused172','unused173','unused174','unused175','unused176','unused177','unused178','unused179','unused180','unused181','unused182','unused183','unused184','unused185','unused186','unused187','unused188','unused189','unused190','unused191','unused192','unused193','unused194','unused195','unused196','unused197','unused198','unused199','unused200','unused201','unused202','unused203','unused204','unused205','unused206','unused207','unused208','unused209','unused210','unused211','unused212','unused213','unused214','unused215','unused216','unused217','unused218','unused219','unused220','unused221','unused222','unused223','unused224','unused225','unused226','unused227','unused228','unused229','unused230','unused231','unused232','unused233','unused234','unused235','unused236','unused237','unused238','unused239','unused240','unused241','unused242','unused243','unused244','unused245','unused246','unused247','unused248','unused249','unused250','unused251','unused252','unused253','unused254','unused255')]
        [string]$Volume
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['TargetDigest']) { $parameters['target-digest'] = $TargetDigest }
        if($PSBoundParameters['TargetVmid']) { $parameters['target-vmid'] = $TargetVmid }
        if($PSBoundParameters['TargetVolume']) { $parameters['target-volume'] = $TargetVolume }
        if($PSBoundParameters['Volume']) { $parameters['volume'] = $Volume }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/move_volume" -Parameters $parameters
    }
}

function Get-PveNodesLxcPending
{
<#
.DESCRIPTION
Get container configuration, including pending changes.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/pending"
    }
}

function Get-PveNodesLxcInterfaces
{
<#
.DESCRIPTION
Get IP addresses of the specified container interface.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/interfaces"
    }
}

function New-PveNodesLxcMtunnel
{
<#
.DESCRIPTION
Migration tunnel endpoint - only for internal use by CT migration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Bridges
List of network bridges to check availability. Will be checked again for actually used bridges during migration.
.PARAMETER Node
The cluster node name.
.PARAMETER Storages
List of storages to check permission and availability. Will be checked again for all actually used storages during migration.
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bridges,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storages,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Bridges']) { $parameters['bridges'] = $Bridges }
        if($PSBoundParameters['Storages']) { $parameters['storages'] = $Storages }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/lxc/$Vmid/mtunnel" -Parameters $parameters
    }
}

function Get-PveNodesLxcMtunnelwebsocket
{
<#
.DESCRIPTION
Migration tunnel endpoint for websocket upgrade - only for internal use by VM migration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Socket
unix socket to forward to
.PARAMETER Ticket
ticket return by initial 'mtunnel' API call, or retrieved via 'ticket' tunnel command
.PARAMETER Vmid
The (unique) ID of the VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Socket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ticket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Socket']) { $parameters['socket'] = $Socket }
        if($PSBoundParameters['Ticket']) { $parameters['ticket'] = $Ticket }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/lxc/$Vmid/mtunnelwebsocket" -Parameters $parameters
    }
}

function Get-PveNodesCeph
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph"
    }
}

function Get-PveNodesCephCfg
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/cfg"
    }
}

function Get-PveNodesCephCfgRaw
{
<#
.DESCRIPTION
Get the Ceph configuration file.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/cfg/raw"
    }
}

function Get-PveNodesCephCfgDb
{
<#
.DESCRIPTION
Get the Ceph configuration database.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/cfg/db"
    }
}

function Get-PveNodesCephCfgValue
{
<#
.DESCRIPTION
Get configured values from either the config file or config DB.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER ConfigKeys
List of <section>':'<config key> items.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$ConfigKeys,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['ConfigKeys']) { $parameters['config-keys'] = $ConfigKeys }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/cfg/value" -Parameters $parameters
    }
}

function Get-PveNodesCephOsd
{
<#
.DESCRIPTION
Get Ceph osd list/tree.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/osd"
    }
}

function New-PveNodesCephOsd
{
<#
.DESCRIPTION
Create OSD
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER CrushDeviceClass
Set the device class of the OSD in crush.
.PARAMETER DbDev
Block device name for block.db.
.PARAMETER DbDevSize
Size in GiB for block.db.
.PARAMETER Dev
Block device name.
.PARAMETER Encrypted
Enables encryption of the OSD.
.PARAMETER Node
The cluster node name.
.PARAMETER OsdsPerDevice
OSD services per physical device. Only useful for fast NVMe devices"		    ." to utilize their performance better.
.PARAMETER WalDev
Block device name for block.wal.
.PARAMETER WalDevSize
Size in GiB for block.wal.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$CrushDeviceClass,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$DbDev,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$DbDevSize,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Dev,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Encrypted,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$OsdsPerDevice,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$WalDev,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$WalDevSize
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['CrushDeviceClass']) { $parameters['crush-device-class'] = $CrushDeviceClass }
        if($PSBoundParameters['DbDev']) { $parameters['db_dev'] = $DbDev }
        if($PSBoundParameters['DbDevSize']) { $parameters['db_dev_size'] = $DbDevSize }
        if($PSBoundParameters['Dev']) { $parameters['dev'] = $Dev }
        if($PSBoundParameters['Encrypted']) { $parameters['encrypted'] = $Encrypted }
        if($PSBoundParameters['OsdsPerDevice']) { $parameters['osds-per-device'] = $OsdsPerDevice }
        if($PSBoundParameters['WalDev']) { $parameters['wal_dev'] = $WalDev }
        if($PSBoundParameters['WalDevSize']) { $parameters['wal_dev_size'] = $WalDevSize }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/osd" -Parameters $parameters
    }
}

function Remove-PveNodesCephOsd
{
<#
.DESCRIPTION
Destroy OSD
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cleanup
If set, we remove partition table entries.
.PARAMETER Node
The cluster node name.
.PARAMETER Osdid
OSD ID
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Cleanup,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Osdid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cleanup']) { $parameters['cleanup'] = $Cleanup }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/ceph/osd/$Osdid" -Parameters $parameters
    }
}

function Get-PveNodesCephOsdIdx
{
<#
.DESCRIPTION
OSD index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Osdid
OSD ID
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Osdid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/osd/$Osdid"
    }
}

function Get-PveNodesCephOsdMetadata
{
<#
.DESCRIPTION
Get OSD details
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Osdid
OSD ID
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Osdid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/osd/$Osdid/metadata"
    }
}

function Get-PveNodesCephOsdLvInfo
{
<#
.DESCRIPTION
Get OSD volume details
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Osdid
OSD ID
.PARAMETER Type
OSD device type Enum: block,db,wal
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Osdid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('block','db','wal')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/osd/$Osdid/lv-info" -Parameters $parameters
    }
}

function New-PveNodesCephOsdIn
{
<#
.DESCRIPTION
ceph osd in
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Osdid
OSD ID
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Osdid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/osd/$Osdid/in"
    }
}

function New-PveNodesCephOsdOut
{
<#
.DESCRIPTION
ceph osd out
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Osdid
OSD ID
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Osdid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/osd/$Osdid/out"
    }
}

function New-PveNodesCephOsdScrub
{
<#
.DESCRIPTION
Instruct the OSD to scrub.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Deep
If set, instructs a deep scrub instead of a normal one.
.PARAMETER Node
The cluster node name.
.PARAMETER Osdid
OSD ID
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Deep,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Osdid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Deep']) { $parameters['deep'] = $Deep }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/osd/$Osdid/scrub" -Parameters $parameters
    }
}

function Get-PveNodesCephMds
{
<#
.DESCRIPTION
MDS directory index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/mds"
    }
}

function Remove-PveNodesCephMds
{
<#
.DESCRIPTION
Destroy Ceph Metadata Server
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
The name (ID) of the mds
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/ceph/mds/$Name"
    }
}

function New-PveNodesCephMds
{
<#
.DESCRIPTION
Create Ceph Metadata Server (MDS)
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Hotstandby
Determines whether a ceph-mds daemon should poll and replay the log of an active MDS. Faster switch on MDS failure, but needs more idle resources.
.PARAMETER Name
The ID for the mds, when omitted the same as the nodename
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Hotstandby,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Hotstandby']) { $parameters['hotstandby'] = $Hotstandby }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/mds/$Name" -Parameters $parameters
    }
}

function Get-PveNodesCephMgr
{
<#
.DESCRIPTION
MGR directory index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/mgr"
    }
}

function Remove-PveNodesCephMgr
{
<#
.DESCRIPTION
Destroy Ceph Manager.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
The ID of the manager
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/ceph/mgr/$Id"
    }
}

function New-PveNodesCephMgr
{
<#
.DESCRIPTION
Create Ceph Manager
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
The ID for the manager, when omitted the same as the nodename
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/mgr/$Id"
    }
}

function Get-PveNodesCephMon
{
<#
.DESCRIPTION
Get Ceph monitor list.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/mon"
    }
}

function Remove-PveNodesCephMon
{
<#
.DESCRIPTION
Destroy Ceph Monitor and Manager.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Monid
Monitor ID
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Monid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/ceph/mon/$Monid"
    }
}

function New-PveNodesCephMon
{
<#
.DESCRIPTION
Create Ceph Monitor and Manager
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER MonAddress
Overwrites autodetected monitor IP address(es). Must be in the public network(s) of Ceph.
.PARAMETER Monid
The ID for the monitor, when omitted the same as the nodename
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$MonAddress,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Monid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['MonAddress']) { $parameters['mon-address'] = $MonAddress }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/mon/$Monid" -Parameters $parameters
    }
}

function Get-PveNodesCephFs
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/fs"
    }
}

function New-PveNodesCephFs
{
<#
.DESCRIPTION
Create a Ceph filesystem
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AddStorage
Configure the created CephFS as storage for this cluster.
.PARAMETER Name
The ceph filesystem name.
.PARAMETER Node
The cluster node name.
.PARAMETER PgNum
Number of placement groups for the backing data pool. The metadata pool will use a quarter of this.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AddStorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$PgNum
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AddStorage']) { $parameters['add-storage'] = $AddStorage }
        if($PSBoundParameters['PgNum']) { $parameters['pg_num'] = $PgNum }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/fs/$Name" -Parameters $parameters
    }
}

function Get-PveNodesCephPool
{
<#
.DESCRIPTION
List all pools and their settings (which are settable by the POST/PUT endpoints).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/pool"
    }
}

function New-PveNodesCephPool
{
<#
.DESCRIPTION
Create Ceph pool
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AddStorages
Configure VM and CT storage using the new pool.
.PARAMETER Application
The application of the pool. Enum: rbd,cephfs,rgw
.PARAMETER CrushRule
The rule to use for mapping object placement in the cluster.
.PARAMETER ErasureCoding
Create an erasure coded pool for RBD with an accompaning replicated pool for metadata storage. With EC, the common ceph options 'size', 'min_size' and 'crush_rule' parameters will be applied to the metadata pool.
.PARAMETER MinSize
Minimum number of replicas per object
.PARAMETER Name
The name of the pool. It must be unique.
.PARAMETER Node
The cluster node name.
.PARAMETER PgAutoscaleMode
The automatic PG scaling mode of the pool. Enum: on,off,warn
.PARAMETER PgNum
Number of placement groups.
.PARAMETER PgNumMin
Minimal number of placement groups.
.PARAMETER Size
Number of replicas per object
.PARAMETER TargetSize
The estimated target size of the pool for the PG autoscaler.
.PARAMETER TargetSizeRatio
The estimated target ratio of the pool for the PG autoscaler.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AddStorages,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('rbd','cephfs','rgw')]
        [string]$Application,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$CrushRule,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ErasureCoding,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MinSize,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('on','off','warn')]
        [string]$PgAutoscaleMode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$PgNum,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$PgNumMin,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Size,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$TargetSize,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$TargetSizeRatio
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AddStorages']) { $parameters['add_storages'] = $AddStorages }
        if($PSBoundParameters['Application']) { $parameters['application'] = $Application }
        if($PSBoundParameters['CrushRule']) { $parameters['crush_rule'] = $CrushRule }
        if($PSBoundParameters['ErasureCoding']) { $parameters['erasure-coding'] = $ErasureCoding }
        if($PSBoundParameters['MinSize']) { $parameters['min_size'] = $MinSize }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['PgAutoscaleMode']) { $parameters['pg_autoscale_mode'] = $PgAutoscaleMode }
        if($PSBoundParameters['PgNum']) { $parameters['pg_num'] = $PgNum }
        if($PSBoundParameters['PgNumMin']) { $parameters['pg_num_min'] = $PgNumMin }
        if($PSBoundParameters['Size']) { $parameters['size'] = $Size }
        if($PSBoundParameters['TargetSize']) { $parameters['target_size'] = $TargetSize }
        if($PSBoundParameters['TargetSizeRatio']) { $parameters['target_size_ratio'] = $TargetSizeRatio }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/pool" -Parameters $parameters
    }
}

function Remove-PveNodesCephPool
{
<#
.DESCRIPTION
Destroy pool
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
If true, destroys pool even if in use
.PARAMETER Name
The name of the pool. It must be unique.
.PARAMETER Node
The cluster node name.
.PARAMETER RemoveEcprofile
Remove the erasure code profile. Defaults to true, if applicable.
.PARAMETER RemoveStorages
Remove all pveceph-managed storages configured for this pool
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$RemoveEcprofile,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$RemoveStorages
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['RemoveEcprofile']) { $parameters['remove_ecprofile'] = $RemoveEcprofile }
        if($PSBoundParameters['RemoveStorages']) { $parameters['remove_storages'] = $RemoveStorages }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/ceph/pool/$Name" -Parameters $parameters
    }
}

function Get-PveNodesCephPoolIdx
{
<#
.DESCRIPTION
Pool index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
The name of the pool.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/pool/$Name"
    }
}

function Set-PveNodesCephPool
{
<#
.DESCRIPTION
Change POOL settings
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Application
The application of the pool. Enum: rbd,cephfs,rgw
.PARAMETER CrushRule
The rule to use for mapping object placement in the cluster.
.PARAMETER MinSize
Minimum number of replicas per object
.PARAMETER Name
The name of the pool. It must be unique.
.PARAMETER Node
The cluster node name.
.PARAMETER PgAutoscaleMode
The automatic PG scaling mode of the pool. Enum: on,off,warn
.PARAMETER PgNum
Number of placement groups.
.PARAMETER PgNumMin
Minimal number of placement groups.
.PARAMETER Size
Number of replicas per object
.PARAMETER TargetSize
The estimated target size of the pool for the PG autoscaler.
.PARAMETER TargetSizeRatio
The estimated target ratio of the pool for the PG autoscaler.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('rbd','cephfs','rgw')]
        [string]$Application,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$CrushRule,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MinSize,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('on','off','warn')]
        [string]$PgAutoscaleMode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$PgNum,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$PgNumMin,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Size,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$TargetSize,

        [Parameter(ValueFromPipelineByPropertyName)]
        [float]$TargetSizeRatio
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Application']) { $parameters['application'] = $Application }
        if($PSBoundParameters['CrushRule']) { $parameters['crush_rule'] = $CrushRule }
        if($PSBoundParameters['MinSize']) { $parameters['min_size'] = $MinSize }
        if($PSBoundParameters['PgAutoscaleMode']) { $parameters['pg_autoscale_mode'] = $PgAutoscaleMode }
        if($PSBoundParameters['PgNum']) { $parameters['pg_num'] = $PgNum }
        if($PSBoundParameters['PgNumMin']) { $parameters['pg_num_min'] = $PgNumMin }
        if($PSBoundParameters['Size']) { $parameters['size'] = $Size }
        if($PSBoundParameters['TargetSize']) { $parameters['target_size'] = $TargetSize }
        if($PSBoundParameters['TargetSizeRatio']) { $parameters['target_size_ratio'] = $TargetSizeRatio }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/ceph/pool/$Name" -Parameters $parameters
    }
}

function Get-PveNodesCephPoolStatus
{
<#
.DESCRIPTION
Show the current pool status.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
The name of the pool. It must be unique.
.PARAMETER Node
The cluster node name.
.PARAMETER Verbose_
If enabled, will display additional data(eg. statistics).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Verbose_
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Verbose_']) { $parameters['verbose'] = $Verbose_ }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/pool/$Name/status" -Parameters $parameters
    }
}

function New-PveNodesCephInit
{
<#
.DESCRIPTION
Create initial ceph default configuration and setup symlinks.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER ClusterNetwork
Declare a separate cluster network, OSDs will routeheartbeat, object replication and recovery traffic over it
.PARAMETER DisableCephx
Disable cephx authentication.WARNING':' cephx is a security feature protecting against man-in-the-middle attacks. Only consider disabling cephx if your network is private!
.PARAMETER MinSize
Minimum number of available replicas per object to allow I/O
.PARAMETER Network
Use specific network for all ceph related traffic
.PARAMETER Node
The cluster node name.
.PARAMETER PgBits
Placement group bits, used to specify the default number of placement groups.Depreacted. This setting was deprecated in recent Ceph versions.
.PARAMETER Size
Targeted number of replicas per object
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ClusterNetwork,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$DisableCephx,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MinSize,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Network,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$PgBits,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Size
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['ClusterNetwork']) { $parameters['cluster-network'] = $ClusterNetwork }
        if($PSBoundParameters['DisableCephx']) { $parameters['disable_cephx'] = $DisableCephx }
        if($PSBoundParameters['MinSize']) { $parameters['min_size'] = $MinSize }
        if($PSBoundParameters['Network']) { $parameters['network'] = $Network }
        if($PSBoundParameters['PgBits']) { $parameters['pg_bits'] = $PgBits }
        if($PSBoundParameters['Size']) { $parameters['size'] = $Size }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/init" -Parameters $parameters
    }
}

function New-PveNodesCephStop
{
<#
.DESCRIPTION
Stop ceph services.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Ceph service name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Service
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Service']) { $parameters['service'] = $Service }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/stop" -Parameters $parameters
    }
}

function New-PveNodesCephStart
{
<#
.DESCRIPTION
Start ceph services.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Ceph service name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Service
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Service']) { $parameters['service'] = $Service }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/start" -Parameters $parameters
    }
}

function New-PveNodesCephRestart
{
<#
.DESCRIPTION
Restart ceph services.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Ceph service name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Service
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Service']) { $parameters['service'] = $Service }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/ceph/restart" -Parameters $parameters
    }
}

function Get-PveNodesCephStatus
{
<#
.DESCRIPTION
Get ceph status.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/status"
    }
}

function Get-PveNodesCephCrush
{
<#
.DESCRIPTION
Get OSD crush map
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/crush"
    }
}

function Get-PveNodesCephLog
{
<#
.DESCRIPTION
Read ceph log
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Limit
--
.PARAMETER Node
The cluster node name.
.PARAMETER Start
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Limit,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Start
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Limit']) { $parameters['limit'] = $Limit }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/log" -Parameters $parameters
    }
}

function Get-PveNodesCephRules
{
<#
.DESCRIPTION
List ceph rules.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/rules"
    }
}

function Get-PveNodesCephCmdSafety
{
<#
.DESCRIPTION
Heuristical check if it is safe to perform an action.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Action to check Enum: stop,destroy
.PARAMETER Id
ID of the service
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Service type Enum: osd,mon,mds
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('stop','destroy')]
        [string]$Action,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('osd','mon','mds')]
        [string]$Service
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Id']) { $parameters['id'] = $Id }
        if($PSBoundParameters['Service']) { $parameters['service'] = $Service }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/ceph/cmd-safety" -Parameters $parameters
    }
}

function New-PveNodesVzdump
{
<#
.DESCRIPTION
Create backup.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER All
Backup all known guest systems on this host.
.PARAMETER Bwlimit
Limit I/O bandwidth (in KiB/s).
.PARAMETER Compress
Compress dump file. Enum: 0,1,gzip,lzo,zstd
.PARAMETER Dumpdir
Store resulting files to specified directory.
.PARAMETER Exclude
Exclude specified guest systems (assumes --all)
.PARAMETER ExcludePath
Exclude certain files/directories (shell globs). Paths starting with '/' are anchored to the container's root,  other paths match relative to each subdirectory.
.PARAMETER Ionice
Set IO priority when using the BFQ scheduler. For snapshot and suspend mode backups of VMs, this only affects the compressor. A value of 8 means the idle priority is used, otherwise the best-effort priority is used with the specified value.
.PARAMETER Lockwait
Maximal time to wait for the global lock (minutes).
.PARAMETER Mailnotification
Deprecated':' use 'notification-policy' instead. Enum: always,failure
.PARAMETER Mailto
Comma-separated list of email addresses or users that should receive email notifications. Has no effect if the 'notification-target' option  is set at the same time.
.PARAMETER Maxfiles
Deprecated':' use 'prune-backups' instead. Maximal number of backup files per guest system.
.PARAMETER Mode
Backup mode. Enum: snapshot,suspend,stop
.PARAMETER Node
Only run if executed on this node.
.PARAMETER NotesTemplate
Template string for generating notes for the backup(s). It can contain variables which will be replaced by their values. Currently supported are {{cluster}}, {{guestname}}, {{node}}, and {{vmid}}, but more might be added in the future. Needs to be a single line, newline and backslash need to be escaped as '\n' and '\\' respectively.
.PARAMETER NotificationPolicy
Specify when to send a notification Enum: always,failure,never
.PARAMETER NotificationTarget
Determine the target to which notifications should be sent. Can either be a notification endpoint or a notification group. This option takes precedence over 'mailto', meaning that if both are  set, the 'mailto' option will be ignored.
.PARAMETER Performance
Other performance-related settings.
.PARAMETER Pigz
Use pigz instead of gzip when N>0. N=1 uses half of cores, N>1 uses N as thread count.
.PARAMETER Pool
Backup all known guest systems included in the specified pool.
.PARAMETER Protected
If true, mark backup(s) as protected.
.PARAMETER PruneBackups
Use these retention options instead of those from the storage configuration.
.PARAMETER Quiet
Be quiet.
.PARAMETER Remove
Prune older backups according to 'prune-backups'.
.PARAMETER Script
Use specified hook script.
.PARAMETER Stdexcludes
Exclude temporary files and logs.
.PARAMETER Stdout
Write tar to stdout, not to a file.
.PARAMETER Stop
Stop running backup jobs on this host.
.PARAMETER Stopwait
Maximal time to wait until a guest system is stopped (minutes).
.PARAMETER Storage
Store resulting file to this storage.
.PARAMETER Tmpdir
Store temporary files to specified directory.
.PARAMETER Vmid
The ID of the guest system you want to backup.
.PARAMETER Zstd
Zstd threads. N=0 uses half of the available cores, N>0 uses N as thread count.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$All,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('0','1','gzip','lzo','zstd')]
        [string]$Compress,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dumpdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Exclude,

        [Parameter(ValueFromPipelineByPropertyName)]
        [array]$ExcludePath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Ionice,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Lockwait,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('always','failure')]
        [string]$Mailnotification,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mailto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Maxfiles,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('snapshot','suspend','stop')]
        [string]$Mode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$NotesTemplate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('always','failure','never')]
        [string]$NotificationPolicy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$NotificationTarget,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Performance,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pigz,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Pool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Protected,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PruneBackups,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Quiet,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Remove,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Script,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Stdexcludes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Stdout,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Stop,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Stopwait,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tmpdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vmid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Zstd
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['All']) { $parameters['all'] = $All }
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['Compress']) { $parameters['compress'] = $Compress }
        if($PSBoundParameters['Dumpdir']) { $parameters['dumpdir'] = $Dumpdir }
        if($PSBoundParameters['Exclude']) { $parameters['exclude'] = $Exclude }
        if($PSBoundParameters['ExcludePath']) { $parameters['exclude-path'] = $ExcludePath }
        if($PSBoundParameters['Ionice']) { $parameters['ionice'] = $Ionice }
        if($PSBoundParameters['Lockwait']) { $parameters['lockwait'] = $Lockwait }
        if($PSBoundParameters['Mailnotification']) { $parameters['mailnotification'] = $Mailnotification }
        if($PSBoundParameters['Mailto']) { $parameters['mailto'] = $Mailto }
        if($PSBoundParameters['Maxfiles']) { $parameters['maxfiles'] = $Maxfiles }
        if($PSBoundParameters['Mode']) { $parameters['mode'] = $Mode }
        if($PSBoundParameters['NotesTemplate']) { $parameters['notes-template'] = $NotesTemplate }
        if($PSBoundParameters['NotificationPolicy']) { $parameters['notification-policy'] = $NotificationPolicy }
        if($PSBoundParameters['NotificationTarget']) { $parameters['notification-target'] = $NotificationTarget }
        if($PSBoundParameters['Performance']) { $parameters['performance'] = $Performance }
        if($PSBoundParameters['Pigz']) { $parameters['pigz'] = $Pigz }
        if($PSBoundParameters['Pool']) { $parameters['pool'] = $Pool }
        if($PSBoundParameters['Protected']) { $parameters['protected'] = $Protected }
        if($PSBoundParameters['PruneBackups']) { $parameters['prune-backups'] = $PruneBackups }
        if($PSBoundParameters['Quiet']) { $parameters['quiet'] = $Quiet }
        if($PSBoundParameters['Remove']) { $parameters['remove'] = $Remove }
        if($PSBoundParameters['Script']) { $parameters['script'] = $Script }
        if($PSBoundParameters['Stdexcludes']) { $parameters['stdexcludes'] = $Stdexcludes }
        if($PSBoundParameters['Stdout']) { $parameters['stdout'] = $Stdout }
        if($PSBoundParameters['Stop']) { $parameters['stop'] = $Stop }
        if($PSBoundParameters['Stopwait']) { $parameters['stopwait'] = $Stopwait }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Tmpdir']) { $parameters['tmpdir'] = $Tmpdir }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }
        if($PSBoundParameters['Zstd']) { $parameters['zstd'] = $Zstd }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/vzdump" -Parameters $parameters
    }
}

function Get-PveNodesVzdumpDefaults
{
<#
.DESCRIPTION
Get the currently configured vzdump defaults.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/vzdump/defaults" -Parameters $parameters
    }
}

function Get-PveNodesVzdumpExtractconfig
{
<#
.DESCRIPTION
Extract configuration from vzdump backup archive.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Volume
Volume identifier
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Volume
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Volume']) { $parameters['volume'] = $Volume }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/vzdump/extractconfig" -Parameters $parameters
    }
}

function Get-PveNodesServices
{
<#
.DESCRIPTION
Service list.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/services"
    }
}

function Get-PveNodesServicesIdx
{
<#
.DESCRIPTION
Directory index
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Service ID Enum: chrony,corosync,cron,ksmtuned,postfix,pve-cluster,pve-firewall,pve-ha-crm,pve-ha-lrm,pvedaemon,pvefw-logger,pveproxy,pvescheduler,pvestatd,spiceproxy,sshd,syslog,systemd-journald,systemd-timesyncd
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('chrony','corosync','cron','ksmtuned','postfix','pve-cluster','pve-firewall','pve-ha-crm','pve-ha-lrm','pvedaemon','pvefw-logger','pveproxy','pvescheduler','pvestatd','spiceproxy','sshd','syslog','systemd-journald','systemd-timesyncd')]
        [string]$Service
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/services/$Service"
    }
}

function Get-PveNodesServicesState
{
<#
.DESCRIPTION
Read service properties
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Service ID Enum: chrony,corosync,cron,ksmtuned,postfix,pve-cluster,pve-firewall,pve-ha-crm,pve-ha-lrm,pvedaemon,pvefw-logger,pveproxy,pvescheduler,pvestatd,spiceproxy,sshd,syslog,systemd-journald,systemd-timesyncd
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('chrony','corosync','cron','ksmtuned','postfix','pve-cluster','pve-firewall','pve-ha-crm','pve-ha-lrm','pvedaemon','pvefw-logger','pveproxy','pvescheduler','pvestatd','spiceproxy','sshd','syslog','systemd-journald','systemd-timesyncd')]
        [string]$Service
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/services/$Service/state"
    }
}

function New-PveNodesServicesStart
{
<#
.DESCRIPTION
Start service.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Service ID Enum: chrony,corosync,cron,ksmtuned,postfix,pve-cluster,pve-firewall,pve-ha-crm,pve-ha-lrm,pvedaemon,pvefw-logger,pveproxy,pvescheduler,pvestatd,spiceproxy,sshd,syslog,systemd-journald,systemd-timesyncd
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('chrony','corosync','cron','ksmtuned','postfix','pve-cluster','pve-firewall','pve-ha-crm','pve-ha-lrm','pvedaemon','pvefw-logger','pveproxy','pvescheduler','pvestatd','spiceproxy','sshd','syslog','systemd-journald','systemd-timesyncd')]
        [string]$Service
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/services/$Service/start"
    }
}

function New-PveNodesServicesStop
{
<#
.DESCRIPTION
Stop service.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Service ID Enum: chrony,corosync,cron,ksmtuned,postfix,pve-cluster,pve-firewall,pve-ha-crm,pve-ha-lrm,pvedaemon,pvefw-logger,pveproxy,pvescheduler,pvestatd,spiceproxy,sshd,syslog,systemd-journald,systemd-timesyncd
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('chrony','corosync','cron','ksmtuned','postfix','pve-cluster','pve-firewall','pve-ha-crm','pve-ha-lrm','pvedaemon','pvefw-logger','pveproxy','pvescheduler','pvestatd','spiceproxy','sshd','syslog','systemd-journald','systemd-timesyncd')]
        [string]$Service
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/services/$Service/stop"
    }
}

function New-PveNodesServicesRestart
{
<#
.DESCRIPTION
Hard restart service. Use reload if you want to reduce interruptions.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Service ID Enum: chrony,corosync,cron,ksmtuned,postfix,pve-cluster,pve-firewall,pve-ha-crm,pve-ha-lrm,pvedaemon,pvefw-logger,pveproxy,pvescheduler,pvestatd,spiceproxy,sshd,syslog,systemd-journald,systemd-timesyncd
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('chrony','corosync','cron','ksmtuned','postfix','pve-cluster','pve-firewall','pve-ha-crm','pve-ha-lrm','pvedaemon','pvefw-logger','pveproxy','pvescheduler','pvestatd','spiceproxy','sshd','syslog','systemd-journald','systemd-timesyncd')]
        [string]$Service
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/services/$Service/restart"
    }
}

function New-PveNodesServicesReload
{
<#
.DESCRIPTION
Reload service. Falls back to restart if service cannot be reloaded.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Service ID Enum: chrony,corosync,cron,ksmtuned,postfix,pve-cluster,pve-firewall,pve-ha-crm,pve-ha-lrm,pvedaemon,pvefw-logger,pveproxy,pvescheduler,pvestatd,spiceproxy,sshd,syslog,systemd-journald,systemd-timesyncd
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('chrony','corosync','cron','ksmtuned','postfix','pve-cluster','pve-firewall','pve-ha-crm','pve-ha-lrm','pvedaemon','pvefw-logger','pveproxy','pvescheduler','pvestatd','spiceproxy','sshd','syslog','systemd-journald','systemd-timesyncd')]
        [string]$Service
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/services/$Service/reload"
    }
}

function Remove-PveNodesSubscription
{
<#
.DESCRIPTION
Delete subscription key of this node.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/subscription"
    }
}

function Get-PveNodesSubscription
{
<#
.DESCRIPTION
Read subscription info.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/subscription"
    }
}

function New-PveNodesSubscription
{
<#
.DESCRIPTION
Update subscription info.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
Always connect to server, even if local cache is still valid.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/subscription" -Parameters $parameters
    }
}

function Set-PveNodesSubscription
{
<#
.DESCRIPTION
Set subscription key.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Key
Proxmox VE subscription key
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Key,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Key']) { $parameters['key'] = $Key }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/subscription" -Parameters $parameters
    }
}

function Remove-PveNodesNetwork
{
<#
.DESCRIPTION
Revert network configuration changes.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/network"
    }
}

function Get-PveNodesNetwork
{
<#
.DESCRIPTION
List available networks
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Type
Only list specific interface types. Enum: bridge,bond,eth,alias,vlan,OVSBridge,OVSBond,OVSPort,OVSIntPort,any_bridge,any_local_bridge
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('bridge','bond','eth','alias','vlan','OVSBridge','OVSBond','OVSPort','OVSIntPort','any_bridge','any_local_bridge')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/network" -Parameters $parameters
    }
}

function New-PveNodesNetwork
{
<#
.DESCRIPTION
Create network device configuration
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Address
IP address.
.PARAMETER Address6
IP address.
.PARAMETER Autostart
Automatically start interface on boot.
.PARAMETER BondPrimary
Specify the primary interface for active-backup bond.
.PARAMETER BondMode
Bonding mode. Enum: balance-rr,active-backup,balance-xor,broadcast,802.3ad,balance-tlb,balance-alb,balance-slb,lacp-balance-slb,lacp-balance-tcp
.PARAMETER BondXmitHashPolicy
Selects the transmit hash policy to use for slave selection in balance-xor and 802.3ad modes. Enum: layer2,layer2+3,layer3+4
.PARAMETER BridgePorts
Specify the interfaces you want to add to your bridge.
.PARAMETER BridgeVlanAware
Enable bridge vlan support.
.PARAMETER Cidr
IPv4 CIDR.
.PARAMETER Cidr6
IPv6 CIDR.
.PARAMETER Comments
Comments
.PARAMETER Comments6
Comments
.PARAMETER Gateway
Default gateway address.
.PARAMETER Gateway6
Default ipv6 gateway address.
.PARAMETER Iface
Network interface name.
.PARAMETER Mtu
MTU.
.PARAMETER Netmask
Network mask.
.PARAMETER Netmask6
Network mask.
.PARAMETER Node
The cluster node name.
.PARAMETER OvsBonds
Specify the interfaces used by the bonding device.
.PARAMETER OvsBridge
The OVS bridge associated with a OVS port. This is required when you create an OVS port.
.PARAMETER OvsOptions
OVS interface options.
.PARAMETER OvsPorts
Specify the interfaces you want to add to your bridge.
.PARAMETER OvsTag
Specify a VLan tag (used by OVSPort, OVSIntPort, OVSBond)
.PARAMETER Slaves
Specify the interfaces used by the bonding device.
.PARAMETER Type
Network interface type Enum: bridge,bond,eth,alias,vlan,OVSBridge,OVSBond,OVSPort,OVSIntPort,unknown
.PARAMETER VlanId
vlan-id for a custom named vlan interface (ifupdown2 only).
.PARAMETER VlanRawDevice
Specify the raw interface for the vlan interface.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Address,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Address6,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Autostart,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$BondPrimary,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('balance-rr','active-backup','balance-xor','broadcast','802.3ad','balance-tlb','balance-alb','balance-slb','lacp-balance-slb','lacp-balance-tcp')]
        [string]$BondMode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('layer2','layer2+3','layer3+4')]
        [string]$BondXmitHashPolicy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$BridgePorts,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$BridgeVlanAware,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cidr6,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comments,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comments6,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Gateway,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Gateway6,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Mtu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Netmask,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Netmask6,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OvsBonds,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OvsBridge,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OvsOptions,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OvsPorts,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$OvsTag,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Slaves,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('bridge','bond','eth','alias','vlan','OVSBridge','OVSBond','OVSPort','OVSIntPort','unknown')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$VlanId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$VlanRawDevice
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Address']) { $parameters['address'] = $Address }
        if($PSBoundParameters['Address6']) { $parameters['address6'] = $Address6 }
        if($PSBoundParameters['Autostart']) { $parameters['autostart'] = $Autostart }
        if($PSBoundParameters['BondPrimary']) { $parameters['bond-primary'] = $BondPrimary }
        if($PSBoundParameters['BondMode']) { $parameters['bond_mode'] = $BondMode }
        if($PSBoundParameters['BondXmitHashPolicy']) { $parameters['bond_xmit_hash_policy'] = $BondXmitHashPolicy }
        if($PSBoundParameters['BridgePorts']) { $parameters['bridge_ports'] = $BridgePorts }
        if($PSBoundParameters['BridgeVlanAware']) { $parameters['bridge_vlan_aware'] = $BridgeVlanAware }
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Cidr6']) { $parameters['cidr6'] = $Cidr6 }
        if($PSBoundParameters['Comments']) { $parameters['comments'] = $Comments }
        if($PSBoundParameters['Comments6']) { $parameters['comments6'] = $Comments6 }
        if($PSBoundParameters['Gateway']) { $parameters['gateway'] = $Gateway }
        if($PSBoundParameters['Gateway6']) { $parameters['gateway6'] = $Gateway6 }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Mtu']) { $parameters['mtu'] = $Mtu }
        if($PSBoundParameters['Netmask']) { $parameters['netmask'] = $Netmask }
        if($PSBoundParameters['Netmask6']) { $parameters['netmask6'] = $Netmask6 }
        if($PSBoundParameters['OvsBonds']) { $parameters['ovs_bonds'] = $OvsBonds }
        if($PSBoundParameters['OvsBridge']) { $parameters['ovs_bridge'] = $OvsBridge }
        if($PSBoundParameters['OvsOptions']) { $parameters['ovs_options'] = $OvsOptions }
        if($PSBoundParameters['OvsPorts']) { $parameters['ovs_ports'] = $OvsPorts }
        if($PSBoundParameters['OvsTag']) { $parameters['ovs_tag'] = $OvsTag }
        if($PSBoundParameters['Slaves']) { $parameters['slaves'] = $Slaves }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['VlanId']) { $parameters['vlan-id'] = $VlanId }
        if($PSBoundParameters['VlanRawDevice']) { $parameters['vlan-raw-device'] = $VlanRawDevice }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/network" -Parameters $parameters
    }
}

function Set-PveNodesNetwork
{
<#
.DESCRIPTION
Reload network configuration
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/network"
    }
}

function Remove-PveNodesNetworkIdx
{
<#
.DESCRIPTION
Delete network device configuration
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Iface
Network interface name.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/network/$Iface"
    }
}

function Get-PveNodesNetworkIdx
{
<#
.DESCRIPTION
Read network device configuration
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Iface
Network interface name.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/network/$Iface"
    }
}

function Set-PveNodesNetworkIdx
{
<#
.DESCRIPTION
Update network device configuration
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Address
IP address.
.PARAMETER Address6
IP address.
.PARAMETER Autostart
Automatically start interface on boot.
.PARAMETER BondPrimary
Specify the primary interface for active-backup bond.
.PARAMETER BondMode
Bonding mode. Enum: balance-rr,active-backup,balance-xor,broadcast,802.3ad,balance-tlb,balance-alb,balance-slb,lacp-balance-slb,lacp-balance-tcp
.PARAMETER BondXmitHashPolicy
Selects the transmit hash policy to use for slave selection in balance-xor and 802.3ad modes. Enum: layer2,layer2+3,layer3+4
.PARAMETER BridgePorts
Specify the interfaces you want to add to your bridge.
.PARAMETER BridgeVlanAware
Enable bridge vlan support.
.PARAMETER Cidr
IPv4 CIDR.
.PARAMETER Cidr6
IPv6 CIDR.
.PARAMETER Comments
Comments
.PARAMETER Comments6
Comments
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Gateway
Default gateway address.
.PARAMETER Gateway6
Default ipv6 gateway address.
.PARAMETER Iface
Network interface name.
.PARAMETER Mtu
MTU.
.PARAMETER Netmask
Network mask.
.PARAMETER Netmask6
Network mask.
.PARAMETER Node
The cluster node name.
.PARAMETER OvsBonds
Specify the interfaces used by the bonding device.
.PARAMETER OvsBridge
The OVS bridge associated with a OVS port. This is required when you create an OVS port.
.PARAMETER OvsOptions
OVS interface options.
.PARAMETER OvsPorts
Specify the interfaces you want to add to your bridge.
.PARAMETER OvsTag
Specify a VLan tag (used by OVSPort, OVSIntPort, OVSBond)
.PARAMETER Slaves
Specify the interfaces used by the bonding device.
.PARAMETER Type
Network interface type Enum: bridge,bond,eth,alias,vlan,OVSBridge,OVSBond,OVSPort,OVSIntPort,unknown
.PARAMETER VlanId
vlan-id for a custom named vlan interface (ifupdown2 only).
.PARAMETER VlanRawDevice
Specify the raw interface for the vlan interface.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Address,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Address6,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Autostart,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$BondPrimary,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('balance-rr','active-backup','balance-xor','broadcast','802.3ad','balance-tlb','balance-alb','balance-slb','lacp-balance-slb','lacp-balance-tcp')]
        [string]$BondMode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('layer2','layer2+3','layer3+4')]
        [string]$BondXmitHashPolicy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$BridgePorts,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$BridgeVlanAware,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cidr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cidr6,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comments,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comments6,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Gateway,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Gateway6,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Mtu,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Netmask,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Netmask6,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OvsBonds,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OvsBridge,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OvsOptions,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OvsPorts,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$OvsTag,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Slaves,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('bridge','bond','eth','alias','vlan','OVSBridge','OVSBond','OVSPort','OVSIntPort','unknown')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$VlanId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$VlanRawDevice
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Address']) { $parameters['address'] = $Address }
        if($PSBoundParameters['Address6']) { $parameters['address6'] = $Address6 }
        if($PSBoundParameters['Autostart']) { $parameters['autostart'] = $Autostart }
        if($PSBoundParameters['BondPrimary']) { $parameters['bond-primary'] = $BondPrimary }
        if($PSBoundParameters['BondMode']) { $parameters['bond_mode'] = $BondMode }
        if($PSBoundParameters['BondXmitHashPolicy']) { $parameters['bond_xmit_hash_policy'] = $BondXmitHashPolicy }
        if($PSBoundParameters['BridgePorts']) { $parameters['bridge_ports'] = $BridgePorts }
        if($PSBoundParameters['BridgeVlanAware']) { $parameters['bridge_vlan_aware'] = $BridgeVlanAware }
        if($PSBoundParameters['Cidr']) { $parameters['cidr'] = $Cidr }
        if($PSBoundParameters['Cidr6']) { $parameters['cidr6'] = $Cidr6 }
        if($PSBoundParameters['Comments']) { $parameters['comments'] = $Comments }
        if($PSBoundParameters['Comments6']) { $parameters['comments6'] = $Comments6 }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Gateway']) { $parameters['gateway'] = $Gateway }
        if($PSBoundParameters['Gateway6']) { $parameters['gateway6'] = $Gateway6 }
        if($PSBoundParameters['Mtu']) { $parameters['mtu'] = $Mtu }
        if($PSBoundParameters['Netmask']) { $parameters['netmask'] = $Netmask }
        if($PSBoundParameters['Netmask6']) { $parameters['netmask6'] = $Netmask6 }
        if($PSBoundParameters['OvsBonds']) { $parameters['ovs_bonds'] = $OvsBonds }
        if($PSBoundParameters['OvsBridge']) { $parameters['ovs_bridge'] = $OvsBridge }
        if($PSBoundParameters['OvsOptions']) { $parameters['ovs_options'] = $OvsOptions }
        if($PSBoundParameters['OvsPorts']) { $parameters['ovs_ports'] = $OvsPorts }
        if($PSBoundParameters['OvsTag']) { $parameters['ovs_tag'] = $OvsTag }
        if($PSBoundParameters['Slaves']) { $parameters['slaves'] = $Slaves }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['VlanId']) { $parameters['vlan-id'] = $VlanId }
        if($PSBoundParameters['VlanRawDevice']) { $parameters['vlan-raw-device'] = $VlanRawDevice }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/network/$Iface" -Parameters $parameters
    }
}

function Get-PveNodesTasks
{
<#
.DESCRIPTION
Read task list for one node (finished tasks).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Errors
Only list tasks with a status of ERROR.
.PARAMETER Limit
Only list this amount of tasks.
.PARAMETER Node
The cluster node name.
.PARAMETER Since
Only list tasks since this UNIX epoch.
.PARAMETER Source
List archived, active or all tasks. Enum: archive,active,all
.PARAMETER Start
List tasks beginning from this offset.
.PARAMETER Statusfilter
List of Task States that should be returned.
.PARAMETER Typefilter
Only list tasks of this type (e.g., vzstart, vzdump).
.PARAMETER Until
Only list tasks until this UNIX epoch.
.PARAMETER Userfilter
Only list tasks from this user.
.PARAMETER Vmid
Only list tasks for this VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Errors,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Limit,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Since,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('archive','active','all')]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Start,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Statusfilter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Typefilter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Until,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Userfilter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Errors']) { $parameters['errors'] = $Errors }
        if($PSBoundParameters['Limit']) { $parameters['limit'] = $Limit }
        if($PSBoundParameters['Since']) { $parameters['since'] = $Since }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }
        if($PSBoundParameters['Statusfilter']) { $parameters['statusfilter'] = $Statusfilter }
        if($PSBoundParameters['Typefilter']) { $parameters['typefilter'] = $Typefilter }
        if($PSBoundParameters['Until']) { $parameters['until'] = $Until }
        if($PSBoundParameters['Userfilter']) { $parameters['userfilter'] = $Userfilter }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/tasks" -Parameters $parameters
    }
}

function Remove-PveNodesTasks
{
<#
.DESCRIPTION
Stop a task.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Upid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Upid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/tasks/$Upid"
    }
}

function Get-PveNodesTasksIdx
{
<#
.DESCRIPTION
--
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Upid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Upid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/tasks/$Upid"
    }
}

function Get-PveNodesTasksLog
{
<#
.DESCRIPTION
Read task log.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Download
Whether the tasklog file should be downloaded. This parameter can't be used in conjunction with other parameters
.PARAMETER Limit
The amount of lines to read from the tasklog.
.PARAMETER Node
The cluster node name.
.PARAMETER Start
Start at this line when reading the tasklog
.PARAMETER Upid
The task's unique ID.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Download,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Limit,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Start,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Upid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Download']) { $parameters['download'] = $Download }
        if($PSBoundParameters['Limit']) { $parameters['limit'] = $Limit }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/tasks/$Upid/log" -Parameters $parameters
    }
}

function Get-PveNodesTasksStatus
{
<#
.DESCRIPTION
Read task status.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Upid
The task's unique ID.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Upid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/tasks/$Upid/status"
    }
}

function Get-PveNodesScan
{
<#
.DESCRIPTION
Index of available scan methods
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/scan"
    }
}

function Get-PveNodesScanNfs
{
<#
.DESCRIPTION
Scan remote NFS server.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Server
The server address (name or IP).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Server
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/scan/nfs" -Parameters $parameters
    }
}

function Get-PveNodesScanCifs
{
<#
.DESCRIPTION
Scan remote CIFS server.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Domain
SMB domain (Workgroup).
.PARAMETER Node
The cluster node name.
.PARAMETER Password
User password.
.PARAMETER Server
The server address (name or IP).
.PARAMETER Username
User name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Domain,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Username
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Domain']) { $parameters['domain'] = $Domain }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Username']) { $parameters['username'] = $Username }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/scan/cifs" -Parameters $parameters
    }
}

function Get-PveNodesScanPbs
{
<#
.DESCRIPTION
Scan remote Proxmox Backup Server.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Fingerprint
Certificate SHA 256 fingerprint.
.PARAMETER Node
The cluster node name.
.PARAMETER Password
User password or API token secret.
.PARAMETER Port
Optional port.
.PARAMETER Server
The server address (name or IP).
.PARAMETER Username
User-name or API token-ID.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Fingerprint,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Username
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Fingerprint']) { $parameters['fingerprint'] = $Fingerprint }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Username']) { $parameters['username'] = $Username }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/scan/pbs" -Parameters $parameters
    }
}

function Get-PveNodesScanGlusterfs
{
<#
.DESCRIPTION
Scan remote GlusterFS server.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Server
The server address (name or IP).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Server
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/scan/glusterfs" -Parameters $parameters
    }
}

function Get-PveNodesScanIscsi
{
<#
.DESCRIPTION
Scan remote iSCSI server.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Portal
The iSCSI portal (IP or DNS name with optional port).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Portal
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Portal']) { $parameters['portal'] = $Portal }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/scan/iscsi" -Parameters $parameters
    }
}

function Get-PveNodesScanLvm
{
<#
.DESCRIPTION
List local LVM volume groups.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/scan/lvm"
    }
}

function Get-PveNodesScanLvmthin
{
<#
.DESCRIPTION
List local LVM Thin Pools.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vg
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vg
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Vg']) { $parameters['vg'] = $Vg }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/scan/lvmthin" -Parameters $parameters
    }
}

function Get-PveNodesScanZfs
{
<#
.DESCRIPTION
Scan zfs pool list on local node.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/scan/zfs"
    }
}

function Get-PveNodesHardware
{
<#
.DESCRIPTION
Index of hardware types
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/hardware"
    }
}

function Get-PveNodesHardwarePci
{
<#
.DESCRIPTION
List local PCI devices.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER PciClassBlacklist
A list of blacklisted PCI classes, which will not be returned. Following are filtered by default':' Memory Controller (05), Bridge (06) and Processor (0b).
.PARAMETER Verbose_
If disabled, does only print the PCI IDs. Otherwise, additional information like vendor and device will be returned.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PciClassBlacklist,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Verbose_
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['PciClassBlacklist']) { $parameters['pci-class-blacklist'] = $PciClassBlacklist }
        if($PSBoundParameters['Verbose_']) { $parameters['verbose'] = $Verbose_ }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/hardware/pci" -Parameters $parameters
    }
}

function Get-PveNodesHardwarePciIdx
{
<#
.DESCRIPTION
Index of available pci methods
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Pciid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Pciid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/hardware/pci/$Pciid"
    }
}

function Get-PveNodesHardwarePciMdev
{
<#
.DESCRIPTION
List mediated device types for given PCI device.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Pciid
The PCI ID to list the mdev types for.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Pciid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/hardware/pci/$Pciid/mdev"
    }
}

function Get-PveNodesHardwareUsb
{
<#
.DESCRIPTION
List local USB devices.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/hardware/usb"
    }
}

function Get-PveNodesCapabilities
{
<#
.DESCRIPTION
Node capabilities index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/capabilities"
    }
}

function Get-PveNodesCapabilitiesQemu
{
<#
.DESCRIPTION
QEMU capabilities index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/capabilities/qemu"
    }
}

function Get-PveNodesCapabilitiesQemuCpu
{
<#
.DESCRIPTION
List all custom and default CPU models.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/capabilities/qemu/cpu"
    }
}

function Get-PveNodesCapabilitiesQemuMachines
{
<#
.DESCRIPTION
Get available QEMU/KVM machine types.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/capabilities/qemu/machines"
    }
}

function Get-PveNodesStorage
{
<#
.DESCRIPTION
Get status for all datastores.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Content
Only list stores which support this content type.
.PARAMETER Enabled
Only list stores which are enabled (not disabled in config).
.PARAMETER Format
Include information about formats
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
Only list status for  specified storage
.PARAMETER Target
If target is different to 'node', we only lists shared storages which content is accessible on this 'node' and the specified 'target' node.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Content,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enabled,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Format,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Target
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Content']) { $parameters['content'] = $Content }
        if($PSBoundParameters['Enabled']) { $parameters['enabled'] = $Enabled }
        if($PSBoundParameters['Format']) { $parameters['format'] = $Format }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/storage" -Parameters $parameters
    }
}

function Get-PveNodesStorageIdx
{
<#
.DESCRIPTION
--
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/storage/$Storage"
    }
}

function Remove-PveNodesStoragePrunebackups
{
<#
.DESCRIPTION
Prune backups. Only those using the standard naming scheme are considered.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER PruneBackups
Use these retention options instead of those from the storage configuration.
.PARAMETER Storage
The storage identifier.
.PARAMETER Type
Either 'qemu' or 'lxc'. Only consider backups for guests of this type. Enum: qemu,lxc
.PARAMETER Vmid
Only prune backups for this VM.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PruneBackups,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('qemu','lxc')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['PruneBackups']) { $parameters['prune-backups'] = $PruneBackups }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/storage/$Storage/prunebackups" -Parameters $parameters
    }
}

function Get-PveNodesStoragePrunebackups
{
<#
.DESCRIPTION
Get prune information for backups. NOTE':' this is only a preview and might not be what a subsequent prune call does if backups are removed/added in the meantime.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER PruneBackups
Use these retention options instead of those from the storage configuration.
.PARAMETER Storage
The storage identifier.
.PARAMETER Type
Either 'qemu' or 'lxc'. Only consider backups for guests of this type. Enum: qemu,lxc
.PARAMETER Vmid
Only consider backups for this guest.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PruneBackups,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('qemu','lxc')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['PruneBackups']) { $parameters['prune-backups'] = $PruneBackups }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/storage/$Storage/prunebackups" -Parameters $parameters
    }
}

function Get-PveNodesStorageContent
{
<#
.DESCRIPTION
List storage content.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Content
Only list content of this type.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.PARAMETER Vmid
Only list images for this VM
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Content,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Content']) { $parameters['content'] = $Content }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/storage/$Storage/content" -Parameters $parameters
    }
}

function New-PveNodesStorageContent
{
<#
.DESCRIPTION
Allocate disk images.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Filename
The name of the file to create.
.PARAMETER Format
-- Enum: raw,qcow2,subvol
.PARAMETER Node
The cluster node name.
.PARAMETER Size
Size in kilobyte (1024 bytes). Optional suffixes 'M' (megabyte, 1024K) and 'G' (gigabyte, 1024M)
.PARAMETER Storage
The storage identifier.
.PARAMETER Vmid
Specify owner VM
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Filename,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('raw','qcow2','subvol')]
        [string]$Format,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Size,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Vmid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Filename']) { $parameters['filename'] = $Filename }
        if($PSBoundParameters['Format']) { $parameters['format'] = $Format }
        if($PSBoundParameters['Size']) { $parameters['size'] = $Size }
        if($PSBoundParameters['Vmid']) { $parameters['vmid'] = $Vmid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/storage/$Storage/content" -Parameters $parameters
    }
}

function Remove-PveNodesStorageContent
{
<#
.DESCRIPTION
Delete volume
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delay
Time to wait for the task to finish. We return 'null' if the task finish within that time.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.PARAMETER Volume
Volume identifier
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Delay,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Volume
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delay']) { $parameters['delay'] = $Delay }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/storage/$Storage/content/$Volume" -Parameters $parameters
    }
}

function Get-PveNodesStorageContentIdx
{
<#
.DESCRIPTION
Get volume attributes
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.PARAMETER Volume
Volume identifier
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Volume
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/storage/$Storage/content/$Volume"
    }
}

function New-PveNodesStorageContentIdx
{
<#
.DESCRIPTION
Copy a volume. This is experimental code - do not use.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.PARAMETER Target
Target volume identifier
.PARAMETER TargetNode
Target node. Default is local node.
.PARAMETER Volume
Source volume identifier
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Target,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$TargetNode,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Volume
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }
        if($PSBoundParameters['TargetNode']) { $parameters['target_node'] = $TargetNode }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/storage/$Storage/content/$Volume" -Parameters $parameters
    }
}

function Set-PveNodesStorageContent
{
<#
.DESCRIPTION
Update volume attributes
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Notes
The new notes.
.PARAMETER Protected
Protection status. Currently only supported for backups.
.PARAMETER Storage
The storage identifier.
.PARAMETER Volume
Volume identifier
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Notes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Protected,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Volume
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Notes']) { $parameters['notes'] = $Notes }
        if($PSBoundParameters['Protected']) { $parameters['protected'] = $Protected }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/storage/$Storage/content/$Volume" -Parameters $parameters
    }
}

function Get-PveNodesStorageStatus
{
<#
.DESCRIPTION
Read storage status.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/storage/$Storage/status"
    }
}

function Get-PveNodesStorageRrd
{
<#
.DESCRIPTION
Read storage RRD statistics (returns PNG).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cf
The RRD consolidation function Enum: AVERAGE,MAX
.PARAMETER Ds
The list of datasources you want to display.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.PARAMETER Timeframe
Specify the time frame you are interested in. Enum: hour,day,week,month,year
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('AVERAGE','MAX')]
        [string]$Cf,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ds,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('hour','day','week','month','year')]
        [string]$Timeframe
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cf']) { $parameters['cf'] = $Cf }
        if($PSBoundParameters['Ds']) { $parameters['ds'] = $Ds }
        if($PSBoundParameters['Timeframe']) { $parameters['timeframe'] = $Timeframe }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/storage/$Storage/rrd" -Parameters $parameters
    }
}

function Get-PveNodesStorageRrddata
{
<#
.DESCRIPTION
Read storage RRD statistics.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cf
The RRD consolidation function Enum: AVERAGE,MAX
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.PARAMETER Timeframe
Specify the time frame you are interested in. Enum: hour,day,week,month,year
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('AVERAGE','MAX')]
        [string]$Cf,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('hour','day','week','month','year')]
        [string]$Timeframe
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cf']) { $parameters['cf'] = $Cf }
        if($PSBoundParameters['Timeframe']) { $parameters['timeframe'] = $Timeframe }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/storage/$Storage/rrddata" -Parameters $parameters
    }
}

function New-PveNodesStorageUpload
{
<#
.DESCRIPTION
Upload templates and ISO images.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Checksum
The expected checksum of the file.
.PARAMETER ChecksumAlgorithm
The algorithm to calculate the checksum of the file. Enum: md5,sha1,sha224,sha256,sha384,sha512
.PARAMETER Content
Content type. Enum: iso,vztmpl
.PARAMETER Filename
The name of the file to create. Caution':' This will be normalized!
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.PARAMETER Tmpfilename
The source file name. This parameter is usually set by the REST handler. You can only overwrite it when connecting to the trusted port on localhost.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Checksum,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('md5','sha1','sha224','sha256','sha384','sha512')]
        [string]$ChecksumAlgorithm,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('iso','vztmpl')]
        [string]$Content,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Filename,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tmpfilename
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Checksum']) { $parameters['checksum'] = $Checksum }
        if($PSBoundParameters['ChecksumAlgorithm']) { $parameters['checksum-algorithm'] = $ChecksumAlgorithm }
        if($PSBoundParameters['Content']) { $parameters['content'] = $Content }
        if($PSBoundParameters['Filename']) { $parameters['filename'] = $Filename }
        if($PSBoundParameters['Tmpfilename']) { $parameters['tmpfilename'] = $Tmpfilename }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/storage/$Storage/upload" -Parameters $parameters
    }
}

function New-PveNodesStorageDownloadUrl
{
<#
.DESCRIPTION
Download templates and ISO images by using an URL.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Checksum
The expected checksum of the file.
.PARAMETER ChecksumAlgorithm
The algorithm to calculate the checksum of the file. Enum: md5,sha1,sha224,sha256,sha384,sha512
.PARAMETER Compression
Decompress the downloaded file using the specified compression algorithm.
.PARAMETER Content
Content type. Enum: iso,vztmpl
.PARAMETER Filename
The name of the file to create. Caution':' This will be normalized!
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage identifier.
.PARAMETER Url
The URL to download the file from.
.PARAMETER VerifyCertificates
If false, no SSL/TLS certificates will be verified.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Checksum,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('md5','sha1','sha224','sha256','sha384','sha512')]
        [string]$ChecksumAlgorithm,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Compression,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('iso','vztmpl')]
        [string]$Content,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Filename,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Url,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$VerifyCertificates
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Checksum']) { $parameters['checksum'] = $Checksum }
        if($PSBoundParameters['ChecksumAlgorithm']) { $parameters['checksum-algorithm'] = $ChecksumAlgorithm }
        if($PSBoundParameters['Compression']) { $parameters['compression'] = $Compression }
        if($PSBoundParameters['Content']) { $parameters['content'] = $Content }
        if($PSBoundParameters['Filename']) { $parameters['filename'] = $Filename }
        if($PSBoundParameters['Url']) { $parameters['url'] = $Url }
        if($PSBoundParameters['VerifyCertificates']) { $parameters['verify-certificates'] = $VerifyCertificates }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/storage/$Storage/download-url" -Parameters $parameters
    }
}

function Get-PveNodesDisks
{
<#
.DESCRIPTION
Node index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/disks"
    }
}

function Get-PveNodesDisksLvm
{
<#
.DESCRIPTION
List LVM Volume Groups
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/disks/lvm"
    }
}

function New-PveNodesDisksLvm
{
<#
.DESCRIPTION
Create an LVM Volume Group
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AddStorage
Configure storage using the Volume Group
.PARAMETER Device
The block device you want to create the volume group on
.PARAMETER Name
The storage identifier.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AddStorage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Device,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AddStorage']) { $parameters['add_storage'] = $AddStorage }
        if($PSBoundParameters['Device']) { $parameters['device'] = $Device }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/disks/lvm" -Parameters $parameters
    }
}

function Remove-PveNodesDisksLvm
{
<#
.DESCRIPTION
Remove an LVM Volume Group.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER CleanupConfig
Marks associated storage(s) as not available on this node anymore or removes them from the configuration (if configured for this node only).
.PARAMETER CleanupDisks
Also wipe disks so they can be repurposed afterwards.
.PARAMETER Name
The storage identifier.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CleanupConfig,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CleanupDisks,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['CleanupConfig']) { $parameters['cleanup-config'] = $CleanupConfig }
        if($PSBoundParameters['CleanupDisks']) { $parameters['cleanup-disks'] = $CleanupDisks }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/disks/lvm/$Name" -Parameters $parameters
    }
}

function Get-PveNodesDisksLvmthin
{
<#
.DESCRIPTION
List LVM thinpools
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/disks/lvmthin"
    }
}

function New-PveNodesDisksLvmthin
{
<#
.DESCRIPTION
Create an LVM thinpool
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AddStorage
Configure storage using the thinpool.
.PARAMETER Device
The block device you want to create the thinpool on.
.PARAMETER Name
The storage identifier.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AddStorage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Device,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AddStorage']) { $parameters['add_storage'] = $AddStorage }
        if($PSBoundParameters['Device']) { $parameters['device'] = $Device }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/disks/lvmthin" -Parameters $parameters
    }
}

function Remove-PveNodesDisksLvmthin
{
<#
.DESCRIPTION
Remove an LVM thin pool.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER CleanupConfig
Marks associated storage(s) as not available on this node anymore or removes them from the configuration (if configured for this node only).
.PARAMETER CleanupDisks
Also wipe disks so they can be repurposed afterwards.
.PARAMETER Name
The storage identifier.
.PARAMETER Node
The cluster node name.
.PARAMETER VolumeGroup
The storage identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CleanupConfig,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CleanupDisks,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$VolumeGroup
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['CleanupConfig']) { $parameters['cleanup-config'] = $CleanupConfig }
        if($PSBoundParameters['CleanupDisks']) { $parameters['cleanup-disks'] = $CleanupDisks }
        if($PSBoundParameters['VolumeGroup']) { $parameters['volume-group'] = $VolumeGroup }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/disks/lvmthin/$Name" -Parameters $parameters
    }
}

function Get-PveNodesDisksDirectory
{
<#
.DESCRIPTION
PVE Managed Directory storages.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/disks/directory"
    }
}

function New-PveNodesDisksDirectory
{
<#
.DESCRIPTION
Create a Filesystem on an unused disk. Will be mounted under '/mnt/pve/NAME'.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AddStorage
Configure storage using the directory.
.PARAMETER Device
The block device you want to create the filesystem on.
.PARAMETER Filesystem
The desired filesystem. Enum: ext4,xfs
.PARAMETER Name
The storage identifier.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AddStorage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Device,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ext4','xfs')]
        [string]$Filesystem,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AddStorage']) { $parameters['add_storage'] = $AddStorage }
        if($PSBoundParameters['Device']) { $parameters['device'] = $Device }
        if($PSBoundParameters['Filesystem']) { $parameters['filesystem'] = $Filesystem }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/disks/directory" -Parameters $parameters
    }
}

function Remove-PveNodesDisksDirectory
{
<#
.DESCRIPTION
Unmounts the storage and removes the mount unit.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER CleanupConfig
Marks associated storage(s) as not available on this node anymore or removes them from the configuration (if configured for this node only).
.PARAMETER CleanupDisks
Also wipe disk so it can be repurposed afterwards.
.PARAMETER Name
The storage identifier.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CleanupConfig,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CleanupDisks,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['CleanupConfig']) { $parameters['cleanup-config'] = $CleanupConfig }
        if($PSBoundParameters['CleanupDisks']) { $parameters['cleanup-disks'] = $CleanupDisks }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/disks/directory/$Name" -Parameters $parameters
    }
}

function Get-PveNodesDisksZfs
{
<#
.DESCRIPTION
List Zpools.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/disks/zfs"
    }
}

function New-PveNodesDisksZfs
{
<#
.DESCRIPTION
Create a ZFS pool.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AddStorage
Configure storage using the zpool.
.PARAMETER Ashift
Pool sector size exponent.
.PARAMETER Compression
The compression algorithm to use. Enum: on,off,gzip,lz4,lzjb,zle,zstd
.PARAMETER Devices
The block devices you want to create the zpool on.
.PARAMETER DraidConfig
--
.PARAMETER Name
The storage identifier.
.PARAMETER Node
The cluster node name.
.PARAMETER Raidlevel
The RAID level to use. Enum: single,mirror,raid10,raidz,raidz2,raidz3,draid,draid2,draid3
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AddStorage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Ashift,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('on','off','gzip','lz4','lzjb','zle','zstd')]
        [string]$Compression,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Devices,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$DraidConfig,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('single','mirror','raid10','raidz','raidz2','raidz3','draid','draid2','draid3')]
        [string]$Raidlevel
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AddStorage']) { $parameters['add_storage'] = $AddStorage }
        if($PSBoundParameters['Ashift']) { $parameters['ashift'] = $Ashift }
        if($PSBoundParameters['Compression']) { $parameters['compression'] = $Compression }
        if($PSBoundParameters['Devices']) { $parameters['devices'] = $Devices }
        if($PSBoundParameters['DraidConfig']) { $parameters['draid-config'] = $DraidConfig }
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Raidlevel']) { $parameters['raidlevel'] = $Raidlevel }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/disks/zfs" -Parameters $parameters
    }
}

function Remove-PveNodesDisksZfs
{
<#
.DESCRIPTION
Destroy a ZFS pool.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER CleanupConfig
Marks associated storage(s) as not available on this node anymore or removes them from the configuration (if configured for this node only).
.PARAMETER CleanupDisks
Also wipe disks so they can be repurposed afterwards.
.PARAMETER Name
The storage identifier.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CleanupConfig,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CleanupDisks,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['CleanupConfig']) { $parameters['cleanup-config'] = $CleanupConfig }
        if($PSBoundParameters['CleanupDisks']) { $parameters['cleanup-disks'] = $CleanupDisks }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/disks/zfs/$Name" -Parameters $parameters
    }
}

function Get-PveNodesDisksZfsIdx
{
<#
.DESCRIPTION
Get details about a zpool.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
The storage identifier.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/disks/zfs/$Name"
    }
}

function Get-PveNodesDisksList
{
<#
.DESCRIPTION
List local disks.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER IncludePartitions
Also include partitions.
.PARAMETER Node
The cluster node name.
.PARAMETER Skipsmart
Skip smart checks.
.PARAMETER Type
Only list specific types of disks. Enum: unused,journal_disks
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$IncludePartitions,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Skipsmart,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('unused','journal_disks')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['IncludePartitions']) { $parameters['include-partitions'] = $IncludePartitions }
        if($PSBoundParameters['Skipsmart']) { $parameters['skipsmart'] = $Skipsmart }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/disks/list" -Parameters $parameters
    }
}

function Get-PveNodesDisksSmart
{
<#
.DESCRIPTION
Get SMART Health of a disk.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Disk
Block device name
.PARAMETER Healthonly
If true returns only the health status
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Disk,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Healthonly,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Disk']) { $parameters['disk'] = $Disk }
        if($PSBoundParameters['Healthonly']) { $parameters['healthonly'] = $Healthonly }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/disks/smart" -Parameters $parameters
    }
}

function New-PveNodesDisksInitgpt
{
<#
.DESCRIPTION
Initialize Disk with GPT
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Disk
Block device name
.PARAMETER Node
The cluster node name.
.PARAMETER Uuid
UUID for the GPT table
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Disk,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Uuid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Disk']) { $parameters['disk'] = $Disk }
        if($PSBoundParameters['Uuid']) { $parameters['uuid'] = $Uuid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/disks/initgpt" -Parameters $parameters
    }
}

function Set-PveNodesDisksWipedisk
{
<#
.DESCRIPTION
Wipe a disk or partition.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Disk
Block device name
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Disk,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Disk']) { $parameters['disk'] = $Disk }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/disks/wipedisk" -Parameters $parameters
    }
}

function Get-PveNodesApt
{
<#
.DESCRIPTION
Directory index for apt (Advanced Package Tool).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/apt"
    }
}

function Get-PveNodesAptUpdate
{
<#
.DESCRIPTION
List available updates.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/apt/update"
    }
}

function New-PveNodesAptUpdate
{
<#
.DESCRIPTION
This is used to resynchronize the package index files from their sources (apt-get update).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Notify
Send notification about new packages.
.PARAMETER Quiet
Only produces output suitable for logging, omitting progress indicators.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Notify,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Quiet
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Notify']) { $parameters['notify'] = $Notify }
        if($PSBoundParameters['Quiet']) { $parameters['quiet'] = $Quiet }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/apt/update" -Parameters $parameters
    }
}

function Get-PveNodesAptChangelog
{
<#
.DESCRIPTION
Get package changelogs.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Name
Package name.
.PARAMETER Node
The cluster node name.
.PARAMETER Version
Package version.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Version
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Name']) { $parameters['name'] = $Name }
        if($PSBoundParameters['Version']) { $parameters['version'] = $Version }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/apt/changelog" -Parameters $parameters
    }
}

function Get-PveNodesAptRepositories
{
<#
.DESCRIPTION
Get APT repository information.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/apt/repositories"
    }
}

function New-PveNodesAptRepositories
{
<#
.DESCRIPTION
Change the properties of a repository. Currently only allows enabling/disabling.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Digest to detect modifications.
.PARAMETER Enabled
Whether the repository should be enabled or not.
.PARAMETER Index
Index within the file (starting from 0).
.PARAMETER Node
The cluster node name.
.PARAMETER Path
Path to the containing file.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enabled,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Index,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Path
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Enabled']) { $parameters['enabled'] = $Enabled }
        if($PSBoundParameters['Index']) { $parameters['index'] = $Index }
        if($PSBoundParameters['Path']) { $parameters['path'] = $Path }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/apt/repositories" -Parameters $parameters
    }
}

function Set-PveNodesAptRepositories
{
<#
.DESCRIPTION
Add a standard repository to the configuration
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Digest to detect modifications.
.PARAMETER Handle
Handle that identifies a repository.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Handle,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Handle']) { $parameters['handle'] = $Handle }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/apt/repositories" -Parameters $parameters
    }
}

function Get-PveNodesAptVersions
{
<#
.DESCRIPTION
Get package information for important Proxmox packages.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/apt/versions"
    }
}

function Get-PveNodesFirewall
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/firewall"
    }
}

function Get-PveNodesFirewallRules
{
<#
.DESCRIPTION
List rules.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/firewall/rules"
    }
}

function New-PveNodesFirewallRules
{
<#
.DESCRIPTION
Create new rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('in','out','group')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Pos']) { $parameters['pos'] = $Pos }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/firewall/rules" -Parameters $parameters
    }
}

function Remove-PveNodesFirewallRules
{
<#
.DESCRIPTION
Delete rule.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/firewall/rules/$Pos" -Parameters $parameters
    }
}

function Get-PveNodesFirewallRulesIdx
{
<#
.DESCRIPTION
Get single rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/firewall/rules/$Pos"
    }
}

function Set-PveNodesFirewallRules
{
<#
.DESCRIPTION
Modify rule data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Action
Rule action ('ACCEPT', 'DROP', 'REJECT') or security group name.
.PARAMETER Comment
Descriptive comment.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Dest
Restrict packet destination address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Dport
Restrict TCP/UDP destination port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Enable
Flag to enable/disable a rule.
.PARAMETER IcmpType
Specify icmp-type. Only valid if proto equals 'icmp' or 'icmpv6'/'ipv6-icmp'.
.PARAMETER Iface
Network interface name. You have to use network configuration key names for VMs and containers ('net\d+'). Host related rules can use arbitrary strings.
.PARAMETER Log
Log level for firewall rule. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Macro
Use predefined standard macro.
.PARAMETER Moveto
Move rule to new position <moveto>. Other arguments are ignored.
.PARAMETER Node
The cluster node name.
.PARAMETER Pos
Update rule at position <pos>.
.PARAMETER Proto
IP protocol. You can use protocol names ('tcp'/'udp') or simple numbers, as defined in '/etc/protocols'.
.PARAMETER Source
Restrict packet source address. This can refer to a single IP address, an IP set ('+ipsetname') or an IP alias definition. You can also specify an address range like '20.34.101.207-201.3.9.99', or a list of IP addresses and networks (entries are separated by comma). Please do not mix IPv4 and IPv6 addresses inside such lists.
.PARAMETER Sport
Restrict TCP/UDP source port. You can use service names or simple numbers (0-65535), as defined in '/etc/services'. Port ranges can be specified with '\d+':'\d+', for example '80':'85', and you can use comma separated list to match several ports or ranges.
.PARAMETER Type
Rule type. Enum: in,out,group
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Action,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IcmpType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iface,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$Log,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Macro,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Moveto,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Pos,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Sport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('in','out','group')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Action']) { $parameters['action'] = $Action }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Dest']) { $parameters['dest'] = $Dest }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Dport']) { $parameters['dport'] = $Dport }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['IcmpType']) { $parameters['icmp-type'] = $IcmpType }
        if($PSBoundParameters['Iface']) { $parameters['iface'] = $Iface }
        if($PSBoundParameters['Log']) { $parameters['log'] = $Log }
        if($PSBoundParameters['Macro']) { $parameters['macro'] = $Macro }
        if($PSBoundParameters['Moveto']) { $parameters['moveto'] = $Moveto }
        if($PSBoundParameters['Proto']) { $parameters['proto'] = $Proto }
        if($PSBoundParameters['Source']) { $parameters['source'] = $Source }
        if($PSBoundParameters['Sport']) { $parameters['sport'] = $Sport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/firewall/rules/$Pos" -Parameters $parameters
    }
}

function Get-PveNodesFirewallOptions
{
<#
.DESCRIPTION
Get host firewall options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/firewall/options"
    }
}

function Set-PveNodesFirewallOptions
{
<#
.DESCRIPTION
Set Firewall options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Enable
Enable host firewall rules.
.PARAMETER LogLevelIn
Log level for incoming traffic. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER LogLevelOut
Log level for outgoing traffic. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER LogNfConntrack
Enable logging of conntrack information.
.PARAMETER Ndp
Enable NDP (Neighbor Discovery Protocol).
.PARAMETER NfConntrackAllowInvalid
Allow invalid packets on connection tracking.
.PARAMETER NfConntrackHelpers
Enable conntrack helpers for specific protocols. Supported protocols':' amanda, ftp, irc, netbios-ns, pptp, sane, sip, snmp, tftp
.PARAMETER NfConntrackMax
Maximum number of tracked connections.
.PARAMETER NfConntrackTcpTimeoutEstablished
Conntrack established timeout.
.PARAMETER NfConntrackTcpTimeoutSynRecv
Conntrack syn recv timeout.
.PARAMETER Node
The cluster node name.
.PARAMETER Nosmurfs
Enable SMURFS filter.
.PARAMETER ProtectionSynflood
Enable synflood protection
.PARAMETER ProtectionSynfloodBurst
Synflood protection rate burst by ip src.
.PARAMETER ProtectionSynfloodRate
Synflood protection rate syn/sec by ip src.
.PARAMETER SmurfLogLevel
Log level for SMURFS filter. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER TcpFlagsLogLevel
Log level for illegal tcp flags filter. Enum: emerg,alert,crit,err,warning,notice,info,debug,nolog
.PARAMETER Tcpflags
Filter illegal combinations of TCP flags.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$LogLevelIn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$LogLevelOut,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$LogNfConntrack,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Ndp,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$NfConntrackAllowInvalid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$NfConntrackHelpers,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$NfConntrackMax,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$NfConntrackTcpTimeoutEstablished,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$NfConntrackTcpTimeoutSynRecv,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nosmurfs,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$ProtectionSynflood,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$ProtectionSynfloodBurst,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$ProtectionSynfloodRate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$SmurfLogLevel,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('emerg','alert','crit','err','warning','notice','info','debug','nolog')]
        [string]$TcpFlagsLogLevel,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Tcpflags
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['LogLevelIn']) { $parameters['log_level_in'] = $LogLevelIn }
        if($PSBoundParameters['LogLevelOut']) { $parameters['log_level_out'] = $LogLevelOut }
        if($PSBoundParameters['LogNfConntrack']) { $parameters['log_nf_conntrack'] = $LogNfConntrack }
        if($PSBoundParameters['Ndp']) { $parameters['ndp'] = $Ndp }
        if($PSBoundParameters['NfConntrackAllowInvalid']) { $parameters['nf_conntrack_allow_invalid'] = $NfConntrackAllowInvalid }
        if($PSBoundParameters['NfConntrackHelpers']) { $parameters['nf_conntrack_helpers'] = $NfConntrackHelpers }
        if($PSBoundParameters['NfConntrackMax']) { $parameters['nf_conntrack_max'] = $NfConntrackMax }
        if($PSBoundParameters['NfConntrackTcpTimeoutEstablished']) { $parameters['nf_conntrack_tcp_timeout_established'] = $NfConntrackTcpTimeoutEstablished }
        if($PSBoundParameters['NfConntrackTcpTimeoutSynRecv']) { $parameters['nf_conntrack_tcp_timeout_syn_recv'] = $NfConntrackTcpTimeoutSynRecv }
        if($PSBoundParameters['Nosmurfs']) { $parameters['nosmurfs'] = $Nosmurfs }
        if($PSBoundParameters['ProtectionSynflood']) { $parameters['protection_synflood'] = $ProtectionSynflood }
        if($PSBoundParameters['ProtectionSynfloodBurst']) { $parameters['protection_synflood_burst'] = $ProtectionSynfloodBurst }
        if($PSBoundParameters['ProtectionSynfloodRate']) { $parameters['protection_synflood_rate'] = $ProtectionSynfloodRate }
        if($PSBoundParameters['SmurfLogLevel']) { $parameters['smurf_log_level'] = $SmurfLogLevel }
        if($PSBoundParameters['TcpFlagsLogLevel']) { $parameters['tcp_flags_log_level'] = $TcpFlagsLogLevel }
        if($PSBoundParameters['Tcpflags']) { $parameters['tcpflags'] = $Tcpflags }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/firewall/options" -Parameters $parameters
    }
}

function Get-PveNodesFirewallLog
{
<#
.DESCRIPTION
Read firewall log
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Limit
--
.PARAMETER Node
The cluster node name.
.PARAMETER Since
Display log since this UNIX epoch.
.PARAMETER Start
--
.PARAMETER Until
Display log until this UNIX epoch.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Limit,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Since,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Start,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Until
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Limit']) { $parameters['limit'] = $Limit }
        if($PSBoundParameters['Since']) { $parameters['since'] = $Since }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }
        if($PSBoundParameters['Until']) { $parameters['until'] = $Until }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/firewall/log" -Parameters $parameters
    }
}

function Get-PveNodesReplication
{
<#
.DESCRIPTION
List status of all replication jobs on this node.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Guest
Only list replication jobs for this guest.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Guest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Guest']) { $parameters['guest'] = $Guest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/replication" -Parameters $parameters
    }
}

function Get-PveNodesReplicationIdx
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
Replication Job ID. The ID is composed of a Guest ID and a job number, separated by a hyphen, i.e. '<GUEST>-<JOBNUM>'.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/replication/$Id"
    }
}

function Get-PveNodesReplicationStatus
{
<#
.DESCRIPTION
Get replication job status.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
Replication Job ID. The ID is composed of a Guest ID and a job number, separated by a hyphen, i.e. '<GUEST>-<JOBNUM>'.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/replication/$Id/status"
    }
}

function Get-PveNodesReplicationLog
{
<#
.DESCRIPTION
Read replication job log.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
Replication Job ID. The ID is composed of a Guest ID and a job number, separated by a hyphen, i.e. '<GUEST>-<JOBNUM>'.
.PARAMETER Limit
--
.PARAMETER Node
The cluster node name.
.PARAMETER Start
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Limit,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Start
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Limit']) { $parameters['limit'] = $Limit }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/replication/$Id/log" -Parameters $parameters
    }
}

function New-PveNodesReplicationScheduleNow
{
<#
.DESCRIPTION
Schedule replication job to start as soon as possible.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
Replication Job ID. The ID is composed of a Guest ID and a job number, separated by a hyphen, i.e. '<GUEST>-<JOBNUM>'.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/replication/$Id/schedule_now"
    }
}

function Get-PveNodesCertificates
{
<#
.DESCRIPTION
Node index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/certificates"
    }
}

function Get-PveNodesCertificatesAcme
{
<#
.DESCRIPTION
ACME index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/certificates/acme"
    }
}

function Remove-PveNodesCertificatesAcmeCertificate
{
<#
.DESCRIPTION
Revoke existing certificate from CA.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/certificates/acme/certificate"
    }
}

function New-PveNodesCertificatesAcmeCertificate
{
<#
.DESCRIPTION
Order a new certificate from ACME-compatible CA.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
Overwrite existing custom certificate.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/certificates/acme/certificate" -Parameters $parameters
    }
}

function Set-PveNodesCertificatesAcmeCertificate
{
<#
.DESCRIPTION
Renew existing certificate from CA.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
Force renewal even if expiry is more than 30 days away.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/certificates/acme/certificate" -Parameters $parameters
    }
}

function Get-PveNodesCertificatesInfo
{
<#
.DESCRIPTION
Get information about node's certificates.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/certificates/info"
    }
}

function Remove-PveNodesCertificatesCustom
{
<#
.DESCRIPTION
DELETE custom certificate chain and key.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Restart
Restart pveproxy.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Restart
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Restart']) { $parameters['restart'] = $Restart }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/nodes/$Node/certificates/custom" -Parameters $parameters
    }
}

function New-PveNodesCertificatesCustom
{
<#
.DESCRIPTION
Upload or update custom certificate chain and key.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Certificates
PEM encoded certificate (chain).
.PARAMETER Force
Overwrite existing custom or ACME certificate files.
.PARAMETER Key
PEM encoded private key.
.PARAMETER Node
The cluster node name.
.PARAMETER Restart
Restart pveproxy.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Certificates,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Key,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Restart
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Certificates']) { $parameters['certificates'] = $Certificates }
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Key']) { $parameters['key'] = $Key }
        if($PSBoundParameters['Restart']) { $parameters['restart'] = $Restart }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/certificates/custom" -Parameters $parameters
    }
}

function Get-PveNodesConfig
{
<#
.DESCRIPTION
Get node configuration options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Property
Return only a specific property from the node configuration. Enum: acme,acmedomain0,acmedomain1,acmedomain2,acmedomain3,acmedomain4,acmedomain5,description,startall-onboot-delay,wakeonlan
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('acme','acmedomain0','acmedomain1','acmedomain2','acmedomain3','acmedomain4','acmedomain5','description','startall-onboot-delay','wakeonlan')]
        [string]$Property
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Property']) { $parameters['property'] = $Property }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/config" -Parameters $parameters
    }
}

function Set-PveNodesConfig
{
<#
.DESCRIPTION
Set node configuration options.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Acme
Node specific ACME settings.
.PARAMETER AcmedomainN
ACME domain and validation plugin
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Description
Description for the Node. Shown in the web-interface node notes panel. This is saved as comment inside the configuration file.
.PARAMETER Digest
Prevent changes if current configuration file has different SHA1 digest. This can be used to prevent concurrent modifications.
.PARAMETER Node
The cluster node name.
.PARAMETER StartallOnbootDelay
Initial delay in seconds, before starting all the Virtual Guests with on-boot enabled.
.PARAMETER Wakeonlan
MAC address for wake on LAN
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Acme,

        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable]$AcmedomainN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$StartallOnbootDelay,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Wakeonlan
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Acme']) { $parameters['acme'] = $Acme }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['StartallOnbootDelay']) { $parameters['startall-onboot-delay'] = $StartallOnbootDelay }
        if($PSBoundParameters['Wakeonlan']) { $parameters['wakeonlan'] = $Wakeonlan }

        if($PSBoundParameters['AcmedomainN']) { $AcmedomainN.keys | ForEach-Object { $parameters['acmedomain' + $_] = $AcmedomainN[$_] } }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/config" -Parameters $parameters
    }
}

function Get-PveNodesSdn
{
<#
.DESCRIPTION
SDN index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/sdn"
    }
}

function Get-PveNodesSdnZones
{
<#
.DESCRIPTION
Get status for all zones.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/sdn/zones"
    }
}

function Get-PveNodesSdnZonesIdx
{
<#
.DESCRIPTION
--
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Zone
The SDN zone object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/sdn/zones/$Zone"
    }
}

function Get-PveNodesSdnZonesContent
{
<#
.DESCRIPTION
List zone content.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Zone
The SDN zone object identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Zone
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/sdn/zones/$Zone/content"
    }
}

function Get-PveNodesVersion
{
<#
.DESCRIPTION
API version details
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/version"
    }
}

function Get-PveNodesStatus
{
<#
.DESCRIPTION
Read node status
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/status"
    }
}

function New-PveNodesStatus
{
<#
.DESCRIPTION
Reboot or shutdown a node.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Command
Specify the command. Enum: reboot,shutdown
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('reboot','shutdown')]
        [string]$Command,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Command']) { $parameters['command'] = $Command }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/status" -Parameters $parameters
    }
}

function Get-PveNodesNetstat
{
<#
.DESCRIPTION
Read tap/vm network device interface counters
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/netstat"
    }
}

function New-PveNodesExecute
{
<#
.DESCRIPTION
Execute multiple commands in order, root only.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Commands
JSON encoded array of commands.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Commands,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Commands']) { $parameters['commands'] = $Commands }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/execute" -Parameters $parameters
    }
}

function New-PveNodesWakeonlan
{
<#
.DESCRIPTION
Try to wake a node via 'wake on LAN' network packet.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
target node for wake on LAN packet
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/wakeonlan"
    }
}

function Get-PveNodesRrd
{
<#
.DESCRIPTION
Read node RRD statistics (returns PNG)
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cf
The RRD consolidation function Enum: AVERAGE,MAX
.PARAMETER Ds
The list of datasources you want to display.
.PARAMETER Node
The cluster node name.
.PARAMETER Timeframe
Specify the time frame you are interested in. Enum: hour,day,week,month,year
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('AVERAGE','MAX')]
        [string]$Cf,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Ds,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('hour','day','week','month','year')]
        [string]$Timeframe
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cf']) { $parameters['cf'] = $Cf }
        if($PSBoundParameters['Ds']) { $parameters['ds'] = $Ds }
        if($PSBoundParameters['Timeframe']) { $parameters['timeframe'] = $Timeframe }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/rrd" -Parameters $parameters
    }
}

function Get-PveNodesRrddata
{
<#
.DESCRIPTION
Read node RRD statistics
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cf
The RRD consolidation function Enum: AVERAGE,MAX
.PARAMETER Node
The cluster node name.
.PARAMETER Timeframe
Specify the time frame you are interested in. Enum: hour,day,week,month,year
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('AVERAGE','MAX')]
        [string]$Cf,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('hour','day','week','month','year')]
        [string]$Timeframe
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cf']) { $parameters['cf'] = $Cf }
        if($PSBoundParameters['Timeframe']) { $parameters['timeframe'] = $Timeframe }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/rrddata" -Parameters $parameters
    }
}

function Get-PveNodesSyslog
{
<#
.DESCRIPTION
Read system log
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Limit
--
.PARAMETER Node
The cluster node name.
.PARAMETER Service
Service ID
.PARAMETER Since
Display all log since this date-time string.
.PARAMETER Start
--
.PARAMETER Until
Display all log until this date-time string.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Limit,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Service,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Since,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Start,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Until
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Limit']) { $parameters['limit'] = $Limit }
        if($PSBoundParameters['Service']) { $parameters['service'] = $Service }
        if($PSBoundParameters['Since']) { $parameters['since'] = $Since }
        if($PSBoundParameters['Start']) { $parameters['start'] = $Start }
        if($PSBoundParameters['Until']) { $parameters['until'] = $Until }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/syslog" -Parameters $parameters
    }
}

function Get-PveNodesJournal
{
<#
.DESCRIPTION
Read Journal
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Endcursor
End before the given Cursor. Conflicts with 'until'
.PARAMETER Lastentries
Limit to the last X lines. Conflicts with a range.
.PARAMETER Node
The cluster node name.
.PARAMETER Since
Display all log since this UNIX epoch. Conflicts with 'startcursor'.
.PARAMETER Startcursor
Start after the given Cursor. Conflicts with 'since'
.PARAMETER Until
Display all log until this UNIX epoch. Conflicts with 'endcursor'.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Endcursor,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Lastentries,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Since,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Startcursor,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Until
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Endcursor']) { $parameters['endcursor'] = $Endcursor }
        if($PSBoundParameters['Lastentries']) { $parameters['lastentries'] = $Lastentries }
        if($PSBoundParameters['Since']) { $parameters['since'] = $Since }
        if($PSBoundParameters['Startcursor']) { $parameters['startcursor'] = $Startcursor }
        if($PSBoundParameters['Until']) { $parameters['until'] = $Until }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/journal" -Parameters $parameters
    }
}

function New-PveNodesVncshell
{
<#
.DESCRIPTION
Creates a VNC Shell proxy.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cmd
Run specific command or default to login (requires 'root@pam') Enum: ceph_install,login,upgrade
.PARAMETER CmdOpts
Add parameters to a command. Encoded as null terminated strings.
.PARAMETER Height
sets the height of the console in pixels.
.PARAMETER Node
The cluster node name.
.PARAMETER Websocket
use websocket instead of standard vnc.
.PARAMETER Width
sets the width of the console in pixels.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ceph_install','login','upgrade')]
        [string]$Cmd,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$CmdOpts,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Height,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Websocket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Width
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cmd']) { $parameters['cmd'] = $Cmd }
        if($PSBoundParameters['CmdOpts']) { $parameters['cmd-opts'] = $CmdOpts }
        if($PSBoundParameters['Height']) { $parameters['height'] = $Height }
        if($PSBoundParameters['Websocket']) { $parameters['websocket'] = $Websocket }
        if($PSBoundParameters['Width']) { $parameters['width'] = $Width }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/vncshell" -Parameters $parameters
    }
}

function New-PveNodesTermproxy
{
<#
.DESCRIPTION
Creates a VNC Shell proxy.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cmd
Run specific command or default to login (requires 'root@pam') Enum: ceph_install,login,upgrade
.PARAMETER CmdOpts
Add parameters to a command. Encoded as null terminated strings.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ceph_install','login','upgrade')]
        [string]$Cmd,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$CmdOpts,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cmd']) { $parameters['cmd'] = $Cmd }
        if($PSBoundParameters['CmdOpts']) { $parameters['cmd-opts'] = $CmdOpts }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/termproxy" -Parameters $parameters
    }
}

function Get-PveNodesVncwebsocket
{
<#
.DESCRIPTION
Opens a websocket for VNC traffic.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Port
Port number returned by previous vncproxy call.
.PARAMETER Vncticket
Ticket from previous call to vncproxy.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Vncticket
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Vncticket']) { $parameters['vncticket'] = $Vncticket }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/vncwebsocket" -Parameters $parameters
    }
}

function New-PveNodesSpiceshell
{
<#
.DESCRIPTION
Creates a SPICE shell.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Cmd
Run specific command or default to login (requires 'root@pam') Enum: ceph_install,login,upgrade
.PARAMETER CmdOpts
Add parameters to a command. Encoded as null terminated strings.
.PARAMETER Node
The cluster node name.
.PARAMETER Proxy
SPICE proxy server. This can be used by the client to specify the proxy server. All nodes in a cluster runs 'spiceproxy', so it is up to the client to choose one. By default, we return the node where the VM is currently running. As reasonable setting is to use same node you use to connect to the API (This is window.location.hostname for the JS GUI).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ceph_install','login','upgrade')]
        [string]$Cmd,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$CmdOpts,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Proxy
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Cmd']) { $parameters['cmd'] = $Cmd }
        if($PSBoundParameters['CmdOpts']) { $parameters['cmd-opts'] = $CmdOpts }
        if($PSBoundParameters['Proxy']) { $parameters['proxy'] = $Proxy }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/spiceshell" -Parameters $parameters
    }
}

function Get-PveNodesDns
{
<#
.DESCRIPTION
Read DNS settings.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/dns"
    }
}

function Set-PveNodesDns
{
<#
.DESCRIPTION
Write DNS settings.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Dns1
First name server IP address.
.PARAMETER Dns2
Second name server IP address.
.PARAMETER Dns3
Third name server IP address.
.PARAMETER Node
The cluster node name.
.PARAMETER Search
Search domain for host-name lookup.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dns1,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dns2,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Dns3,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Search
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Dns1']) { $parameters['dns1'] = $Dns1 }
        if($PSBoundParameters['Dns2']) { $parameters['dns2'] = $Dns2 }
        if($PSBoundParameters['Dns3']) { $parameters['dns3'] = $Dns3 }
        if($PSBoundParameters['Search']) { $parameters['search'] = $Search }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/dns" -Parameters $parameters
    }
}

function Get-PveNodesTime
{
<#
.DESCRIPTION
Read server time and time zone settings.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/time"
    }
}

function Set-PveNodesTime
{
<#
.DESCRIPTION
Set time zone.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Timezone
Time zone. The file '/usr/share/zoneinfo/zone.tab' contains the list of valid names.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Timezone
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Timezone']) { $parameters['timezone'] = $Timezone }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/nodes/$Node/time" -Parameters $parameters
    }
}

function Get-PveNodesAplinfo
{
<#
.DESCRIPTION
Get list of appliances.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/aplinfo"
    }
}

function New-PveNodesAplinfo
{
<#
.DESCRIPTION
Download appliance templates.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Storage
The storage where the template will be stored
.PARAMETER Template
The template which will downloaded
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Template
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Template']) { $parameters['template'] = $Template }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/aplinfo" -Parameters $parameters
    }
}

function Get-PveNodesQueryUrlMetadata
{
<#
.DESCRIPTION
Query metadata of an URL':' file size, file name and mime type.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Url
The URL to query the metadata from.
.PARAMETER VerifyCertificates
If false, no SSL/TLS certificates will be verified.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Url,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$VerifyCertificates
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Url']) { $parameters['url'] = $Url }
        if($PSBoundParameters['VerifyCertificates']) { $parameters['verify-certificates'] = $VerifyCertificates }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/query-url-metadata" -Parameters $parameters
    }
}

function Get-PveNodesReport
{
<#
.DESCRIPTION
Gather various systems information about a node
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/report"
    }
}

function New-PveNodesStartall
{
<#
.DESCRIPTION
Start all VMs and containers located on this node (by default only those with onboot=1).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Force
Issue start command even if virtual guest have 'onboot' not set or set to off.
.PARAMETER Node
The cluster node name.
.PARAMETER Vms
Only consider guests from this comma separated list of VMIDs.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Force,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vms
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Force']) { $parameters['force'] = $Force }
        if($PSBoundParameters['Vms']) { $parameters['vms'] = $Vms }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/startall" -Parameters $parameters
    }
}

function New-PveNodesStopall
{
<#
.DESCRIPTION
Stop all VMs and Containers.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER ForceStop
Force a hard-stop after the timeout.
.PARAMETER Node
The cluster node name.
.PARAMETER Timeout
Timeout for each guest shutdown task. Depending on `force-stop`, the shutdown gets then simply aborted or a hard-stop is forced.
.PARAMETER Vms
Only consider Guests with these IDs.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$ForceStop,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Timeout,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vms
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['ForceStop']) { $parameters['force-stop'] = $ForceStop }
        if($PSBoundParameters['Timeout']) { $parameters['timeout'] = $Timeout }
        if($PSBoundParameters['Vms']) { $parameters['vms'] = $Vms }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/stopall" -Parameters $parameters
    }
}

function New-PveNodesSuspendall
{
<#
.DESCRIPTION
Suspend all VMs.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.PARAMETER Vms
Only consider Guests with these IDs.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vms
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Vms']) { $parameters['vms'] = $Vms }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/suspendall" -Parameters $parameters
    }
}

function New-PveNodesMigrateall
{
<#
.DESCRIPTION
Migrate all VMs and Containers.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Maxworkers
Maximal number of parallel migration job. If not set, uses'max_workers' from datacenter.cfg. One of both must be set!
.PARAMETER Node
The cluster node name.
.PARAMETER Target
Target node.
.PARAMETER Vms
Only consider Guests with these IDs.
.PARAMETER WithLocalDisks
Enable live storage migration for local disk
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Maxworkers,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Target,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vms,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$WithLocalDisks
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Maxworkers']) { $parameters['maxworkers'] = $Maxworkers }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }
        if($PSBoundParameters['Vms']) { $parameters['vms'] = $Vms }
        if($PSBoundParameters['WithLocalDisks']) { $parameters['with-local-disks'] = $WithLocalDisks }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/migrateall" -Parameters $parameters
    }
}

function Get-PveNodesHosts
{
<#
.DESCRIPTION
Get the content of /etc/hosts.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/nodes/$Node/hosts"
    }
}

function New-PveNodesHosts
{
<#
.DESCRIPTION
Write /etc/hosts.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Data
The target content of /etc/hosts.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Node
The cluster node name.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Data,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Node
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Data']) { $parameters['data'] = $Data }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/nodes/$Node/hosts" -Parameters $parameters
    }
}

function Get-PveStorage
{
<#
.DESCRIPTION
Storage index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Type
Only list storage of specific type Enum: btrfs,cephfs,cifs,dir,glusterfs,iscsi,iscsidirect,lvm,lvmthin,nfs,pbs,rbd,zfs,zfspool
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('btrfs','cephfs','cifs','dir','glusterfs','iscsi','iscsidirect','lvm','lvmthin','nfs','pbs','rbd','zfs','zfspool')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/storage" -Parameters $parameters
    }
}

function New-PveStorage
{
<#
.DESCRIPTION
Create a new storage.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Authsupported
Authsupported.
.PARAMETER Base
Base volume. This volume is automatically activated.
.PARAMETER Blocksize
block size
.PARAMETER Bwlimit
Set I/O bandwidth limit for various operations (in KiB/s).
.PARAMETER ComstarHg
host group for comstar views
.PARAMETER ComstarTg
target group for comstar views
.PARAMETER Content
Allowed content types.NOTE':' the value 'rootdir' is used for Containers, and value 'images' for VMs.
.PARAMETER ContentDirs
Overrides for default content type directories.
.PARAMETER CreateBasePath
Create the base directory if it doesn't exist.
.PARAMETER CreateSubdirs
Populate the directory with the default structure.
.PARAMETER DataPool
Data Pool (for erasure coding only)
.PARAMETER Datastore
Proxmox Backup Server datastore name.
.PARAMETER Disable
Flag to disable the storage.
.PARAMETER Domain
CIFS domain.
.PARAMETER EncryptionKey
Encryption key. Use 'autogen' to generate one automatically without passphrase.
.PARAMETER Export
NFS export path.
.PARAMETER Fingerprint
Certificate SHA 256 fingerprint.
.PARAMETER Format
Default image format.
.PARAMETER FsName
The Ceph filesystem name.
.PARAMETER Fuse
Mount CephFS through FUSE.
.PARAMETER IsMountpoint
Assume the given path is an externally managed mountpoint and consider the storage offline if it is not mounted. Using a boolean (yes/no) value serves as a shortcut to using the target path in this field.
.PARAMETER Iscsiprovider
iscsi provider
.PARAMETER Keyring
Client keyring contents (for external clusters).
.PARAMETER Krbd
Always access rbd through krbd kernel module.
.PARAMETER LioTpg
target portal group for Linux LIO targets
.PARAMETER MasterPubkey
Base64-encoded, PEM-formatted public RSA key. Used to encrypt a copy of the encryption-key which will be added to each encrypted backup.
.PARAMETER MaxProtectedBackups
Maximal number of protected backups per guest. Use '-1' for unlimited.
.PARAMETER Maxfiles
Deprecated':' use 'prune-backups' instead. Maximal number of backup files per VM. Use '0' for unlimited.
.PARAMETER Mkdir
Create the directory if it doesn't exist and populate it with default sub-dirs. NOTE':' Deprecated, use the 'create-base-path' and 'create-subdirs' options instead.
.PARAMETER Monhost
IP addresses of monitors (for external clusters).
.PARAMETER Mountpoint
mount point
.PARAMETER Namespace
Namespace.
.PARAMETER Nocow
Set the NOCOW flag on files. Disables data checksumming and causes data errors to be unrecoverable from while allowing direct I/O. Only use this if data does not need to be any more safe than on a single ext4 formatted disk with no underlying raid system.
.PARAMETER Nodes
List of cluster node names.
.PARAMETER Nowritecache
disable write caching on the target
.PARAMETER Options
NFS/CIFS mount options (see 'man nfs' or 'man mount.cifs')
.PARAMETER Password
Password for accessing the share/datastore.
.PARAMETER Path
File system path.
.PARAMETER Pool
Pool.
.PARAMETER Port
For non default port.
.PARAMETER Portal
iSCSI portal (IP or DNS name with optional port).
.PARAMETER Preallocation
Preallocation mode for raw and qcow2 images. Using 'metadata' on raw images results in preallocation=off. Enum: off,metadata,falloc,full
.PARAMETER PruneBackups
The retention options with shorter intervals are processed first with --keep-last being the very first one. Each option covers a specific period of time. We say that backups within this period are covered by this option. The next option does not take care of already covered backups and only considers older backups.
.PARAMETER Saferemove
Zero-out data when removing LVs.
.PARAMETER SaferemoveThroughput
Wipe throughput (cstream -t parameter value).
.PARAMETER Server
Server IP or DNS name.
.PARAMETER Server2
Backup volfile server IP or DNS name.
.PARAMETER Share
CIFS share.
.PARAMETER Shared
Mark storage as shared.
.PARAMETER Smbversion
SMB protocol version. 'default' if not set, negotiates the highest SMB2+ version supported by both the client and server. Enum: default,2.0,2.1,3,3.0,3.11
.PARAMETER Sparse
use sparse volumes
.PARAMETER Storage
The storage identifier.
.PARAMETER Subdir
Subdir to mount.
.PARAMETER TaggedOnly
Only use logical volumes tagged with 'pve-vm-ID'.
.PARAMETER Target
iSCSI target.
.PARAMETER Thinpool
LVM thin pool LV name.
.PARAMETER Transport
Gluster transport':' tcp or rdma Enum: tcp,rdma,unix
.PARAMETER Type
Storage type. Enum: btrfs,cephfs,cifs,dir,glusterfs,iscsi,iscsidirect,lvm,lvmthin,nfs,pbs,rbd,zfs,zfspool
.PARAMETER Username
RBD Id.
.PARAMETER Vgname
Volume group name.
.PARAMETER Volume
Glusterfs Volume.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Authsupported,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Base,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Blocksize,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ComstarHg,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ComstarTg,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Content,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ContentDirs,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CreateBasePath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CreateSubdirs,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$DataPool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Datastore,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Domain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$EncryptionKey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Export,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Fingerprint,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Format,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$FsName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Fuse,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IsMountpoint,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Iscsiprovider,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Keyring,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Krbd,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$LioTpg,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$MasterPubkey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MaxProtectedBackups,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Maxfiles,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Mkdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Monhost,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mountpoint,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Namespace,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nocow,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nodes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nowritecache,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Options,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Path,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Pool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Portal,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('off','metadata','falloc','full')]
        [string]$Preallocation,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PruneBackups,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Saferemove,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SaferemoveThroughput,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server2,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Share,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Shared,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('default','2.0','2.1','3','3.0','3.11')]
        [string]$Smbversion,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Sparse,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Subdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$TaggedOnly,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Target,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Thinpool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('tcp','rdma','unix')]
        [string]$Transport,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('btrfs','cephfs','cifs','dir','glusterfs','iscsi','iscsidirect','lvm','lvmthin','nfs','pbs','rbd','zfs','zfspool')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Username,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vgname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Volume
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Authsupported']) { $parameters['authsupported'] = $Authsupported }
        if($PSBoundParameters['Base']) { $parameters['base'] = $Base }
        if($PSBoundParameters['Blocksize']) { $parameters['blocksize'] = $Blocksize }
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['ComstarHg']) { $parameters['comstar_hg'] = $ComstarHg }
        if($PSBoundParameters['ComstarTg']) { $parameters['comstar_tg'] = $ComstarTg }
        if($PSBoundParameters['Content']) { $parameters['content'] = $Content }
        if($PSBoundParameters['ContentDirs']) { $parameters['content-dirs'] = $ContentDirs }
        if($PSBoundParameters['CreateBasePath']) { $parameters['create-base-path'] = $CreateBasePath }
        if($PSBoundParameters['CreateSubdirs']) { $parameters['create-subdirs'] = $CreateSubdirs }
        if($PSBoundParameters['DataPool']) { $parameters['data-pool'] = $DataPool }
        if($PSBoundParameters['Datastore']) { $parameters['datastore'] = $Datastore }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Domain']) { $parameters['domain'] = $Domain }
        if($PSBoundParameters['EncryptionKey']) { $parameters['encryption-key'] = $EncryptionKey }
        if($PSBoundParameters['Export']) { $parameters['export'] = $Export }
        if($PSBoundParameters['Fingerprint']) { $parameters['fingerprint'] = $Fingerprint }
        if($PSBoundParameters['Format']) { $parameters['format'] = $Format }
        if($PSBoundParameters['FsName']) { $parameters['fs-name'] = $FsName }
        if($PSBoundParameters['Fuse']) { $parameters['fuse'] = $Fuse }
        if($PSBoundParameters['IsMountpoint']) { $parameters['is_mountpoint'] = $IsMountpoint }
        if($PSBoundParameters['Iscsiprovider']) { $parameters['iscsiprovider'] = $Iscsiprovider }
        if($PSBoundParameters['Keyring']) { $parameters['keyring'] = $Keyring }
        if($PSBoundParameters['Krbd']) { $parameters['krbd'] = $Krbd }
        if($PSBoundParameters['LioTpg']) { $parameters['lio_tpg'] = $LioTpg }
        if($PSBoundParameters['MasterPubkey']) { $parameters['master-pubkey'] = $MasterPubkey }
        if($PSBoundParameters['MaxProtectedBackups']) { $parameters['max-protected-backups'] = $MaxProtectedBackups }
        if($PSBoundParameters['Maxfiles']) { $parameters['maxfiles'] = $Maxfiles }
        if($PSBoundParameters['Mkdir']) { $parameters['mkdir'] = $Mkdir }
        if($PSBoundParameters['Monhost']) { $parameters['monhost'] = $Monhost }
        if($PSBoundParameters['Mountpoint']) { $parameters['mountpoint'] = $Mountpoint }
        if($PSBoundParameters['Namespace']) { $parameters['namespace'] = $Namespace }
        if($PSBoundParameters['Nocow']) { $parameters['nocow'] = $Nocow }
        if($PSBoundParameters['Nodes']) { $parameters['nodes'] = $Nodes }
        if($PSBoundParameters['Nowritecache']) { $parameters['nowritecache'] = $Nowritecache }
        if($PSBoundParameters['Options']) { $parameters['options'] = $Options }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Path']) { $parameters['path'] = $Path }
        if($PSBoundParameters['Pool']) { $parameters['pool'] = $Pool }
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Portal']) { $parameters['portal'] = $Portal }
        if($PSBoundParameters['Preallocation']) { $parameters['preallocation'] = $Preallocation }
        if($PSBoundParameters['PruneBackups']) { $parameters['prune-backups'] = $PruneBackups }
        if($PSBoundParameters['Saferemove']) { $parameters['saferemove'] = $Saferemove }
        if($PSBoundParameters['SaferemoveThroughput']) { $parameters['saferemove_throughput'] = $SaferemoveThroughput }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Server2']) { $parameters['server2'] = $Server2 }
        if($PSBoundParameters['Share']) { $parameters['share'] = $Share }
        if($PSBoundParameters['Shared']) { $parameters['shared'] = $Shared }
        if($PSBoundParameters['Smbversion']) { $parameters['smbversion'] = $Smbversion }
        if($PSBoundParameters['Sparse']) { $parameters['sparse'] = $Sparse }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Subdir']) { $parameters['subdir'] = $Subdir }
        if($PSBoundParameters['TaggedOnly']) { $parameters['tagged_only'] = $TaggedOnly }
        if($PSBoundParameters['Target']) { $parameters['target'] = $Target }
        if($PSBoundParameters['Thinpool']) { $parameters['thinpool'] = $Thinpool }
        if($PSBoundParameters['Transport']) { $parameters['transport'] = $Transport }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['Username']) { $parameters['username'] = $Username }
        if($PSBoundParameters['Vgname']) { $parameters['vgname'] = $Vgname }
        if($PSBoundParameters['Volume']) { $parameters['volume'] = $Volume }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/storage" -Parameters $parameters
    }
}

function Remove-PveStorage
{
<#
.DESCRIPTION
Delete storage configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Storage
The storage identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/storage/$Storage"
    }
}

function Get-PveStorageIdx
{
<#
.DESCRIPTION
Read storage configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Storage
The storage identifier.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/storage/$Storage"
    }
}

function Set-PveStorage
{
<#
.DESCRIPTION
Update storage configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Blocksize
block size
.PARAMETER Bwlimit
Set I/O bandwidth limit for various operations (in KiB/s).
.PARAMETER ComstarHg
host group for comstar views
.PARAMETER ComstarTg
target group for comstar views
.PARAMETER Content
Allowed content types.NOTE':' the value 'rootdir' is used for Containers, and value 'images' for VMs.
.PARAMETER ContentDirs
Overrides for default content type directories.
.PARAMETER CreateBasePath
Create the base directory if it doesn't exist.
.PARAMETER CreateSubdirs
Populate the directory with the default structure.
.PARAMETER DataPool
Data Pool (for erasure coding only)
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Disable
Flag to disable the storage.
.PARAMETER Domain
CIFS domain.
.PARAMETER EncryptionKey
Encryption key. Use 'autogen' to generate one automatically without passphrase.
.PARAMETER Fingerprint
Certificate SHA 256 fingerprint.
.PARAMETER Format
Default image format.
.PARAMETER FsName
The Ceph filesystem name.
.PARAMETER Fuse
Mount CephFS through FUSE.
.PARAMETER IsMountpoint
Assume the given path is an externally managed mountpoint and consider the storage offline if it is not mounted. Using a boolean (yes/no) value serves as a shortcut to using the target path in this field.
.PARAMETER Keyring
Client keyring contents (for external clusters).
.PARAMETER Krbd
Always access rbd through krbd kernel module.
.PARAMETER LioTpg
target portal group for Linux LIO targets
.PARAMETER MasterPubkey
Base64-encoded, PEM-formatted public RSA key. Used to encrypt a copy of the encryption-key which will be added to each encrypted backup.
.PARAMETER MaxProtectedBackups
Maximal number of protected backups per guest. Use '-1' for unlimited.
.PARAMETER Maxfiles
Deprecated':' use 'prune-backups' instead. Maximal number of backup files per VM. Use '0' for unlimited.
.PARAMETER Mkdir
Create the directory if it doesn't exist and populate it with default sub-dirs. NOTE':' Deprecated, use the 'create-base-path' and 'create-subdirs' options instead.
.PARAMETER Monhost
IP addresses of monitors (for external clusters).
.PARAMETER Mountpoint
mount point
.PARAMETER Namespace
Namespace.
.PARAMETER Nocow
Set the NOCOW flag on files. Disables data checksumming and causes data errors to be unrecoverable from while allowing direct I/O. Only use this if data does not need to be any more safe than on a single ext4 formatted disk with no underlying raid system.
.PARAMETER Nodes
List of cluster node names.
.PARAMETER Nowritecache
disable write caching on the target
.PARAMETER Options
NFS/CIFS mount options (see 'man nfs' or 'man mount.cifs')
.PARAMETER Password
Password for accessing the share/datastore.
.PARAMETER Pool
Pool.
.PARAMETER Port
For non default port.
.PARAMETER Preallocation
Preallocation mode for raw and qcow2 images. Using 'metadata' on raw images results in preallocation=off. Enum: off,metadata,falloc,full
.PARAMETER PruneBackups
The retention options with shorter intervals are processed first with --keep-last being the very first one. Each option covers a specific period of time. We say that backups within this period are covered by this option. The next option does not take care of already covered backups and only considers older backups.
.PARAMETER Saferemove
Zero-out data when removing LVs.
.PARAMETER SaferemoveThroughput
Wipe throughput (cstream -t parameter value).
.PARAMETER Server
Server IP or DNS name.
.PARAMETER Server2
Backup volfile server IP or DNS name.
.PARAMETER Shared
Mark storage as shared.
.PARAMETER Smbversion
SMB protocol version. 'default' if not set, negotiates the highest SMB2+ version supported by both the client and server. Enum: default,2.0,2.1,3,3.0,3.11
.PARAMETER Sparse
use sparse volumes
.PARAMETER Storage
The storage identifier.
.PARAMETER Subdir
Subdir to mount.
.PARAMETER TaggedOnly
Only use logical volumes tagged with 'pve-vm-ID'.
.PARAMETER Transport
Gluster transport':' tcp or rdma Enum: tcp,rdma,unix
.PARAMETER Username
RBD Id.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Blocksize,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Bwlimit,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ComstarHg,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ComstarTg,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Content,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ContentDirs,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CreateBasePath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CreateSubdirs,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$DataPool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Disable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Domain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$EncryptionKey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Fingerprint,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Format,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$FsName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Fuse,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IsMountpoint,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Keyring,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Krbd,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$LioTpg,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$MasterPubkey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$MaxProtectedBackups,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Maxfiles,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Mkdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Monhost,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Mountpoint,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Namespace,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nocow,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Nodes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Nowritecache,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Options,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Pool,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('off','metadata','falloc','full')]
        [string]$Preallocation,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PruneBackups,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Saferemove,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SaferemoveThroughput,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server2,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Shared,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('default','2.0','2.1','3','3.0','3.11')]
        [string]$Smbversion,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Sparse,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Subdir,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$TaggedOnly,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('tcp','rdma','unix')]
        [string]$Transport,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Username
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Blocksize']) { $parameters['blocksize'] = $Blocksize }
        if($PSBoundParameters['Bwlimit']) { $parameters['bwlimit'] = $Bwlimit }
        if($PSBoundParameters['ComstarHg']) { $parameters['comstar_hg'] = $ComstarHg }
        if($PSBoundParameters['ComstarTg']) { $parameters['comstar_tg'] = $ComstarTg }
        if($PSBoundParameters['Content']) { $parameters['content'] = $Content }
        if($PSBoundParameters['ContentDirs']) { $parameters['content-dirs'] = $ContentDirs }
        if($PSBoundParameters['CreateBasePath']) { $parameters['create-base-path'] = $CreateBasePath }
        if($PSBoundParameters['CreateSubdirs']) { $parameters['create-subdirs'] = $CreateSubdirs }
        if($PSBoundParameters['DataPool']) { $parameters['data-pool'] = $DataPool }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Disable']) { $parameters['disable'] = $Disable }
        if($PSBoundParameters['Domain']) { $parameters['domain'] = $Domain }
        if($PSBoundParameters['EncryptionKey']) { $parameters['encryption-key'] = $EncryptionKey }
        if($PSBoundParameters['Fingerprint']) { $parameters['fingerprint'] = $Fingerprint }
        if($PSBoundParameters['Format']) { $parameters['format'] = $Format }
        if($PSBoundParameters['FsName']) { $parameters['fs-name'] = $FsName }
        if($PSBoundParameters['Fuse']) { $parameters['fuse'] = $Fuse }
        if($PSBoundParameters['IsMountpoint']) { $parameters['is_mountpoint'] = $IsMountpoint }
        if($PSBoundParameters['Keyring']) { $parameters['keyring'] = $Keyring }
        if($PSBoundParameters['Krbd']) { $parameters['krbd'] = $Krbd }
        if($PSBoundParameters['LioTpg']) { $parameters['lio_tpg'] = $LioTpg }
        if($PSBoundParameters['MasterPubkey']) { $parameters['master-pubkey'] = $MasterPubkey }
        if($PSBoundParameters['MaxProtectedBackups']) { $parameters['max-protected-backups'] = $MaxProtectedBackups }
        if($PSBoundParameters['Maxfiles']) { $parameters['maxfiles'] = $Maxfiles }
        if($PSBoundParameters['Mkdir']) { $parameters['mkdir'] = $Mkdir }
        if($PSBoundParameters['Monhost']) { $parameters['monhost'] = $Monhost }
        if($PSBoundParameters['Mountpoint']) { $parameters['mountpoint'] = $Mountpoint }
        if($PSBoundParameters['Namespace']) { $parameters['namespace'] = $Namespace }
        if($PSBoundParameters['Nocow']) { $parameters['nocow'] = $Nocow }
        if($PSBoundParameters['Nodes']) { $parameters['nodes'] = $Nodes }
        if($PSBoundParameters['Nowritecache']) { $parameters['nowritecache'] = $Nowritecache }
        if($PSBoundParameters['Options']) { $parameters['options'] = $Options }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Pool']) { $parameters['pool'] = $Pool }
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Preallocation']) { $parameters['preallocation'] = $Preallocation }
        if($PSBoundParameters['PruneBackups']) { $parameters['prune-backups'] = $PruneBackups }
        if($PSBoundParameters['Saferemove']) { $parameters['saferemove'] = $Saferemove }
        if($PSBoundParameters['SaferemoveThroughput']) { $parameters['saferemove_throughput'] = $SaferemoveThroughput }
        if($PSBoundParameters['Server']) { $parameters['server'] = $Server }
        if($PSBoundParameters['Server2']) { $parameters['server2'] = $Server2 }
        if($PSBoundParameters['Shared']) { $parameters['shared'] = $Shared }
        if($PSBoundParameters['Smbversion']) { $parameters['smbversion'] = $Smbversion }
        if($PSBoundParameters['Sparse']) { $parameters['sparse'] = $Sparse }
        if($PSBoundParameters['Subdir']) { $parameters['subdir'] = $Subdir }
        if($PSBoundParameters['TaggedOnly']) { $parameters['tagged_only'] = $TaggedOnly }
        if($PSBoundParameters['Transport']) { $parameters['transport'] = $Transport }
        if($PSBoundParameters['Username']) { $parameters['username'] = $Username }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/storage/$Storage" -Parameters $parameters
    }
}

function Get-PveAccess
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access"
    }
}

function Get-PveAccessUsers
{
<#
.DESCRIPTION
User index.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Enabled
Optional filter for enable property.
.PARAMETER Full
Include group and token information.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enabled,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Full
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Enabled']) { $parameters['enabled'] = $Enabled }
        if($PSBoundParameters['Full']) { $parameters['full'] = $Full }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/users" -Parameters $parameters
    }
}

function New-PveAccessUsers
{
<#
.DESCRIPTION
Create new user.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Email
--
.PARAMETER Enable
Enable the account (default). You can set this to '0' to disable the account
.PARAMETER Expire
Account expiration date (seconds since epoch). '0' means no expiration date.
.PARAMETER Firstname
--
.PARAMETER Groups
--
.PARAMETER Keys
Keys for two factor auth (yubico).
.PARAMETER Lastname
--
.PARAMETER Password
Initial password.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Email,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Expire,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Firstname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Groups,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Keys,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Lastname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Email']) { $parameters['email'] = $Email }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['Expire']) { $parameters['expire'] = $Expire }
        if($PSBoundParameters['Firstname']) { $parameters['firstname'] = $Firstname }
        if($PSBoundParameters['Groups']) { $parameters['groups'] = $Groups }
        if($PSBoundParameters['Keys']) { $parameters['keys'] = $Keys }
        if($PSBoundParameters['Lastname']) { $parameters['lastname'] = $Lastname }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Userid']) { $parameters['userid'] = $Userid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/users" -Parameters $parameters
    }
}

function Remove-PveAccessUsers
{
<#
.DESCRIPTION
Delete user.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/access/users/$Userid"
    }
}

function Get-PveAccessUsersIdx
{
<#
.DESCRIPTION
Get user configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/users/$Userid"
    }
}

function Set-PveAccessUsers
{
<#
.DESCRIPTION
Update user configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Append
--
.PARAMETER Comment
--
.PARAMETER Email
--
.PARAMETER Enable
Enable the account (default). You can set this to '0' to disable the account
.PARAMETER Expire
Account expiration date (seconds since epoch). '0' means no expiration date.
.PARAMETER Firstname
--
.PARAMETER Groups
--
.PARAMETER Keys
Keys for two factor auth (yubico).
.PARAMETER Lastname
--
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Append,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Email,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enable,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Expire,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Firstname,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Groups,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Keys,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Lastname,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Append']) { $parameters['append'] = $Append }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Email']) { $parameters['email'] = $Email }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['Expire']) { $parameters['expire'] = $Expire }
        if($PSBoundParameters['Firstname']) { $parameters['firstname'] = $Firstname }
        if($PSBoundParameters['Groups']) { $parameters['groups'] = $Groups }
        if($PSBoundParameters['Keys']) { $parameters['keys'] = $Keys }
        if($PSBoundParameters['Lastname']) { $parameters['lastname'] = $Lastname }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/access/users/$Userid" -Parameters $parameters
    }
}

function Get-PveAccessUsersTfa
{
<#
.DESCRIPTION
Get user TFA types (Personal and Realm).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Multiple
Request all entries as an array.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Multiple,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Multiple']) { $parameters['multiple'] = $Multiple }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/users/$Userid/tfa" -Parameters $parameters
    }
}

function Set-PveAccessUsersUnlockTfa
{
<#
.DESCRIPTION
Unlock a user's TFA authentication.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/access/users/$Userid/unlock-tfa"
    }
}

function Get-PveAccessUsersToken
{
<#
.DESCRIPTION
Get user API tokens.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/users/$Userid/token"
    }
}

function Remove-PveAccessUsersToken
{
<#
.DESCRIPTION
Remove API token for a specific user.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Tokenid
User-specific token identifier.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Tokenid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/access/users/$Userid/token/$Tokenid"
    }
}

function Get-PveAccessUsersTokenIdx
{
<#
.DESCRIPTION
Get specific API token information.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Tokenid
User-specific token identifier.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Tokenid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/users/$Userid/token/$Tokenid"
    }
}

function New-PveAccessUsersToken
{
<#
.DESCRIPTION
Generate a new API token for a specific user. NOTE':' returns API token value, which needs to be stored as it cannot be retrieved afterwards!
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Expire
API token expiration date (seconds since epoch). '0' means no expiration date.
.PARAMETER Privsep
Restrict API token privileges with separate ACLs (default), or give full privileges of corresponding user.
.PARAMETER Tokenid
User-specific token identifier.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Expire,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Privsep,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Tokenid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Expire']) { $parameters['expire'] = $Expire }
        if($PSBoundParameters['Privsep']) { $parameters['privsep'] = $Privsep }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/users/$Userid/token/$Tokenid" -Parameters $parameters
    }
}

function Set-PveAccessUsersToken
{
<#
.DESCRIPTION
Update API token for a specific user.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Expire
API token expiration date (seconds since epoch). '0' means no expiration date.
.PARAMETER Privsep
Restrict API token privileges with separate ACLs (default), or give full privileges of corresponding user.
.PARAMETER Tokenid
User-specific token identifier.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Expire,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Privsep,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Tokenid,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Expire']) { $parameters['expire'] = $Expire }
        if($PSBoundParameters['Privsep']) { $parameters['privsep'] = $Privsep }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/access/users/$Userid/token/$Tokenid" -Parameters $parameters
    }
}

function Get-PveAccessGroups
{
<#
.DESCRIPTION
Group index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/groups"
    }
}

function New-PveAccessGroups
{
<#
.DESCRIPTION
Create new group.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Groupid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Groupid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Groupid']) { $parameters['groupid'] = $Groupid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/groups" -Parameters $parameters
    }
}

function Remove-PveAccessGroups
{
<#
.DESCRIPTION
Delete group.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Groupid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Groupid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/access/groups/$Groupid"
    }
}

function Get-PveAccessGroupsIdx
{
<#
.DESCRIPTION
Get group configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Groupid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Groupid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/groups/$Groupid"
    }
}

function Set-PveAccessGroups
{
<#
.DESCRIPTION
Update group data.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Groupid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Groupid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/access/groups/$Groupid" -Parameters $parameters
    }
}

function Get-PveAccessRoles
{
<#
.DESCRIPTION
Role index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/roles"
    }
}

function New-PveAccessRoles
{
<#
.DESCRIPTION
Create new role.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Privs
--
.PARAMETER Roleid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Privs,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Roleid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Privs']) { $parameters['privs'] = $Privs }
        if($PSBoundParameters['Roleid']) { $parameters['roleid'] = $Roleid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/roles" -Parameters $parameters
    }
}

function Remove-PveAccessRoles
{
<#
.DESCRIPTION
Delete role.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Roleid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Roleid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/access/roles/$Roleid"
    }
}

function Get-PveAccessRolesIdx
{
<#
.DESCRIPTION
Get role configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Roleid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Roleid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/roles/$Roleid"
    }
}

function Set-PveAccessRoles
{
<#
.DESCRIPTION
Update an existing role.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Append
--
.PARAMETER Privs
--
.PARAMETER Roleid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Append,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Privs,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Roleid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Append']) { $parameters['append'] = $Append }
        if($PSBoundParameters['Privs']) { $parameters['privs'] = $Privs }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/access/roles/$Roleid" -Parameters $parameters
    }
}

function Get-PveAccessAcl
{
<#
.DESCRIPTION
Get Access Control List (ACLs).
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/acl"
    }
}

function Set-PveAccessAcl
{
<#
.DESCRIPTION
Update Access Control List (add or remove permissions).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Delete
Remove permissions (instead of adding it).
.PARAMETER Groups
List of groups.
.PARAMETER Path
Access control path
.PARAMETER Propagate
Allow to propagate (inherit) permissions.
.PARAMETER Roles
List of roles.
.PARAMETER Tokens
List of API tokens.
.PARAMETER Users
List of users.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Groups,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Path,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Propagate,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Roles,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tokens,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Users
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Groups']) { $parameters['groups'] = $Groups }
        if($PSBoundParameters['Path']) { $parameters['path'] = $Path }
        if($PSBoundParameters['Propagate']) { $parameters['propagate'] = $Propagate }
        if($PSBoundParameters['Roles']) { $parameters['roles'] = $Roles }
        if($PSBoundParameters['Tokens']) { $parameters['tokens'] = $Tokens }
        if($PSBoundParameters['Users']) { $parameters['users'] = $Users }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/access/acl" -Parameters $parameters
    }
}

function Get-PveAccessDomains
{
<#
.DESCRIPTION
Authentication domain index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/domains"
    }
}

function New-PveAccessDomains
{
<#
.DESCRIPTION
Add an authentication server.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AcrValues
Specifies the Authentication Context Class Reference values that theAuthorization Server is being requested to use for the Auth Request.
.PARAMETER Autocreate
Automatically create users if they do not exist.
.PARAMETER BaseDn
LDAP base domain name
.PARAMETER BindDn
LDAP bind domain name
.PARAMETER Capath
Path to the CA certificate store
.PARAMETER CaseSensitive
username is case-sensitive
.PARAMETER Cert
Path to the client certificate
.PARAMETER Certkey
Path to the client certificate key
.PARAMETER CheckConnection
Check bind connection to the server.
.PARAMETER ClientId
OpenID Client ID
.PARAMETER ClientKey
OpenID Client Key
.PARAMETER Comment
Description.
.PARAMETER Default
Use this as default realm
.PARAMETER Domain
AD domain name
.PARAMETER Filter
LDAP filter for user sync.
.PARAMETER GroupClasses
The objectclasses for groups.
.PARAMETER GroupDn
LDAP base domain name for group sync. If not set, the base_dn will be used.
.PARAMETER GroupFilter
LDAP filter for group sync.
.PARAMETER GroupNameAttr
LDAP attribute representing a groups name. If not set or found, the first value of the DN will be used as name.
.PARAMETER IssuerUrl
OpenID Issuer Url
.PARAMETER Mode
LDAP protocol mode. Enum: ldap,ldaps,ldap+starttls
.PARAMETER Password
LDAP bind password. Will be stored in '/etc/pve/priv/realm/<REALM>.pw'.
.PARAMETER Port
Server port.
.PARAMETER Prompt
Specifies whether the Authorization Server prompts the End-User for reauthentication and consent.
.PARAMETER Realm
Authentication domain ID
.PARAMETER Scopes
Specifies the scopes (user details) that should be authorized and returned, for example 'email' or 'profile'.
.PARAMETER Secure
Use secure LDAPS protocol. DEPRECATED':' use 'mode' instead.
.PARAMETER Server1
Server IP address (or DNS name)
.PARAMETER Server2
Fallback Server IP address (or DNS name)
.PARAMETER Sslversion
LDAPS TLS/SSL version. It's not recommended to use version older than 1.2! Enum: tlsv1,tlsv1_1,tlsv1_2,tlsv1_3
.PARAMETER SyncDefaultsOptions
The default options for behavior of synchronizations.
.PARAMETER SyncAttributes
Comma separated list of key=value pairs for specifying which LDAP attributes map to which PVE user field. For example, to map the LDAP attribute 'mail' to PVEs 'email', write  'email=mail'. By default, each PVE user field is represented  by an LDAP attribute of the same name.
.PARAMETER Tfa
Use Two-factor authentication.
.PARAMETER Type
Realm type. Enum: ad,ldap,openid,pam,pve
.PARAMETER UserAttr
LDAP user attribute name
.PARAMETER UserClasses
The objectclasses for users.
.PARAMETER UsernameClaim
OpenID claim used to generate the unique username.
.PARAMETER Verify
Verify the server's SSL certificate
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$AcrValues,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Autocreate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$BaseDn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$BindDn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Capath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CaseSensitive,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cert,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Certkey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CheckConnection,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ClientId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ClientKey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Default,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Domain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Filter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$GroupClasses,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$GroupDn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$GroupFilter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$GroupNameAttr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IssuerUrl,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ldap','ldaps','ldap+starttls')]
        [string]$Mode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Prompt,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Realm,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Scopes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Secure,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server1,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server2,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('tlsv1','tlsv1_1','tlsv1_2','tlsv1_3')]
        [string]$Sslversion,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SyncDefaultsOptions,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SyncAttributes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tfa,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('ad','ldap','openid','pam','pve')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$UserAttr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$UserClasses,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$UsernameClaim,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Verify
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AcrValues']) { $parameters['acr-values'] = $AcrValues }
        if($PSBoundParameters['Autocreate']) { $parameters['autocreate'] = $Autocreate }
        if($PSBoundParameters['BaseDn']) { $parameters['base_dn'] = $BaseDn }
        if($PSBoundParameters['BindDn']) { $parameters['bind_dn'] = $BindDn }
        if($PSBoundParameters['Capath']) { $parameters['capath'] = $Capath }
        if($PSBoundParameters['CaseSensitive']) { $parameters['case-sensitive'] = $CaseSensitive }
        if($PSBoundParameters['Cert']) { $parameters['cert'] = $Cert }
        if($PSBoundParameters['Certkey']) { $parameters['certkey'] = $Certkey }
        if($PSBoundParameters['CheckConnection']) { $parameters['check-connection'] = $CheckConnection }
        if($PSBoundParameters['ClientId']) { $parameters['client-id'] = $ClientId }
        if($PSBoundParameters['ClientKey']) { $parameters['client-key'] = $ClientKey }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Default']) { $parameters['default'] = $Default }
        if($PSBoundParameters['Domain']) { $parameters['domain'] = $Domain }
        if($PSBoundParameters['Filter']) { $parameters['filter'] = $Filter }
        if($PSBoundParameters['GroupClasses']) { $parameters['group_classes'] = $GroupClasses }
        if($PSBoundParameters['GroupDn']) { $parameters['group_dn'] = $GroupDn }
        if($PSBoundParameters['GroupFilter']) { $parameters['group_filter'] = $GroupFilter }
        if($PSBoundParameters['GroupNameAttr']) { $parameters['group_name_attr'] = $GroupNameAttr }
        if($PSBoundParameters['IssuerUrl']) { $parameters['issuer-url'] = $IssuerUrl }
        if($PSBoundParameters['Mode']) { $parameters['mode'] = $Mode }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Prompt']) { $parameters['prompt'] = $Prompt }
        if($PSBoundParameters['Realm']) { $parameters['realm'] = $Realm }
        if($PSBoundParameters['Scopes']) { $parameters['scopes'] = $Scopes }
        if($PSBoundParameters['Secure']) { $parameters['secure'] = $Secure }
        if($PSBoundParameters['Server1']) { $parameters['server1'] = $Server1 }
        if($PSBoundParameters['Server2']) { $parameters['server2'] = $Server2 }
        if($PSBoundParameters['Sslversion']) { $parameters['sslversion'] = $Sslversion }
        if($PSBoundParameters['SyncDefaultsOptions']) { $parameters['sync-defaults-options'] = $SyncDefaultsOptions }
        if($PSBoundParameters['SyncAttributes']) { $parameters['sync_attributes'] = $SyncAttributes }
        if($PSBoundParameters['Tfa']) { $parameters['tfa'] = $Tfa }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['UserAttr']) { $parameters['user_attr'] = $UserAttr }
        if($PSBoundParameters['UserClasses']) { $parameters['user_classes'] = $UserClasses }
        if($PSBoundParameters['UsernameClaim']) { $parameters['username-claim'] = $UsernameClaim }
        if($PSBoundParameters['Verify']) { $parameters['verify'] = $Verify }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/domains" -Parameters $parameters
    }
}

function Remove-PveAccessDomains
{
<#
.DESCRIPTION
Delete an authentication server.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Realm
Authentication domain ID
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Realm
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/access/domains/$Realm"
    }
}

function Get-PveAccessDomainsIdx
{
<#
.DESCRIPTION
Get auth server configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Realm
Authentication domain ID
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Realm
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/domains/$Realm"
    }
}

function Set-PveAccessDomains
{
<#
.DESCRIPTION
Update authentication server settings.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AcrValues
Specifies the Authentication Context Class Reference values that theAuthorization Server is being requested to use for the Auth Request.
.PARAMETER Autocreate
Automatically create users if they do not exist.
.PARAMETER BaseDn
LDAP base domain name
.PARAMETER BindDn
LDAP bind domain name
.PARAMETER Capath
Path to the CA certificate store
.PARAMETER CaseSensitive
username is case-sensitive
.PARAMETER Cert
Path to the client certificate
.PARAMETER Certkey
Path to the client certificate key
.PARAMETER CheckConnection
Check bind connection to the server.
.PARAMETER ClientId
OpenID Client ID
.PARAMETER ClientKey
OpenID Client Key
.PARAMETER Comment
Description.
.PARAMETER Default
Use this as default realm
.PARAMETER Delete
A list of settings you want to delete.
.PARAMETER Digest
Prevent changes if current configuration file has a different digest. This can be used to prevent concurrent modifications.
.PARAMETER Domain
AD domain name
.PARAMETER Filter
LDAP filter for user sync.
.PARAMETER GroupClasses
The objectclasses for groups.
.PARAMETER GroupDn
LDAP base domain name for group sync. If not set, the base_dn will be used.
.PARAMETER GroupFilter
LDAP filter for group sync.
.PARAMETER GroupNameAttr
LDAP attribute representing a groups name. If not set or found, the first value of the DN will be used as name.
.PARAMETER IssuerUrl
OpenID Issuer Url
.PARAMETER Mode
LDAP protocol mode. Enum: ldap,ldaps,ldap+starttls
.PARAMETER Password
LDAP bind password. Will be stored in '/etc/pve/priv/realm/<REALM>.pw'.
.PARAMETER Port
Server port.
.PARAMETER Prompt
Specifies whether the Authorization Server prompts the End-User for reauthentication and consent.
.PARAMETER Realm
Authentication domain ID
.PARAMETER Scopes
Specifies the scopes (user details) that should be authorized and returned, for example 'email' or 'profile'.
.PARAMETER Secure
Use secure LDAPS protocol. DEPRECATED':' use 'mode' instead.
.PARAMETER Server1
Server IP address (or DNS name)
.PARAMETER Server2
Fallback Server IP address (or DNS name)
.PARAMETER Sslversion
LDAPS TLS/SSL version. It's not recommended to use version older than 1.2! Enum: tlsv1,tlsv1_1,tlsv1_2,tlsv1_3
.PARAMETER SyncDefaultsOptions
The default options for behavior of synchronizations.
.PARAMETER SyncAttributes
Comma separated list of key=value pairs for specifying which LDAP attributes map to which PVE user field. For example, to map the LDAP attribute 'mail' to PVEs 'email', write  'email=mail'. By default, each PVE user field is represented  by an LDAP attribute of the same name.
.PARAMETER Tfa
Use Two-factor authentication.
.PARAMETER UserAttr
LDAP user attribute name
.PARAMETER UserClasses
The objectclasses for users.
.PARAMETER Verify
Verify the server's SSL certificate
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$AcrValues,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Autocreate,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$BaseDn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$BindDn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Capath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CaseSensitive,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Cert,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Certkey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$CheckConnection,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ClientId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ClientKey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Default,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Delete,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Digest,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Domain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Filter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$GroupClasses,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$GroupDn,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$GroupFilter,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$GroupNameAttr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$IssuerUrl,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('ldap','ldaps','ldap+starttls')]
        [string]$Mode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$Port,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Prompt,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Realm,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Scopes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Secure,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server1,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Server2,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('tlsv1','tlsv1_1','tlsv1_2','tlsv1_3')]
        [string]$Sslversion,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SyncDefaultsOptions,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SyncAttributes,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Tfa,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$UserAttr,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$UserClasses,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Verify
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AcrValues']) { $parameters['acr-values'] = $AcrValues }
        if($PSBoundParameters['Autocreate']) { $parameters['autocreate'] = $Autocreate }
        if($PSBoundParameters['BaseDn']) { $parameters['base_dn'] = $BaseDn }
        if($PSBoundParameters['BindDn']) { $parameters['bind_dn'] = $BindDn }
        if($PSBoundParameters['Capath']) { $parameters['capath'] = $Capath }
        if($PSBoundParameters['CaseSensitive']) { $parameters['case-sensitive'] = $CaseSensitive }
        if($PSBoundParameters['Cert']) { $parameters['cert'] = $Cert }
        if($PSBoundParameters['Certkey']) { $parameters['certkey'] = $Certkey }
        if($PSBoundParameters['CheckConnection']) { $parameters['check-connection'] = $CheckConnection }
        if($PSBoundParameters['ClientId']) { $parameters['client-id'] = $ClientId }
        if($PSBoundParameters['ClientKey']) { $parameters['client-key'] = $ClientKey }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Default']) { $parameters['default'] = $Default }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Digest']) { $parameters['digest'] = $Digest }
        if($PSBoundParameters['Domain']) { $parameters['domain'] = $Domain }
        if($PSBoundParameters['Filter']) { $parameters['filter'] = $Filter }
        if($PSBoundParameters['GroupClasses']) { $parameters['group_classes'] = $GroupClasses }
        if($PSBoundParameters['GroupDn']) { $parameters['group_dn'] = $GroupDn }
        if($PSBoundParameters['GroupFilter']) { $parameters['group_filter'] = $GroupFilter }
        if($PSBoundParameters['GroupNameAttr']) { $parameters['group_name_attr'] = $GroupNameAttr }
        if($PSBoundParameters['IssuerUrl']) { $parameters['issuer-url'] = $IssuerUrl }
        if($PSBoundParameters['Mode']) { $parameters['mode'] = $Mode }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Port']) { $parameters['port'] = $Port }
        if($PSBoundParameters['Prompt']) { $parameters['prompt'] = $Prompt }
        if($PSBoundParameters['Scopes']) { $parameters['scopes'] = $Scopes }
        if($PSBoundParameters['Secure']) { $parameters['secure'] = $Secure }
        if($PSBoundParameters['Server1']) { $parameters['server1'] = $Server1 }
        if($PSBoundParameters['Server2']) { $parameters['server2'] = $Server2 }
        if($PSBoundParameters['Sslversion']) { $parameters['sslversion'] = $Sslversion }
        if($PSBoundParameters['SyncDefaultsOptions']) { $parameters['sync-defaults-options'] = $SyncDefaultsOptions }
        if($PSBoundParameters['SyncAttributes']) { $parameters['sync_attributes'] = $SyncAttributes }
        if($PSBoundParameters['Tfa']) { $parameters['tfa'] = $Tfa }
        if($PSBoundParameters['UserAttr']) { $parameters['user_attr'] = $UserAttr }
        if($PSBoundParameters['UserClasses']) { $parameters['user_classes'] = $UserClasses }
        if($PSBoundParameters['Verify']) { $parameters['verify'] = $Verify }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/access/domains/$Realm" -Parameters $parameters
    }
}

function New-PveAccessDomainsSync
{
<#
.DESCRIPTION
Syncs users and/or groups from the configured LDAP to user.cfg. NOTE':' Synced groups will have the name 'name-$realm', so make sure those groups do not exist to prevent overwriting.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER DryRun
If set, does not write anything.
.PARAMETER EnableNew
Enable newly synced users immediately.
.PARAMETER Full
DEPRECATED':' use 'remove-vanished' instead. If set, uses the LDAP Directory as source of truth, deleting users or groups not returned from the sync and removing all locally modified properties of synced users. If not set, only syncs information which is present in the synced data, and does not delete or modify anything else.
.PARAMETER Purge
DEPRECATED':' use 'remove-vanished' instead. Remove ACLs for users or groups which were removed from the config during a sync.
.PARAMETER Realm
Authentication domain ID
.PARAMETER RemoveVanished
A semicolon-seperated list of things to remove when they or the user vanishes during a sync. The following values are possible':' 'entry' removes the user/group when not returned from the sync. 'properties' removes the set properties on existing user/group that do not appear in the source (even custom ones). 'acl' removes acls when the user/group is not returned from the sync. Instead of a list it also can be 'none' (the default).
.PARAMETER Scope
Select what to sync. Enum: users,groups,both
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$DryRun,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$EnableNew,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Full,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Purge,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Realm,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$RemoveVanished,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('users','groups','both')]
        [string]$Scope
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['DryRun']) { $parameters['dry-run'] = $DryRun }
        if($PSBoundParameters['EnableNew']) { $parameters['enable-new'] = $EnableNew }
        if($PSBoundParameters['Full']) { $parameters['full'] = $Full }
        if($PSBoundParameters['Purge']) { $parameters['purge'] = $Purge }
        if($PSBoundParameters['RemoveVanished']) { $parameters['remove-vanished'] = $RemoveVanished }
        if($PSBoundParameters['Scope']) { $parameters['scope'] = $Scope }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/domains/$Realm/sync" -Parameters $parameters
    }
}

function Get-PveAccessOpenid
{
<#
.DESCRIPTION
Directory index.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/openid"
    }
}

function New-PveAccessOpenidAuthUrl
{
<#
.DESCRIPTION
Get the OpenId Authorization Url for the specified realm.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Realm
Authentication domain ID
.PARAMETER RedirectUrl
Redirection Url. The client should set this to the used server url (location.origin).
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Realm,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$RedirectUrl
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Realm']) { $parameters['realm'] = $Realm }
        if($PSBoundParameters['RedirectUrl']) { $parameters['redirect-url'] = $RedirectUrl }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/openid/auth-url" -Parameters $parameters
    }
}

function New-PveAccessOpenidLogin
{
<#
.DESCRIPTION
Verify OpenID authorization code and create a ticket.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Code
OpenId authorization code.
.PARAMETER RedirectUrl
Redirection Url. The client should set this to the used server url (location.origin).
.PARAMETER State
OpenId state.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Code,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$RedirectUrl,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$State
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Code']) { $parameters['code'] = $Code }
        if($PSBoundParameters['RedirectUrl']) { $parameters['redirect-url'] = $RedirectUrl }
        if($PSBoundParameters['State']) { $parameters['state'] = $State }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/openid/login" -Parameters $parameters
    }
}

function Get-PveAccessTfa
{
<#
.DESCRIPTION
List TFA configurations of users.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/tfa"
    }
}

function Get-PveAccessTfaIdx
{
<#
.DESCRIPTION
List TFA configurations of users.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/tfa/$Userid"
    }
}

function New-PveAccessTfa
{
<#
.DESCRIPTION
Add a TFA entry for a user.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Challenge
When responding to a u2f challenge':' the original challenge string
.PARAMETER Description
A description to distinguish multiple entries from one another
.PARAMETER Password
The current password.
.PARAMETER Totp
A totp URI.
.PARAMETER Type
TFA Entry Type. Enum: totp,u2f,webauthn,recovery,yubico
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.PARAMETER Value
The current value for the provided totp URI, or a Webauthn/U2F challenge response
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Challenge,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Totp,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][ValidateSet('totp','u2f','webauthn','recovery','yubico')]
        [string]$Type,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Value
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Challenge']) { $parameters['challenge'] = $Challenge }
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Totp']) { $parameters['totp'] = $Totp }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }
        if($PSBoundParameters['Value']) { $parameters['value'] = $Value }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/tfa/$Userid" -Parameters $parameters
    }
}

function Remove-PveAccessTfa
{
<#
.DESCRIPTION
Delete a TFA entry by ID.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
A TFA entry id.
.PARAMETER Password
The current password.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/access/tfa/$Userid/$Id" -Parameters $parameters
    }
}

function Get-PveAccessTfaIdx
{
<#
.DESCRIPTION
Fetch a requested TFA entry if present.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Id
A TFA entry id.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/tfa/$Userid/$Id"
    }
}

function Set-PveAccessTfa
{
<#
.DESCRIPTION
Add a TFA entry for a user.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Description
A description to distinguish multiple entries from one another
.PARAMETER Enable
Whether the entry should be enabled for login.
.PARAMETER Id
A TFA entry id.
.PARAMETER Password
The current password.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Enable,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Id,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Description']) { $parameters['description'] = $Description }
        if($PSBoundParameters['Enable']) { $parameters['enable'] = $Enable }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/access/tfa/$Userid/$Id" -Parameters $parameters
    }
}

function Get-PveAccessTicket
{
<#
.DESCRIPTION
Dummy. Useful for formatters which want to provide a login page.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/ticket"
    }
}

function New-PveAccessTicket
{
<#
.DESCRIPTION
Create or verify authentication ticket.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER NewFormat
This parameter is now ignored and assumed to be 1.
.PARAMETER Otp
One-time password for Two-factor authentication.
.PARAMETER Password
The secret password. This can also be a valid ticket.
.PARAMETER Path
Verify ticket, and check if user have access 'privs' on 'path'
.PARAMETER Privs
Verify ticket, and check if user have access 'privs' on 'path'
.PARAMETER Realm
You can optionally pass the realm using this parameter. Normally the realm is simply added to the username <username>@<relam>.
.PARAMETER TfaChallenge
The signed TFA challenge string the user wants to respond to.
.PARAMETER Username
User name
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$NewFormat,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Otp,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Path,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Privs,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Realm,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$TfaChallenge,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Username
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['NewFormat']) { $parameters['new-format'] = $NewFormat }
        if($PSBoundParameters['Otp']) { $parameters['otp'] = $Otp }
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Path']) { $parameters['path'] = $Path }
        if($PSBoundParameters['Privs']) { $parameters['privs'] = $Privs }
        if($PSBoundParameters['Realm']) { $parameters['realm'] = $Realm }
        if($PSBoundParameters['TfaChallenge']) { $parameters['tfa-challenge'] = $TfaChallenge }
        if($PSBoundParameters['Username']) { $parameters['username'] = $Username }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/access/ticket" -Parameters $parameters
    }
}

function Set-PveAccessPassword
{
<#
.DESCRIPTION
Change user password.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Password
The new password.
.PARAMETER Userid
Full User ID, in the `name@realm` format.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [SecureString]$Password,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Password']) { $parameters['password'] = (ConvertFrom-SecureString -SecureString $Password -AsPlainText) }
        if($PSBoundParameters['Userid']) { $parameters['userid'] = $Userid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/access/password" -Parameters $parameters
    }
}

function Get-PveAccessPermissions
{
<#
.DESCRIPTION
Retrieve effective permissions of given user/token.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Path
Only dump this specific path, not the whole tree.
.PARAMETER Userid
User ID or full API token ID
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Path,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Userid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Path']) { $parameters['path'] = $Path }
        if($PSBoundParameters['Userid']) { $parameters['userid'] = $Userid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/access/permissions" -Parameters $parameters
    }
}

function Remove-PvePools
{
<#
.DESCRIPTION
Delete pool.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Poolid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Poolid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Poolid']) { $parameters['poolid'] = $Poolid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/pools" -Parameters $parameters
    }
}

function Get-PvePools
{
<#
.DESCRIPTION
List pools or get pool configuration.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Poolid
--
.PARAMETER Type
-- Enum: qemu,lxc,storage
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Poolid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('qemu','lxc','storage')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Poolid']) { $parameters['poolid'] = $Poolid }
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/pools" -Parameters $parameters
    }
}

function New-PvePools
{
<#
.DESCRIPTION
Create new pool.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Comment
--
.PARAMETER Poolid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Poolid
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Poolid']) { $parameters['poolid'] = $Poolid }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Create -Resource "/pools" -Parameters $parameters
    }
}

function Set-PvePools
{
<#
.DESCRIPTION
Update pool.
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AllowMove
Allow adding a guest even if already in another pool. The guest will be removed from its current pool and added to this one.
.PARAMETER Comment
--
.PARAMETER Delete
Remove the passed VMIDs and/or storage IDs instead of adding them.
.PARAMETER Poolid
--
.PARAMETER Storage
List of storage IDs to add or remove from this pool.
.PARAMETER Vms
List of guest VMIDs to add or remove from this pool.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AllowMove,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Delete,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Poolid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vms
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AllowMove']) { $parameters['allow-move'] = $AllowMove }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Poolid']) { $parameters['poolid'] = $Poolid }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Vms']) { $parameters['vms'] = $Vms }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/pools" -Parameters $parameters
    }
}

function Remove-PvePoolsIdx
{
<#
.DESCRIPTION
Delete pool (deprecated, no support for nested pools, use 'DELETE /pools/?poolid={poolid}').
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Poolid
--
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Poolid
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Delete -Resource "/pools/$Poolid"
    }
}

function Get-PvePoolsIdx
{
<#
.DESCRIPTION
Get pool configuration (deprecated, no support for nested pools, use 'GET /pools/?poolid={poolid}').
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER Poolid
--
.PARAMETER Type
-- Enum: qemu,lxc,storage
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Poolid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('qemu','lxc','storage')]
        [string]$Type
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['Type']) { $parameters['type'] = $Type }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/pools/$Poolid" -Parameters $parameters
    }
}

function Set-PvePoolsIdx
{
<#
.DESCRIPTION
Update pool data (deprecated, no support for nested pools - use 'PUT /pools/?poolid={poolid}' instead).
.PARAMETER PveTicket
Ticket data connection.
.PARAMETER AllowMove
Allow adding a guest even if already in another pool. The guest will be removed from its current pool and added to this one.
.PARAMETER Comment
--
.PARAMETER Delete
Remove the passed VMIDs and/or storage IDs instead of adding them.
.PARAMETER Poolid
--
.PARAMETER Storage
List of storage IDs to add or remove from this pool.
.PARAMETER Vms
List of guest VMIDs to add or remove from this pool.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$AllowMove,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Comment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [switch]$Delete,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [string]$Poolid,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Storage,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Vms
    )

    process {
        $parameters = @{}
        if($PSBoundParameters['AllowMove']) { $parameters['allow-move'] = $AllowMove }
        if($PSBoundParameters['Comment']) { $parameters['comment'] = $Comment }
        if($PSBoundParameters['Delete']) { $parameters['delete'] = $Delete }
        if($PSBoundParameters['Storage']) { $parameters['storage'] = $Storage }
        if($PSBoundParameters['Vms']) { $parameters['vms'] = $Vms }

        return Invoke-PveRestApi -PveTicket $PveTicket -Method Set -Resource "/pools/$Poolid" -Parameters $parameters
    }
}

function Get-PveVersion
{
<#
.DESCRIPTION
API version details, including some parts of the global datacenter config.
.PARAMETER PveTicket
Ticket data connection.
.OUTPUTS
PveResponse. Return response.
#>
    [OutputType([PveResponse])]
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [PveTicket]$PveTicket
    )

    process {
        return Invoke-PveRestApi -PveTicket $PveTicket -Method Get -Resource "/version"
    }
}
