#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Fqdns,

    [Parameter(Mandatory = $true)]
    [string]$CustomerDnsServer
)

foreach ($fqdn in $Fqdns) {
    Write-Host "`n=====================================" -ForegroundColor DarkGray
    Write-Host "FQDN: $fqdn" -ForegroundColor Yellow

    Write-Host "`n使用 Appliance 預設 DNS：" -ForegroundColor Cyan
    try {
        Resolve-DnsName -Name $fqdn -DnsOnly -ErrorAction Stop |
            Format-Table Name, Type, NameHost, IPAddress -AutoSize
    }
    catch {
        Write-Host "查詢失敗：$($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`n使用指定客戶 DNS：$CustomerDnsServer" -ForegroundColor Cyan
    try {
        Resolve-DnsName -Name $fqdn -Server $CustomerDnsServer -DnsOnly -ErrorAction Stop |
            Format-Table Name, Type, NameHost, IPAddress -AutoSize
    }
    catch {
        Write-Host "查詢失敗：$($_.Exception.Message)" -ForegroundColor Red
    }
}
