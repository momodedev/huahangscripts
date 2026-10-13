#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputFolder = "C:\AzureMigrate-Network-Test"
)

$ErrorActionPreference = "Continue"
New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
$TimeStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportFile = Join-Path $OutputFolder "Appliance-Baseline-$TimeStamp.txt"

Start-Transcript -Path $ReportFile -Force
try {
    Write-Host "=== System Information ===" -ForegroundColor Cyan
    Get-ComputerInfo | Select-Object CsName, WindowsProductName, WindowsVersion, OsBuildNumber, CsDomain, CsDomainRole | Format-List

    Write-Host "`n=== Active Network Adapters ===" -ForegroundColor Cyan
    Get-NetAdapter | Where-Object Status -eq "Up" | Format-Table Name, InterfaceDescription, Status, LinkSpeed, MacAddress -AutoSize

    Write-Host "`n=== IP Configuration ===" -ForegroundColor Cyan
    Get-NetIPConfiguration -Detailed | Format-List InterfaceAlias, InterfaceIndex, IPv4Address, IPv4DefaultGateway, DNSServer, NetProfile

    Write-Host "`n=== DNS Client Configuration ===" -ForegroundColor Cyan
    Get-DnsClient | Format-Table InterfaceAlias, ConnectionSpecificSuffix, RegisterThisConnectionsAddress, UseSuffixWhenRegistering -AutoSize
    Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table InterfaceAlias, ServerAddresses -AutoSize

    Write-Host "`n=== IPv4 Route Table ===" -ForegroundColor Cyan
    Get-NetRoute -AddressFamily IPv4 | Sort-Object DestinationPrefix, RouteMetric | Format-Table DestinationPrefix, NextHop, InterfaceAlias, RouteMetric, Protocol -AutoSize

    Write-Host "`n=== WinHTTP Proxy ===" -ForegroundColor Cyan
    netsh winhttp show proxy

    Write-Host "`n=== Current User Internet Proxy ===" -ForegroundColor Cyan
    Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue |
        Select-Object ProxyEnable, ProxyServer, AutoConfigURL | Format-List

    Write-Host "`n=== Windows Firewall Profiles ===" -ForegroundColor Cyan
    Get-NetFirewallProfile | Format-Table Name, Enabled, DefaultInboundAction, DefaultOutboundAction -AutoSize

    Write-Host "`n=== Time Synchronization ===" -ForegroundColor Cyan
    w32tm /query /status
}
finally {
    Stop-Transcript | Out-Null
}
Write-Host "報告已儲存至：$ReportFile" -ForegroundColor Green
