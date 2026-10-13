#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [string]$DnsServer = "",

    [string]$OutputFolder = "C:\AzureMigrate-Network-Test"
)

$ErrorActionPreference = "Continue"
if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "找不到 CSV 檔案：$CsvPath"
}
New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
$TimeStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$TextReport = Join-Path $OutputFolder "PrivateEndpoint-Test-$TimeStamp.txt"
$CsvReport = Join-Path $OutputFolder "PrivateEndpoint-Results-$TimeStamp.csv"
$targets = @(Import-Csv -LiteralPath $CsvPath)
$results = @()

Start-Transcript -Path $TextReport -Force
try {
    Write-Host "=== Azure Migrate Private Endpoint Validation ===" -ForegroundColor Cyan
    Write-Host "Test Time: $(Get-Date)"
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "Target Count: $($targets.Count)"

    foreach ($target in $targets) {
        $name = [string]$target.Name
        $fqdn = ([string]$target.Fqdn).Trim()
        $expectedIP = ([string]$target.ExpectedPrivateIP).Trim()
        $port = 443
        if ($target.Port -and ([string]$target.Port -match '^\d+$')) {
            $port = [int]$target.Port
        }

        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            Write-Warning "略過空白 FQDN，項目：$name"
            continue
        }

        Write-Host "`n========================================" -ForegroundColor DarkGray
        Write-Host "Target Name : $name" -ForegroundColor Yellow
        Write-Host "FQDN        : $fqdn"
        Write-Host "Expected IP : $expectedIP"
        Write-Host "Port        : $port"

        $resolvedIPs = @()
        $dnsPassed = $false
        $expectedIPMatched = $false
        $tcpPassed = $false
        $sourceAddress = ""
        $remoteAddress = ""
        $interfaceAlias = ""
        $nextHop = ""
        $routePrefix = ""
        $notes = @()

        try {
            if ([string]::IsNullOrWhiteSpace($DnsServer)) {
                $dnsResult = Resolve-DnsName -Name $fqdn -Type A -DnsOnly -ErrorAction Stop
            }
            else {
                $dnsResult = Resolve-DnsName -Name $fqdn -Type A -Server $DnsServer -DnsOnly -ErrorAction Stop
            }
            $resolvedIPs = @($dnsResult | Where-Object { $_.Type -eq "A" -and $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique)
            $dnsPassed = ($resolvedIPs.Count -gt 0)
            Write-Host "DNS Result: $($resolvedIPs -join ', ')"
            if ($expectedIP) {
                $expectedIPMatched = ($resolvedIPs -contains $expectedIP)
                if ($expectedIPMatched) {
                    Write-Host "PASS：DNS 解析包含預期 Private IP。" -ForegroundColor Green
                }
                else {
                    $notes += "DNS 未解析至預期 Private IP"
                    Write-Host "FAIL：DNS 未解析至預期 Private IP。" -ForegroundColor Red
                }
            }
            else {
                $notes += "未提供 ExpectedPrivateIP"
            }
        }
        catch {
            $notes += "DNS 解析失敗：$($_.Exception.Message)"
            Write-Host "FAIL：DNS 解析失敗。$($_.Exception.Message)" -ForegroundColor Red
        }

        try {
            $tcpTest = Test-NetConnection -ComputerName $fqdn -Port $port -InformationLevel Detailed -WarningAction SilentlyContinue
            $tcpPassed = [bool]$tcpTest.TcpTestSucceeded
            $sourceAddress = [string]$tcpTest.SourceAddress
            $remoteAddress = [string]$tcpTest.RemoteAddress
            $interfaceAlias = [string]$tcpTest.InterfaceAlias
            if ($tcpTest.NetRoute) {
                $nextHop = [string]$tcpTest.NetRoute.NextHop
                $routePrefix = [string]$tcpTest.NetRoute.DestinationPrefix
            }
            $tcpTest | Format-List ComputerName, RemoteAddress, RemotePort, InterfaceAlias, SourceAddress, NetRoute, TcpTestSucceeded
            if ($tcpPassed) {
                Write-Host "PASS：TCP $port 連線成功。" -ForegroundColor Green
            }
            else {
                $notes += "TCP $port 連線失敗"
                Write-Host "FAIL：TCP $port 連線失敗。" -ForegroundColor Red
            }
        }
        catch {
            $notes += "TCP 測試例外：$($_.Exception.Message)"
        }

        $routeTarget = $expectedIP
        if (-not $routeTarget -and $resolvedIPs.Count -gt 0) {
            $routeTarget = $resolvedIPs[0]
        }
        if ($routeTarget) {
            Write-Host "`n=== Route Selection for $routeTarget ===" -ForegroundColor Cyan
            try {
                Find-NetRoute -RemoteIPAddress $routeTarget -ErrorAction Stop | Format-List IPAddress, InterfaceAlias, NextHop, RouteMetric
            }
            catch {
                Write-Host "無法取得 Find-NetRoute 結果：$($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        $overallStatus = "FAIL"
        if ($dnsPassed -and $tcpPassed -and ((-not $expectedIP) -or $expectedIPMatched)) {
            $overallStatus = "PASS"
        }

        $results += [pscustomobject]@{
            Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Name = $name
            Fqdn = $fqdn
            ExpectedPrivateIP = $expectedIP
            ResolvedIPs = $resolvedIPs -join ";"
            DnsPassed = $dnsPassed
            ExpectedIPMatched = $expectedIPMatched
            Port = $port
            TcpPassed = $tcpPassed
            SourceAddress = $sourceAddress
            RemoteAddress = $remoteAddress
            InterfaceAlias = $interfaceAlias
            SelectedRoutePrefix = $routePrefix
            SelectedNextHop = $nextHop
            OverallStatus = $overallStatus
            Notes = $notes -join " | "
        }
    }

    $results | Export-Csv -LiteralPath $CsvReport -NoTypeInformation -Encoding UTF8
    Write-Host "`n=== Test Summary ===" -ForegroundColor Cyan
    $results | Format-Table Name, Fqdn, ExpectedPrivateIP, ResolvedIPs, TcpPassed, OverallStatus -AutoSize
    Write-Host "PASS: $(@($results | Where-Object OverallStatus -eq 'PASS').Count)" -ForegroundColor Green
    Write-Host "FAIL: $(@($results | Where-Object OverallStatus -eq 'FAIL').Count)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
}
Write-Host "文字報告：$TextReport" -ForegroundColor Green
Write-Host "CSV 報告：$CsvReport" -ForegroundColor Green
