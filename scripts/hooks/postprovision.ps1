<#
.SYNOPSIS
  postprovision hook: configures Storage RBAC for the app
  managed identity and publishes app code from a host that has private connectivity.

.NOTES
  Called automatically by azd up / azd provision via the hooks block in azure.yaml.
  IMPORTANT: This script assumes private connectivity for app publishing because
  public network access is disabled for the web app.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RequiredEnvironmentValue {
  param(
    [string]$Name
  )

  $value = [System.Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
      $value = $null
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($value)) {
    $value = [string]$value
    $value = $value.Trim()
    $value = $value -replace '\\"', '"'
    $value = $value.Trim().Trim('"').Trim("'").TrimEnd('\\')
  }

  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "$Name env var is not set. Was preprovision hook skipped?"
  }

  return $value
}

# ---- Read env vars stamped by preprovision and azd provision outputs ------------
$resourceGroup      = Get-RequiredEnvironmentValue -Name 'AZURE_RESOURCE_GROUP'
$baseName           = Get-RequiredEnvironmentValue -Name 'BASE_NAME'
$sqlServer          = Get-RequiredEnvironmentValue -Name 'SQL_SERVER'

$storageAccountName = "stapp$($baseName.Replace('-', ''))"
$appIdentityName   = "id-app-$baseName"
$runnerVmName      = "vm-runner-$baseName"
$webAppName        = "app-$baseName"
$collectLogsScriptPath = Join-Path $PSScriptRoot '..\collect-app-logs-via-runner.ps1'
$hasFailure = $false
$failureReason = ''
# ---- Step 1: Storage RBAC — Storage Blob Data Contributor ----------------------
Write-Host ""
Write-Host "==> Assigning Storage Blob Data Contributor to app managed identity"
$principalId = az identity show `
  --resource-group $resourceGroup --name $appIdentityName `
  --query principalId -o tsv
if (-not $principalId) {
  throw "Could not resolve principalId for managed identity '$appIdentityName'."
}

$storageScope = az storage account show `
  --resource-group $resourceGroup --name $storageAccountName `
  --query id -o tsv
if (-not $storageScope) {
  throw "Could not resolve storage account '$storageAccountName'."
}

$webAppScope = az webapp show `
  --resource-group $resourceGroup --name "app-$baseName" `
  --query id -o tsv
if (-not $webAppScope) {
  throw "Could not resolve web app 'app-$baseName'."
}

$runnerPrincipalId = az vm show `
  --resource-group $resourceGroup --name $runnerVmName `
  --query identity.principalId -o tsv
if (-not $runnerPrincipalId) {
  throw "Could not resolve system-assigned identity principalId for runner VM '$runnerVmName'."
}

$existing = az role assignment list `
  --assignee $principalId --scope $storageScope `
  --role "Storage Blob Data Contributor" -o json | ConvertFrom-Json
if (@($existing).Count -eq 0) {
  az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Contributor" `
    --scope $storageScope 
  Write-Host "Assigned Storage Blob Data Contributor to $appIdentityName"
}
else {
  Write-Host "Storage RBAC already exists for $appIdentityName"
}

Write-Host ""
Write-Host "==> Assigning Website Contributor to runner managed identity"
$runnerWebsiteContributor = az role assignment list `
  --assignee $runnerPrincipalId --scope $webAppScope `
  --role "Website Contributor" -o json | ConvertFrom-Json
if (@($runnerWebsiteContributor).Count -eq 0) {
  az role assignment create `
    --assignee-object-id $runnerPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "Website Contributor" `
    --scope $webAppScope 
  Write-Host "Assigned Website Contributor to runner VM $runnerVmName"
}
else {
  Write-Host "Website Contributor already exists for runner VM $runnerVmName"
}

Write-Host ""
Write-Host "==> Assigning Storage Blob Data Contributor to runner managed identity"
$runnerStorageContributor = az role assignment list `
  --assignee $runnerPrincipalId --scope $storageScope `
  --role "Storage Blob Data Contributor" -o json | ConvertFrom-Json
