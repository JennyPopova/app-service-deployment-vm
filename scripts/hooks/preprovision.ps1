<#
.SYNOPSIS
  preprovision hook: reads deploy.config.json and stamps all required azd env vars
  before azd provision runs.

.NOTES
  Called automatically by azd up / azd provision via the hooks block in azure.yaml.
  Run from the repo root (azd sets the working directory automatically).
#>

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
    # PowerShell 5.x surfaces native stderr as error records; azd update-check text can trip Stop.
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

function New-RandomPassword {
  param([int]$Length = 24)

  $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@$%&*-_=+'
  $bytes = New-Object byte[] $Length
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
  }
  finally {
    $rng.Dispose()
  }

  $passwordChars = for ($index = 0; $index -lt $Length; $index++) {
    $alphabet[$bytes[$index] % $alphabet.Length]
  }

  -join $passwordChars
}

# ---- Resolve config file (optional) --------------------------------------------
$configPath = Join-Path $PSScriptRoot '..\..\deploy.config.json'
$config = $null
if (Test-Path $configPath) {
  $config = Get-Content $configPath -Raw | ConvertFrom-Json
  Write-Host "==> Loaded deploy.config.json from '$configPath'"
} else {
  Write-Host "==> deploy.config.json not found - resolving values from defaults / prompts."
}

# Helper: resolve a variable from (1) config field, (2) default, (3) interactive prompt.
# If $Required and the value is still empty, throws.
function Resolve-Var {
  param(
    [string]$EnvName,
    [string]$ConfigField,
    [string]$Prompt,
    [string]$Default = '',
    [bool]$Required = $false
  )

  $value = $null
  $source = 'none'

  # 1. Config file field (authoritative when present and non-empty)
  if ($null -ne $config -and $config.PSObject.Properties.Name -contains $ConfigField) {
    $configValue = [string]$config.$ConfigField
    if (-not [string]::IsNullOrWhiteSpace($configValue)) {
      $value = $configValue
      $source = 'deploy.config.json'
    }
  }

  # 2. Default value
  if (-not $value) {
    if (-not [string]::IsNullOrWhiteSpace($Default)) {
      $value = $Default
      $source = 'default'
    }

    if (-not $value) {
      $existingEnvValue = Invoke-Azd env get-value $EnvName
      if (-not [string]::IsNullOrWhiteSpace($existingEnvValue)) {
        $value = [string]$existingEnvValue
        $source = 'existing azd env'
      }
    }

    if (-not $value -and [System.Environment]::UserInteractive) {
      # 3. Interactive prompt (only when there is a TTY)
      $value = Read-Host $Prompt
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        $source = 'prompt'
      }
    }
  }

  if ($Required -and -not $value) {
    throw "Required value '$EnvName' could not be resolved. Add it to deploy.config.json or provide it when prompted."
  }

  if ($value) {
    Write-Host "    Resolved $EnvName from $source"
  }

  return $value
}

$baseName            = Resolve-Var -EnvName 'BASE_NAME'               -ConfigField 'BaseName'           -Prompt 'Enter BaseName'           -Required $true
$location            = Resolve-Var -EnvName 'AZURE_LOCATION'          -ConfigField 'Location'           -Prompt 'Enter Azure location'     -Required $true
$resourceGroupName   = Resolve-Var -EnvName 'AZURE_RESOURCE_GROUP'    -ConfigField 'ResourceGroupName'  -Prompt 'Enter resource group name' -Default "rg-app-service-$location"
$runnerAdminUsername = Resolve-Var -EnvName 'RUNNER_ADMIN_USERNAME'   -ConfigField 'RunnerAdminUsername' -Prompt 'Enter runner admin username' -Default 'azureuser'
$sqlServer           = Resolve-Var -EnvName 'SQL_SERVER'              -ConfigField 'SqlServer'          -Prompt 'Enter SQL server host/FQDN' -Default 'sql-server-jn.database.windows.net'
$sqlDatabase         = Resolve-Var -EnvName 'SQL_DATABASE'            -ConfigField 'SqlDatabase'        -Prompt 'Enter SQL database name' -Default 'alfa-db'
$sqlUsername         = Resolve-Var -EnvName 'SQL_USERNAME'            -ConfigField 'SqlUsername'        -Prompt 'Enter SQL username' -Default 'alfa_read_user'
$sqlPassword         = Resolve-Var -EnvName 'SQL_PASSWORD'            -ConfigField 'SqlPassword'        -Prompt 'Enter SQL password' -Required $true
$runnerAdminPassword = New-RandomPassword

# Resolve subscription ID from current az login session
$account = az account show -o json | ConvertFrom-Json
if (-not $account.id) { throw 'Unable to resolve subscription. Run az login and retry.' }
$subscriptionId = $account.id

$environmentName = $env:AZURE_ENV_NAME
if (-not $environmentName) {
  $environmentName = "dev-$baseName-$location"
}

Write-Host "==> Resolution precedence: deploy.config.json -> default -> prompt"

# ---- Pre-deployment Python validation ------------------------------------------
$predeployChecksScriptPath = Join-Path $PSScriptRoot '..\run-python-predeploy-checks.ps1'
if (-not (Test-Path $predeployChecksScriptPath)) {
  throw "Pre-deploy Python checks script not found at '$predeployChecksScriptPath'."
}

Write-Host "==> Running pre-deployment Python checks"
& $predeployChecksScriptPath -AppDirectory (Join-Path $PSScriptRoot '..\..\app')
if ($LASTEXITCODE -ne 0) {
  throw "Pre-deployment Python checks failed with exit code $LASTEXITCODE."
}

# ---- Azure login check ----------------------------------------------------------
Write-Host "==> Using subscription: $subscriptionId ($($account.name))"

# ---- Create resource group (idempotent) -----------------------------------------
Write-Host "==> Creating resource group: $resourceGroupName ($location)"
az group create --name $resourceGroupName --location $location | Out-Null
if ($LASTEXITCODE -ne 0) { throw "az group create failed." }

# ---- Stamp azd env vars ---------------------------------------------------------
Write-Host "==> Stamping azd env vars for environment: $environmentName"
Invoke-Azd env set AZURE_SUBSCRIPTION_ID   $subscriptionId    | Out-Null
Invoke-Azd env set AZURE_LOCATION          $location          | Out-Null
Invoke-Azd env set AZURE_RESOURCE_GROUP    $resourceGroupName | Out-Null
Invoke-Azd env set BASE_NAME               $baseName          | Out-Null
Invoke-Azd env set RUNNER_ADMIN_USERNAME   $runnerAdminUsername | Out-Null
Invoke-Azd env set RUNNER_ADMIN_PASSWORD   $runnerAdminPassword | Out-Null
Invoke-Azd env set SQL_SERVER              $sqlServer         | Out-Null
Invoke-Azd env set SQL_DATABASE            $sqlDatabase       | Out-Null
Invoke-Azd env set SQL_USERNAME            $sqlUsername       | Out-Null
Invoke-Azd env set SQL_PASSWORD            $sqlPassword       | Out-Null

Write-Host ""
Write-Host "preprovision complete."
Write-Host "  Environment  : $environmentName"
Write-Host "  Subscription : $subscriptionId"
Write-Host "  Location     : $location"
Write-Host "  Resource Group: $resourceGroupName"
Write-Host "  BaseName     : $baseName"
Write-Host "  Runner Admin : $runnerAdminUsername"
Write-Host "  SQL Server   : $sqlServer"
Write-Host "  SQL Database : $sqlDatabase"
Write-Host "  SQL Username : $sqlUsername"
