param(
  [Parameter(Mandatory = $true)]
  [string]$ResourceGroup,

  [Parameter(Mandatory = $true)]
  [string]$WebAppName,

  [string]$RunnerVmName = '',

  [int]$SqlPort = 1433,

  [string]$SqlServerHost = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) is required but was not found in PATH."
}

az group show --name $ResourceGroup -o none
if ($LASTEXITCODE -ne 0) {
  throw "Resource group '$ResourceGroup' was not found or is not accessible."
}

$webApp = az webapp show `
  --resource-group $ResourceGroup `
  --name $WebAppName `
  -o json | ConvertFrom-Json
if (-not $webApp) {
  throw "Web app '$WebAppName' was not found in resource group '$ResourceGroup'."
}

function Get-NsgSqlRuleSummary {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Nsg,

    [Parameter(Mandatory = $true)]
    [string]$SqlPortString
  )

  $outboundRules = @($Nsg.securityRules | Where-Object {
    $_.direction -eq 'Outbound' -and $_.access -eq 'Allow'
  })

  $hasSqlRule = $false
  $hasRedirectRule = $false
  $destinationPrefixes = @()

  foreach ($rule in $outboundRules) {
    $destPrefixList = @()
    if ($rule.destinationAddressPrefix) {
      $destPrefixList += [string]$rule.destinationAddressPrefix
    }
    if ($rule.destinationAddressPrefixes) {
      $destPrefixList += @($rule.destinationAddressPrefixes | ForEach-Object { [string]$_ })
    }

    foreach ($prefix in $destPrefixList) {
      if (-not [string]::IsNullOrWhiteSpace($prefix)) {
        $destinationPrefixes += $prefix
      }
    }

    $singlePort = if ($rule.destinationPortRange) { [string]$rule.destinationPortRange } else { '' }
    $portRanges = @()
    if ($singlePort) {
      $portRanges += $singlePort
    }
    if ($rule.destinationPortRanges) {
      $portRanges += @($rule.destinationPortRanges | ForEach-Object { [string]$_ })
    }

    if ($portRanges -contains $SqlPortString) {
      $hasSqlRule = $true
    }

    if ($portRanges -contains '11000-11999') {
      $hasRedirectRule = $true
    }
  }

  [pscustomobject]@{
    hasSqlRule = $hasSqlRule
    hasRedirectRule = $hasRedirectRule
    destinationPrefixes = @($destinationPrefixes | Sort-Object -Unique)
  }
}

function Assert-SubnetSqlEgress {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubnetId,

    [Parameter(Mandatory = $true)]
    [string]$ScopeLabel,

    [Parameter(Mandatory = $true)]
    [string]$SqlPortString
  )

  $subnet = az network vnet subnet show --ids $SubnetId -o json | ConvertFrom-Json
  if (-not $subnet) {
    throw "Unable to resolve subnet from '$SubnetId' for $ScopeLabel."
  }
  if (-not $subnet.networkSecurityGroup -or [string]::IsNullOrWhiteSpace([string]$subnet.networkSecurityGroup.id)) {
    throw "$ScopeLabel subnet '$($subnet.name)' has no network security group attached."
  }

  $nsgId = [string]$subnet.networkSecurityGroup.id
  $nsg = az network nsg show --ids $nsgId -o json | ConvertFrom-Json
  if (-not $nsg) {
    throw "Unable to resolve NSG from '$nsgId' for $ScopeLabel."
  }

  $summary = Get-NsgSqlRuleSummary -Nsg $nsg -SqlPortString $SqlPortString

  if (-not $summary.hasSqlRule) {
    throw "$ScopeLabel NSG '$($nsg.name)' is missing an outbound Allow rule for SQL port $SqlPort."
  }

  if (-not $summary.hasRedirectRule) {
    throw "$ScopeLabel NSG '$($nsg.name)' is missing an outbound Allow rule for Azure SQL redirect ports 11000-11999."
  }

  $hasExpectedPrefix = $summary.destinationPrefixes -contains 'Internet' -or $summary.destinationPrefixes -contains '*' -or $summary.destinationPrefixes -contains 'Sql'
  if (-not $hasExpectedPrefix) {
    Write-Warning "$ScopeLabel NSG '$($nsg.name)' outbound allow rules do not include destination prefix 'Sql', 'Internet', or '*'. Verify external database destination prefixes are intentional."
  }

  [pscustomobject]@{
    scope = $ScopeLabel
    subnetName = [string]$subnet.name
    nsgName = [string]$nsg.name
    destinationPrefixes = $summary.destinationPrefixes
  }
}

$appSettings = az webapp config appsettings list `
  --resource-group $ResourceGroup `
  --name $WebAppName `
  -o json | ConvertFrom-Json

