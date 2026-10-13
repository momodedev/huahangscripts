#requires -Version 7.0
#requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
  唯讀檢查 Azure Migrate Discovery & Assessment 的 Azure Subscription 與操作員權限。
.NOTES
  適用 Azure Portal Cloud Shell PowerShell。腳本不會建立、修改或刪除資源，
  不會註冊 Resource Provider，也不會指派 RBAC 角色。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Alias("AzureMigrateProjectNames")]
    [string[]]$AzureMigrateProjectName = @(),

    [string]$OutputFolder = "$HOME/clouddrive/AzureMigrate-Permission-Check"
)

$ErrorActionPreference = "Stop"
$results = [System.Collections.Generic.List[object]]::new()
$transcriptStarted = $false

function Add-CheckResult {
    param(
        [string]$Category,
        [string]$Item,
        [ValidateSet("PASS", "REVIEW", "FAIL")]
        [string]$Status,
        [string]$Detail,
        [string]$Recommendation = ""
    )

    $results.Add([pscustomobject]@{
        Category       = $Category
        Item           = $Item
        Status         = $Status
        Detail         = $Detail
        Recommendation = $Recommendation
    })
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        "PASS" { return "Green" }
        "FAIL" { return "Red" }
        default { return "Yellow" }
    }
}

