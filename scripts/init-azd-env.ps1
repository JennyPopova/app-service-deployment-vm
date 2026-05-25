<#
.SYNOPSIS
  Initializes/stamps azd environment values from deploy.config.json before running azd up.

.DESCRIPTION
  This script removes the initial azd resource-group selection prompt by setting
  AZURE_RESOURCE_GROUP (and related variables) in the selected azd environment
  before deployment starts.

.EXAMPLE
  ./scripts/init-azd-env.ps1 -EnvironmentName alfa-app
  azd up --no-prompt
#>

param(
  [string]$EnvironmentName,
  [string]$ConfigPath = (Join-Path $PSScriptRoot '..\deploy.config.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Azd {
  param(
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
  )

  $previousErrorActionPreference = $ErrorActionPreference
  $result = $null
  $exitCode = 0

  try {
    $ErrorActionPreference = 'Continue'
    $result = & azd @Arguments 2>$null
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  if ($exitCode -ne 0) {
    throw "azd $($Arguments -join ' ') failed with exit code $exitCode."
  }

  return $result
}

function Resolve-Value {
  param(
    [string]$Name,
    [object]$Config,
    [string]$Field,
    [string]$Default = '',
    [bool]$Required = $false
  )

  $value = $null

  if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $Field) {
    $candidate = [string]$Config.$Field
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      $value = $candidate.Trim()
    }
  }

  if (-not $value -and -not [string]::IsNullOrWhiteSpace($Default)) {
    $value = $Default
  }

  if (-not $value) {
    $existing = Invoke-Azd env get-value $Name
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
      $value = [string]$existing
      $value = $value.Trim()
    }
  }

  if ($Required -and -not $value) {
    throw "Required value '$Name' was not found in deploy.config.json, defaults, or current azd environment."
  }

  return $value
}

if (-not (Test-Path $ConfigPath)) {
  throw "Config file not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$baseName = Resolve-Value -Name 'BASE_NAME' -Config $config -Field 'BaseName' -Required $true
$location = Resolve-Value -Name 'AZURE_LOCATION' -Config $config -Field 'Location' -Required $true
$resourceGroupName = Resolve-Value -Name 'AZURE_RESOURCE_GROUP' -Config $config -Field 'ResourceGroupName' -Default "rg-app-service-$location"
$runnerAdminUsername = Resolve-Value -Name 'RUNNER_ADMIN_USERNAME' -Config $config -Field 'RunnerAdminUsername' -Default 'azureuser'
$sqlServer = Resolve-Value -Name 'SQL_SERVER' -Config $config -Field 'SqlServer' -Default 'sql-server-jn.database.windows.net'
$sqlDatabase = Resolve-Value -Name 'SQL_DATABASE' -Config $config -Field 'SqlDatabase' -Default 'alfa-db'
$sqlUsername = Resolve-Value -Name 'SQL_USERNAME' -Config $config -Field 'SqlUsername' -Default 'alfa_read_user'

$sqlPassword = Resolve-Value -Name 'SQL_PASSWORD' -Config $config -Field 'SqlPassword'
if (-not $sqlPassword) {
  throw "SQL_PASSWORD is required. Set 'SqlPassword' in deploy.config.json or run: azd env set SQL_PASSWORD <value>."
}

$account = az account show -o json | ConvertFrom-Json
if (-not $account.id) {
  throw 'Unable to resolve Azure subscription. Run az login and retry.'
}
$subscriptionId = $account.id

if (-not $EnvironmentName) {
  if ($env:AZURE_ENV_NAME) {
    $EnvironmentName = $env:AZURE_ENV_NAME
  }
  else {
    $EnvironmentName = "dev-$baseName-$location"
  }
}

# Ensure the target azd environment exists and is selected.
$selectSucceeded = $true
try {
  Invoke-Azd env select $EnvironmentName | Out-Null
}
catch {
  $selectSucceeded = $false
}

if (-not $selectSucceeded) {
  Write-Host "==> Creating azd environment '$EnvironmentName'"
  Invoke-Azd env new $EnvironmentName --subscription $subscriptionId --location $location --no-prompt | Out-Null
}

Write-Host "==> Ensuring resource group '$resourceGroupName' exists in '$location'"
az group create --name $resourceGroupName --location $location | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw 'az group create failed.'
}

Write-Host "==> Stamping azd env values from deploy.config.json"
Invoke-Azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Out-Null
Invoke-Azd env set AZURE_LOCATION $location | Out-Null
Invoke-Azd env set AZURE_RESOURCE_GROUP $resourceGroupName | Out-Null
Invoke-Azd env set BASE_NAME $baseName | Out-Null
Invoke-Azd env set RUNNER_ADMIN_USERNAME $runnerAdminUsername | Out-Null
Invoke-Azd env set SQL_SERVER $sqlServer | Out-Null
Invoke-Azd env set SQL_DATABASE $sqlDatabase | Out-Null
Invoke-Azd env set SQL_USERNAME $sqlUsername | Out-Null
Invoke-Azd env set SQL_PASSWORD $sqlPassword | Out-Null

Write-Host ""
Write-Host "Initialization complete."
Write-Host "  Environment   : $EnvironmentName"
Write-Host "  Subscription  : $subscriptionId"
Write-Host "  Location      : $location"
Write-Host "  Resource Group: $resourceGroupName"
Write-Host ""
Write-Host "Next command: azd up --no-prompt"
