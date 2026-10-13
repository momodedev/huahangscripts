#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Fqdns,

    [int]$Port = 443,

    [int]$TimeoutMilliseconds = 10000
)

foreach ($fqdn in $Fqdns) {
    Write-Host "`n=== TLS Test: $fqdn ===" -ForegroundColor Cyan
    $tcpClient = $null
    $sslStream = $null
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcpClient.BeginConnect($fqdn, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            throw "TCP 連線逾時。"
        }
        $tcpClient.EndConnect($asyncResult)

        $validationCallback = {
            param($sender, $certificate, $chain, $sslPolicyErrors)
            return $true
        }
        $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, $validationCallback)
        $sslStream.AuthenticateAsClient($fqdn)
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)

        [pscustomobject]@{
            Fqdn = $fqdn
            TcpConnected = $tcpClient.Connected
            TlsProtocol = $sslStream.SslProtocol
            CertificateSubject = $certificate.Subject
            CertificateIssuer = $certificate.Issuer
            CertificateNotBefore = $certificate.NotBefore
            CertificateNotAfter = $certificate.NotAfter
            Thumbprint = $certificate.Thumbprint
        } | Format-List
    }
    catch {
        Write-Host "TLS 測試失敗：$($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($sslStream) { $sslStream.Dispose() }
        if ($tcpClient) { $tcpClient.Close() }
    }
}
