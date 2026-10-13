#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VCenterFqdn,

    [string]$ExpectedVCenterIP = "",

    [string]$OutputFolder = "C:\AzureMigrate-Network-Test"
)

$ErrorActionPreference = "Continue"
New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
$TimeStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportFile = Join-Path $OutputFolder "vCenter-Test-$TimeStamp.txt"

Start-Transcript -Path $ReportFile -Force
try {
    Write-Host "=== vCenter DNS Resolution ===" -ForegroundColor Cyan
    $resolvedIPs = @()
    try {
        $dnsResult = Resolve-DnsName -Name $VCenterFqdn -Type A -DnsOnly -ErrorAction Stop
        $resolvedIPs = @($dnsResult | Where-Object { $_.Type -eq "A" -and $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique)
        Write-Host "vCenter FQDN: $VCenterFqdn"
        Write-Host "Resolved IPs: $($resolvedIPs -join ', ')"
        if ($ExpectedVCenterIP) {
            if ($resolvedIPs -contains $ExpectedVCenterIP) {
                Write-Host "PASS：解析結果包含預期 vCenter IP。" -ForegroundColor Green
            }
            else {
                Write-Host "FAIL：解析結果不包含預期 vCenter IP：$ExpectedVCenterIP" -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Host "FAIL：vCenter DNS 解析失敗。$($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`n=== vCenter TCP 443 Test ===" -ForegroundColor Cyan
    $tcpTest = Test-NetConnection -ComputerName $VCenterFqdn -Port 443 -InformationLevel Detailed -WarningAction SilentlyContinue
    $tcpTest | Format-List ComputerName, RemoteAddress, RemotePort, NameResolutionResults, InterfaceAlias, SourceAddress, NetRoute, TcpTestSucceeded
    if ($tcpTest.TcpTestSucceeded) {
        Write-Host "PASS：Appliance 可連線到 vCenter TCP 443。" -ForegroundColor Green
    }
    else {
        Write-Host "FAIL：Appliance 無法連線到 vCenter TCP 443。" -ForegroundColor Red
    }
}
finally {
    Stop-Transcript | Out-Null
}
Write-Host "報告已儲存至：$ReportFile" -ForegroundColor Green