function Test-AssignmentAppliesToScope {
    param(
        [string]$AssignmentScope,
        [string]$TargetScope
    )

    if ([string]::IsNullOrWhiteSpace($AssignmentScope)) { return $false }
    $normalizedAssignment = $AssignmentScope.TrimEnd("/")
    $normalizedTarget = $TargetScope.TrimEnd("/")

    return (
        $normalizedTarget -eq $normalizedAssignment -or
        $normalizedTarget.StartsWith(
            "$normalizedAssignment/",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$timeStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$textReport = Join-Path $OutputFolder "AzureMigrate-Permission-$timeStamp.txt"
$csvReport = Join-Path $OutputFolder "AzureMigrate-Permission-$timeStamp.csv"
$jsonReport = Join-Path $OutputFolder "AzureMigrate-Permission-$timeStamp.json"

try {
    Start-Transcript -Path $textReport -Force | Out-Null
    $transcriptStarted = $true

    Write-Host "=== 1. Azure Context ===" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    $context = Get-AzContext

    if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
        throw "無法切換至指定的 Azure Subscription。"
    }

    $accountId = [string]$context.Account.Id
    Write-Host "Account       : $accountId"
    Write-Host "Tenant ID     : $($context.Tenant.Id)"
    Write-Host "Subscription  : $($context.Subscription.Name)"
    Write-Host "SubscriptionId: $SubscriptionId"
    Add-CheckResult -Category "Context" -Item "Subscription access" -Status "PASS" `
        -Detail "已登入並切換至 $($context.Subscription.Name)。"

    $subscription = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
    if ($subscription.State -eq "Enabled") {
        Add-CheckResult -Category "Subscription" -Item "State" -Status "PASS" -Detail "Enabled"
    }
    else {
        Add-CheckResult -Category "Subscription" -Item "State" -Status "FAIL" `
            -Detail ([string]$subscription.State) `
            -Recommendation "請由 Subscription 管理員確認訂用帳戶狀態。"
    }

    Write-Host "`n=== 2. Resource Providers ===" -ForegroundColor Cyan
    $providerNamespaces = @(
        "Microsoft.Migrate",
        "Microsoft.OffAzure",
        "Microsoft.Network",
        "Microsoft.Storage",
        "Microsoft.KeyVault"
    )

    foreach ($providerNamespace in $providerNamespaces) {
        try {
            $provider = Get-AzResourceProvider `
                -ProviderNamespace $providerNamespace `
                -ErrorAction Stop

            $registrationStates = @(
                $provider |
                    ForEach-Object { $_.RegistrationState } |
                    Where-Object { $_ } |
                    Select-Object -Unique
            )

            if ($registrationStates -contains "Registered") {
                Add-CheckResult -Category "Resource Provider" -Item $providerNamespace `
                    -Status "PASS" -Detail ($registrationStates -join ", ")
            }
            else {
                Add-CheckResult -Category "Resource Provider" -Item $providerNamespace `
                    -Status "REVIEW" -Detail ($registrationStates -join ", ") `
                    -Recommendation "請依實際 Azure Migrate 建置流程確認是否需要註冊；本腳本不會自動註冊。"
            }
        }
        catch {
            Add-CheckResult -Category "Resource Provider" -Item $providerNamespace `
                -Status "REVIEW" -Detail $_.Exception.Message `
                -Recommendation "目前操作員可能沒有讀取 Provider 狀態的權限。"
        }
    }

    Write-Host "`n=== 3. Resource Group ===" -ForegroundColor Cyan
    $resourceGroup = $null
    try {
        $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
        Add-CheckResult -Category "Resource Group" -Item $ResourceGroupName `
            -Status "PASS" -Detail "Location=$($resourceGroup.Location)"
    }
    catch {
        Add-CheckResult -Category "Resource Group" -Item $ResourceGroupName `
            -Status "FAIL" -Detail $_.Exception.Message `
            -Recommendation "確認名稱、Subscription Context 及 Resource Group 讀取權限。"
    }

    $subscriptionScope = "/subscriptions/$SubscriptionId"
    $resourceGroupScope = "$subscriptionScope/resourceGroups/$ResourceGroupName"

    Write-Host "`n=== 4. Current operator RBAC ===" -ForegroundColor Cyan
    $assignments = @()
    try {
        if ($accountId -like "MSI@*") {
            throw "Azure context reports managed identity '$accountId', which is not a UPN or object ID accepted by -SignInName."
        }

        $roleCommand = Get-Command Get-AzRoleAssignment -ErrorAction Stop
        if ($roleCommand.Parameters.ContainsKey("ExpandPrincipalGroups")) {
            $assignments = @(
                Get-AzRoleAssignment -SignInName $accountId `
                    -ExpandPrincipalGroups -ErrorAction Stop
            )
        }
        else {
            $assignments = @(
                Get-AzRoleAssignment -SignInName $accountId -ErrorAction Stop
            )
            Add-CheckResult -Category "RBAC" -Item "Group expansion" -Status "REVIEW" `
                -Detail "目前 Az.Resources 版本未提供 ExpandPrincipalGroups 參數。" `
                -Recommendation "請在 Azure Portal IAM > Check access 補充確認群組繼承角色。"
        }

        $relevantAssignments = @(
            $assignments | Where-Object {
                Test-AssignmentAppliesToScope `
                    -AssignmentScope ([string]$_.Scope) `
                    -TargetScope $resourceGroupScope
            }
        )

        if ($relevantAssignments.Count -gt 0) {
            Add-CheckResult -Category "RBAC" -Item "Relevant assignments" -Status "PASS" `
                -Detail "$($relevantAssignments.Count) 筆適用於目標 Resource Group 的角色指派。"

            $relevantAssignments |
                Select-Object DisplayName, SignInName, RoleDefinitionName, Scope, ObjectType |
                Format-Table -AutoSize
        }
        else {
            Add-CheckResult -Category "RBAC" -Item "Relevant assignments" -Status "REVIEW" `
                -Detail "未列出適用於目標 Resource Group 的直接或群組型角色指派。" `
                -Recommendation "請於 IAM Check access 與 PIM 再確認管理群組/Subscription 繼承、自訂角色及已啟用資格。"
        }
    }
    catch {
        $rbacError = $_.Exception.Message
        if ($accountId -like "MSI@*") {
            $rbacError = "無法以 Cloud Shell managed identity 標籤 '$accountId' 解析操作員 principal；需使用其 Entra Object ID 查詢角色指派。原始訊息：$rbacError"
        }
        Add-CheckResult -Category "RBAC" -Item "Relevant assignments" -Status "REVIEW" `
            -Detail $rbacError `
            -Recommendation "查詢 Role Assignment 可能需要 Microsoft.Authorization/roleAssignments/read；請由 IAM 管理員執行或使用 Portal Check access。"
    }

    Write-Host "`n=== 5. Azure Migrate Built-in Roles ===" -ForegroundColor Cyan
    $azureMigrateRoleNames = @(
        "Azure Migrate Owner",
        "Azure Migrate Decide and Plan Expert",
        "Azure Migrate Execute Expert"
    )

    foreach ($roleName in $azureMigrateRoleNames) {
        try {
            $roleDefinition = Get-AzRoleDefinition -Name $roleName -ErrorAction Stop
            Add-CheckResult -Category "Role Definition" -Item $roleName `
                -Status "PASS" -Detail "RoleId=$($roleDefinition.Id)"
        }
        catch {
            Add-CheckResult -Category "Role Definition" -Item $roleName `
                -Status "REVIEW" `
                -Detail "目前環境查無此角色名稱，或操作員無角色定義讀取權限。" `
                -Recommendation "請以 Azure Portal IAM role picker 與 Microsoft 最新文件核對。"
        }
    }

    $assessmentRoleNames = @(
        "Azure Migrate Owner",
        "Azure Migrate Decide and Plan Expert",
        "Owner",
        "Contributor"
    )

    if ($assignments.Count -gt 0) {
        $matchingAssignments = @(
            $assignments | Where-Object {
                $_.RoleDefinitionName -in $assessmentRoleNames -and
                (Test-AssignmentAppliesToScope `
                    -AssignmentScope ([string]$_.Scope) `
                    -TargetScope $resourceGroupScope)
            }
        )

        if ($matchingAssignments.Count -gt 0) {
            $matchingRoleNames = @(
                $matchingAssignments |
                    Select-Object -ExpandProperty RoleDefinitionName -Unique
            )
            Add-CheckResult -Category "Assessment Readiness" -Item "Operator role" `
                -Status "PASS" -Detail ($matchingRoleNames -join ", ") `
                -Recommendation "仍需確認 PIM、Deny Assignment、Azure Policy 與實際作業。"
        }
        else {
            Add-CheckResult -Category "Assessment Readiness" -Item "Operator role" `
                -Status "REVIEW" `
                -Detail "未偵測到預設接受清單中的角色。" `
                -Recommendation "請依最小權限原則評估 Azure Migrate Decide and Plan Expert，或檢查自訂角色是否包含必要 Actions。"
        }
    }

    Write-Host "`n=== 6. Azure Migrate Resources ===" -ForegroundColor Cyan
    if ($resourceGroup) {
        if ($AzureMigrateProjectName.Count -eq 0) {
            $projectInput = Read-Host "要測試的 Azure Migrate Project 名稱（可用逗號分隔；直接 Enter 略過）"
            if (-not [string]::IsNullOrWhiteSpace($projectInput)) {
                $AzureMigrateProjectName = @($projectInput -split "[,;]")
            }
        }
        $projectNames = @(
            $AzureMigrateProjectName |
                ForEach-Object { ([string]$_ -split "[,;]") } |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )

        try {
            $resources = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
            $migrateResources = @(
                $resources | Where-Object {
                    $_.ResourceType -match "^Microsoft\.(Migrate|OffAzure)/"
                }
            )

            if ($migrateResources.Count -gt 0) {
                Add-CheckResult -Category "Resources" -Item "Azure Migrate resources" `
                    -Status "PASS" -Detail "$($migrateResources.Count) 筆可讀取資源。"
                $migrateResources |
                    Select-Object Name, ResourceType, Location, ResourceId |
                    Format-Table -AutoSize
            }
            else {
                Add-CheckResult -Category "Resources" -Item "Azure Migrate resources" `
                    -Status "REVIEW" `
                    -Detail "資源群組內未列出 Microsoft.Migrate 或 Microsoft.OffAzure 資源。" `
                    -Recommendation "若尚未建立專案，此結果可能正常；若已建立，請確認 Resource Group 與讀取權限。"
            }

            $projectResources = @(
                $resources | Where-Object {
                    $_.ResourceType -match "^Microsoft\.Migrate/(migrateprojects|assessmentProjects)$"
                }
            )
            foreach ($projectName in $projectNames) {
                $projects = @($projectResources | Where-Object { $_.Name -eq $projectName })
                if ($projects.Count -gt 0) {
                    Add-CheckResult -Category "Project" -Item $projectName `
                        -Status "PASS" `
                        -Detail (($projects | ForEach-Object { "$($_.ResourceType): $($_.ResourceId)" }) -join "; ")
                }
                else {
                    Add-CheckResult -Category "Project" -Item $projectName `
                        -Status "FAIL" -Detail "在指定 Resource Group 中找不到名稱相符的 Microsoft.Migrate/migrateProjects 或 assessmentProjects 資源。" `
                        -Recommendation "確認 Azure Migrate Project 名稱、Resource Group 與 Subscription。"
                }
            }
        }
        catch {
            Add-CheckResult -Category "Resources" -Item "Azure Migrate resources" `
                -Status "REVIEW" -Detail $_.Exception.Message `
                -Recommendation "確認 Microsoft.Resources/subscriptions/resourceGroups/resources/read 權限。"
        }
    }

    Write-Host "`n=== 7. Summary ===" -ForegroundColor Cyan
    foreach ($result in $results) {
        Write-Host `
            ("[{0}] {1} / {2}: {3}" -f $result.Status, $result.Category, $result.Item, $result.Detail) `
            -ForegroundColor (Get-StatusColor -Status $result.Status)
    }

    $results | Export-Csv -Path $csvReport -NoTypeInformation -Encoding utf8
    $results | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonReport -Encoding utf8
}
catch {
    Add-CheckResult -Category "Script" -Item "Unhandled error" -Status "FAIL" `
        -Detail $_.Exception.Message `
        -Recommendation "確認輸入參數、Azure Context 與 Cloud Shell Az 模組。"

    $results | Export-Csv -Path $csvReport -NoTypeInformation -Encoding utf8
    $results | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonReport -Encoding utf8
    Write-Error $_
}
finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

Write-Host "`n輸出位置：$OutputFolder" -ForegroundColor Green
Write-Host "文字報告：$textReport"
Write-Host "CSV 報告 ：$csvReport"
Write-Host "JSON 報告：$jsonReport"
Write-Host "`n注意：PASS 只代表腳本可觀察到相應項目，不取代 Azure Portal IAM Check access、PIM、Deny Assignment、Azure Policy 或實際作業驗證。" -ForegroundColor Yellow