if (@($runnerStorageContributor).Count -eq 0) {
  az role assignment create `
    --assignee-object-id $runnerPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Contributor" `
    --scope $storageScope
  Write-Host "Assigned Storage Blob Data Contributor to runner VM $runnerVmName"
}
else {
  Write-Host "Storage RBAC already exists for runner VM $runnerVmName"
}

# ---- Summary -------------------------------------------------------------------
try {
  Write-Host ""
  Write-Host "==> Publishing app code through private runner"
  $deployScriptPath = Join-Path $PSScriptRoot '..\deploy-api-via-runner.ps1'
  if (-not (Test-Path $deployScriptPath)) {
    throw "Runner deploy script not found at '$deployScriptPath'."
  }

  & $deployScriptPath `
    -ResourceGroup $resourceGroup `
    -RunnerVmName $runnerVmName `
    -WebAppName $webAppName

  if ($LASTEXITCODE -ne 0) {
    throw "Runner-based app publish failed for web app '$webAppName'."
  }

  Write-Host "App publish complete for $webAppName"

  # ---- Upload app config JSON through private runner ---------------------------
  Write-Host ""
  Write-Host "==> Uploading app config JSON through private runner"
  $uploadConfigScriptPath = Join-Path $PSScriptRoot '..\upload-app-config-via-runner.ps1'
  if (-not (Test-Path $uploadConfigScriptPath)) {
    throw "Runner config upload script not found at '$uploadConfigScriptPath'."
  }

  & $uploadConfigScriptPath `
    -ResourceGroup $resourceGroup `
    -RunnerVmName $runnerVmName `
    -StorageAccountName $storageAccountName

  if ($LASTEXITCODE -ne 0) {
    throw "Runner-based config upload failed for storage account '$storageAccountName'."
  }

  Write-Host "App config upload complete for storage account $storageAccountName"

  # ---- Validate network setup for public SQL access ---------------------------
  Write-Host ""
  Write-Host "==> Validating network setup"
  $networkCheckScriptPath = Join-Path $PSScriptRoot '..\check-network-setup.ps1'
  if (-not (Test-Path $networkCheckScriptPath)) {
    throw "Network check script not found at '$networkCheckScriptPath'."
  }

  & $networkCheckScriptPath `
    -ResourceGroup $resourceGroup `
    -WebAppName $webAppName `
    -RunnerVmName $runnerVmName `
    -SqlServerHost $sqlServer

  if ($LASTEXITCODE -ne 0) {
    throw "Network setup validation failed for web app '$webAppName'."
  }

  Write-Host ""
  Write-Host "==> Waiting 60 seconds before API tests to allow app provisioning to settle"
  Start-Sleep -Seconds 60

  # ---- Test API endpoints through private runner -------------------------------
  Write-Host ""
  Write-Host "==> Testing API endpoints from runner"
  $testScriptPath = Join-Path $PSScriptRoot '..\test-api-via-runner.ps1'
  if (-not (Test-Path $testScriptPath)) {
    throw "API test script not found at '$testScriptPath'."
  }

  & $testScriptPath `
    -ResourceGroup $resourceGroup `
    -RunnerVmName $runnerVmName `
    -WebAppName $webAppName

  if ($LASTEXITCODE -ne 0) {
    throw "API tests failed with exit code $LASTEXITCODE."
  }

  Write-Host ""
  Write-Host "postprovision complete."
  az webapp show --resource-group $resourceGroup --name $webAppName --query '{appName:name, defaultHostName:defaultHostName, hostNames:hostNames, state:state}' -o table
}
catch {
  $hasFailure = $true
  $failureReason = $_.Exception.Message
  throw
}
finally {
  if (-not (Test-Path $collectLogsScriptPath)) {
    Write-Warning "Log collection script not found at '$collectLogsScriptPath'. Skipping diagnostics download."
  }
  else {
    Write-Host ""
    Write-Host "==> Downloading deployment diagnostics"

    try {
      & $collectLogsScriptPath `
        -ResourceGroup $resourceGroup `
        -RunnerVmName $runnerVmName `
        -WebAppName $webAppName `
        -FailureMode:$hasFailure `
        -FailureReason $failureReason
    }
    catch {
      Write-Warning "Diagnostics download failed: $($_.Exception.Message)"
    }
  }
}