$routeAllSetting = $appSettings | Where-Object { $_.name -eq 'WEBSITE_VNET_ROUTE_ALL' } | Select-Object -First 1
if (-not $routeAllSetting) {
  throw "Missing app setting WEBSITE_VNET_ROUTE_ALL on '$WebAppName'."
}
if ([string]$routeAllSetting.value -ne '1') {
  throw "WEBSITE_VNET_ROUTE_ALL must be '1' but is '$($routeAllSetting.value)'."
}

$appSubnetId = [string]$webApp.virtualNetworkSubnetId
if ([string]::IsNullOrWhiteSpace($appSubnetId)) {
  throw "Web app '$WebAppName' is not integrated with a virtual network subnet (virtualNetworkSubnetId is empty)."
}
$requiredSqlPort = [string]$SqlPort
$appCheck = Assert-SubnetSqlEgress -SubnetId $appSubnetId -ScopeLabel 'App subnet' -SqlPortString $requiredSqlPort

$runnerCheck = $null
if (-not [string]::IsNullOrWhiteSpace($RunnerVmName)) {
  $runnerVm = az vm show --resource-group $ResourceGroup --name $RunnerVmName -o json | ConvertFrom-Json
  if (-not $runnerVm) {
    throw "Runner VM '$RunnerVmName' was not found in resource group '$ResourceGroup'."
  }

  $runnerNicId = [string]$runnerVm.networkProfile.networkInterfaces[0].id
  if ([string]::IsNullOrWhiteSpace($runnerNicId)) {
    throw "Unable to resolve primary NIC for runner VM '$RunnerVmName'."
  }

  $runnerNic = az network nic show --ids $runnerNicId -o json | ConvertFrom-Json
  if (-not $runnerNic) {
    throw "Unable to resolve NIC from '$runnerNicId' for runner VM '$RunnerVmName'."
  }

  $runnerSubnetId = [string]$runnerNic.ipConfigurations[0].subnet.id
  if ([string]::IsNullOrWhiteSpace($runnerSubnetId)) {
    throw "Unable to resolve runner subnet for VM '$RunnerVmName'."
  }

  $runnerCheck = Assert-SubnetSqlEgress -SubnetId $runnerSubnetId -ScopeLabel 'Runner subnet' -SqlPortString $requiredSqlPort
}

if (-not [string]::IsNullOrWhiteSpace($SqlServerHost)) {
  try {
    $sqlIp = [System.Net.Dns]::GetHostAddresses($SqlServerHost) | Select-Object -First 1
    if ($sqlIp) {
      $ipText = $sqlIp.IPAddressToString
      if ($ipText.StartsWith('10.') -or $ipText.StartsWith('172.16.') -or $ipText.StartsWith('192.168.')) {
        Write-Warning "Resolved SQL host '$SqlServerHost' to private IP '$ipText'. Your deployment currently assumes an external/public database path."
      }
    }
  }
  catch {
    Write-Warning "DNS resolution check failed for SQL host '$SqlServerHost': $($_.Exception.Message)"
  }
}

Write-Host ''
Write-Host 'Network check passed:'
Write-Host "  - WEBSITE_VNET_ROUTE_ALL=1 is configured"
Write-Host "  - Web app is VNet integrated"
Write-Host "  - App subnet NSG '$($appCheck.nsgName)' allows outbound SQL port $SqlPort and redirect ports"
Write-Host "  - App subnet destination prefixes observed: $($appCheck.destinationPrefixes -join ', ')"
if ($runnerCheck) {
  Write-Host "  - Runner subnet NSG '$($runnerCheck.nsgName)' allows outbound SQL port $SqlPort and redirect ports"
  Write-Host "  - Runner subnet destination prefixes observed: $($runnerCheck.destinationPrefixes -join ', ')"
}
