#requires -Version 5.1
#requires -Modules Az.Accounts,Az.Network,Az.PrivateDns
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$OutputFolder = ".\AzureMigrate-Network-Test"
)

$ErrorActionPreference = "Stop"
New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
$TimeStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportFile = Join-Path $OutputFolder "Azure-Side-Validation-$TimeStamp.txt"

Start-Transcript -Path $ReportFile -Force
try {
    Write-Host "=== Azure Context ===" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Get-AzContext | Format-List Account, Subscription, Tenant

    Write-Host "`n=== Private Endpoints in Resource Group ===" -ForegroundColor Cyan
    $privateEndpoints = @(Get-AzPrivateEndpoint -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue)
    if ($privateEndpoints.Count -eq 0) {
        Write-Warning "指定資源群組內未找到 Private Endpoint，或目前帳號無查詢權限。"
    }

    foreach ($pe in $privateEndpoints) {
        Write-Host "`nPrivate Endpoint: $($pe.Name)" -ForegroundColor Yellow
        Write-Host "Location: $($pe.Location)"
        Write-Host "Subnet ID: $($pe.Subnet.Id)"

        foreach ($connection in @($pe.PrivateLinkServiceConnections)) {
            Write-Host "Target Resource: $($connection.PrivateLinkServiceId)"
            Write-Host "Group IDs: $(@($connection.GroupIds) -join ', ')"
            Write-Host "Connection State: $($connection.PrivateLinkServiceConnectionState.Status)"
            Write-Host "Description: $($connection.PrivateLinkServiceConnectionState.Description)"
        }

        foreach ($nicRef in @($pe.NetworkInterfaces)) {
            $parts = $nicRef.Id.Trim('/') -split '/'
            $nicResourceGroup = $parts[3]
            $nicName = $parts[-1]
            $nic = Get-AzNetworkInterface -ResourceGroupName $nicResourceGroup -Name $nicName
            foreach ($ipConfig in @($nic.IpConfigurations)) {
                Write-Host "NIC: $nicName"
                Write-Host "Private IP: $($ipConfig.PrivateIpAddress)"
                Write-Host "Allocation: $($ipConfig.PrivateIpAllocationMethod)"
            }
        }

        foreach ($dnsConfig in @($pe.CustomDnsConfigs)) {
            Write-Host "FQDN: $($dnsConfig.Fqdn)"
            Write-Host "DNS IPs: $(@($dnsConfig.IpAddresses) -join ', ')"
        }
    }

    Write-Host "`n=== Private DNS Zones accessible to current account ===" -ForegroundColor Cyan
    $zones = @(Get-AzPrivateDnsZone -ErrorAction SilentlyContinue)
    foreach ($zone in $zones) {
        Write-Host "`nZone: $($zone.Name)" -ForegroundColor Yellow
        Write-Host "Resource Group: $($zone.ResourceGroupName)"
        $links = @(Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name -ErrorAction SilentlyContinue)
        foreach ($link in $links) {
            Write-Host "VNet Link: $($link.Name)"
            Write-Host "VNet ID: $($link.VirtualNetworkId)"
            Write-Host "Link State: $($link.VirtualNetworkLinkState)"
            Write-Host "Registration Enabled: $($link.RegistrationEnabled)"
        }
        $records = @(Get-AzPrivateDnsRecordSet -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name -RecordType A -ErrorAction SilentlyContinue)
        foreach ($record in $records) {
            $ips = @($record.Records | ForEach-Object { $_.Ipv4Address })
            Write-Host "A Record: $($record.Name) -> $($ips -join ', ')"
        }
    }

    Write-Host "`n=== VPN Gateway Connections in Resource Group ===" -ForegroundColor Cyan
    $connections = @(Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue)
    foreach ($vpn in $connections) {
        Write-Host "`nConnection: $($vpn.Name)" -ForegroundColor Yellow
        Write-Host "Connection Type: $($vpn.ConnectionType)"
        Write-Host "Provisioning State: $($vpn.ProvisioningState)"
        Write-Host "Connection Status: $($vpn.ConnectionStatus)"
        Write-Host "Ingress Bytes: $($vpn.IngressBytesTransferred)"
        Write-Host "Egress Bytes: $($vpn.EgressBytesTransferred)"
    }
}
finally {
    Stop-Transcript | Out-Null
}
Write-Host "報告已儲存至：$ReportFile" -ForegroundColor Green
