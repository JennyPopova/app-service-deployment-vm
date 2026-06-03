param(
  [Parameter(Mandatory = $true)]
  [string]$ResourceGroup,

  [Parameter(Mandatory = $true)]
  [string]$WebAppName,

  [Parameter(Mandatory = $true)]
  [string]$RunnerVmName,

  [string]$OutputRoot = (Join-Path $PSScriptRoot '..\output\logs'),

  [switch]$FailureMode,

  [string]$FailureReason = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) is required but was not found in PATH."
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$runOutputDir = Join-Path $OutputRoot $timestamp
New-Item -ItemType Directory -Path $runOutputDir -Force | Out-Null
$summaryPath = Join-Path $runOutputDir 'summary.txt'

$summary = [ordered]@{
  timestamp_utc = $timestamp
  resource_group = $ResourceGroup
  web_app_name = $WebAppName
  runner_vm_name = $RunnerVmName
  failure_mode = $FailureMode.IsPresent
  failure_reason = $FailureReason
  app_state = ''
  app_availability_state = ''
  app_enabled = ''
  app_default_host_name = ''
  app_status_artifact = 'webapp-status.json'
  app_service_log_bundle_downloaded = ''
  app_service_log_bundle_path = 'app-service-logs.zip'
}

function Write-Note {
  param([string]$Message)
  Write-Host $Message
}

function Invoke-AzCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Description,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [switch]$AllowFailure
  )

  Write-Note "==> $Description"
  $text = ''
  $previousErrorActionPreference = $ErrorActionPreference
  $hasNativeErrorPreference = $null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)
  $previousNativeErrorPreference = $false

  if ($hasNativeErrorPreference) {
    $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }

  $ErrorActionPreference = 'Continue'
  try {
    $text = (& az @Arguments 2>&1 | Out-String)
  }
  catch {
    if ($text) {
      $text = "$text`r`n$($_.Exception.Message)"
    }
    else {
      $text = $_.Exception.Message
    }
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($hasNativeErrorPreference) {
      $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    }
  }

  $exitCode = $LASTEXITCODE
  Set-Content -Path $OutputFile -Value $text -Encoding UTF8

  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "Failed while running: az $($Arguments -join ' ')"
  }
}

function Invoke-RunnerCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptContent,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [switch]$AllowFailure
  )

  $tempScriptPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.sh')

  try {
    [System.IO.File]::WriteAllText($tempScriptPath, $ScriptContent, [System.Text.UTF8Encoding]::new($false))

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $resultJson = ''
    try {
      $resultJson = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $RunnerVmName `
        --command-id RunShellScript `
        --scripts "@$tempScriptPath" `
        -o json 2>&1 | Out-String
    }
    catch {
      if ($resultJson) {
        $resultJson = "$resultJson`r`n$($_.Exception.Message)"
      }
      else {
        $resultJson = $_.Exception.Message
      }
    }
    finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }

    $exitCode = $LASTEXITCODE
    $result = $null
    if ($exitCode -eq 0) {
      $result = $resultJson | ConvertFrom-Json
    }

    $stdout = ''
    if ($result -and $result.value -and @($result.value).Count -gt 0) {
      $stdout = [string]$result.value[0].message
    }
    elseif ($resultJson) {
      $stdout = [string]$resultJson
    }

    Set-Content -Path $OutputFile -Value $stdout -Encoding UTF8

    if ($exitCode -ne 0 -and -not $AllowFailure) {
      throw "Runner command failed while collecting logs."
    }
  }
  finally {
    if (Test-Path $tempScriptPath) {
      Remove-Item $tempScriptPath -Force
    }
  }
}

Write-Note "Saving deployment diagnostics to $runOutputDir"

$webAppJsonPath = Join-Path $runOutputDir 'webapp-show.json'
Invoke-AzCapture -Description 'Collect web app resource details' -Arguments @('webapp', 'show', '--resource-group', $ResourceGroup, '--name', $WebAppName, '-o', 'json') -OutputFile $webAppJsonPath

$webApp = Get-Content -Path $webAppJsonPath -Raw | ConvertFrom-Json
$appHostName = [string]$webApp.defaultHostName

$summary.app_state = [string]$webApp.state
$summary.app_availability_state = [string]$webApp.availabilityState
$summary.app_enabled = [string]$webApp.enabled
$summary.app_default_host_name = $appHostName

$webAppStatusPath = Join-Path $runOutputDir 'webapp-status.json'
$webAppStatus = [ordered]@{
  timestamp_utc = $timestamp
  resource_group = $ResourceGroup
  web_app_name = $WebAppName
  state = [string]$webApp.state
  availabilityState = [string]$webApp.availabilityState
  enabled = $webApp.enabled
  defaultHostName = $appHostName
}
$webAppStatus | ConvertTo-Json -Depth 4 | Set-Content -Path $webAppStatusPath -Encoding UTF8

$summaryLines = @()
foreach ($item in $summary.GetEnumerator()) {
  $summaryLines += "$($item.Key)=$($item.Value)"
}
Set-Content -Path $summaryPath -Value $summaryLines -Encoding UTF8

Invoke-AzCapture -Description 'Collect web app configuration' -Arguments @('webapp', 'config', 'show', '--resource-group', $ResourceGroup, '--name', $WebAppName, '-o', 'json') -OutputFile (Join-Path $runOutputDir 'webapp-config.json')
Invoke-AzCapture -Description 'Collect web app app settings' -Arguments @('webapp', 'config', 'appsettings', 'list', '--resource-group', $ResourceGroup, '--name', $WebAppName, '-o', 'json') -OutputFile (Join-Path $runOutputDir 'webapp-appsettings.json')
$webAppDeploymentsPath = Join-Path $runOutputDir 'webapp-deployments.json'
Invoke-AzCapture -Description 'Collect web app deployment history' -Arguments @('webapp', 'log', 'deployment', 'list', '--resource-group', $ResourceGroup, '--name', $WebAppName, '-o', 'json') -OutputFile $webAppDeploymentsPath -AllowFailure
if (Select-String -Path $webAppDeploymentsPath -Pattern 'Ip Forbidden' -SimpleMatch -Quiet) {
  Write-Warning 'Skipped web app deployment history: SCM endpoint is restricted by IP access rules (expected in private deployments).'
}

$appLogsZipPath = Join-Path $runOutputDir 'app-service-logs.zip'
Write-Note '==> Download App Service log bundle'
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$logDownloadText = ''
try {
  $logDownloadText = (& az webapp log download --resource-group $ResourceGroup --name $WebAppName --log-file $appLogsZipPath 2>&1 | Out-String)
}
catch {
  if ($logDownloadText) {
    $logDownloadText = "$logDownloadText`r`n$($_.Exception.Message)"
  }
  else {
    $logDownloadText = $_.Exception.Message
  }
}
finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
Set-Content -Path (Join-Path $runOutputDir 'webapp-log-download.txt') -Value $logDownloadText -Encoding UTF8
if ($LASTEXITCODE -ne 0) {
  $summary.app_service_log_bundle_downloaded = 'false'
  Write-Warning 'Failed to download app service log bundle. See webapp-log-download.txt for details.'
}
else {
  $summary.app_service_log_bundle_downloaded = 'true'
}

$runnerHttpScriptTemplate = @'
set -eu
host='__APP_HOST__'
scm_host='${host/.azurewebsites.net/.scm.azurewebsites.net}'

echo '== UTC timestamp =='
date -u || true

echo ''
echo '== Health endpoint =='
curl -k -i --max-time 30 "https://$host/" || true

echo ''
echo '== SCM detectors endpoint =='
curl -k -i --max-time 30 "https://$scm_host/detectors" || true
'@
$runnerHttpScript = $runnerHttpScriptTemplate.Replace('__APP_HOST__', $appHostName)
Invoke-RunnerCapture -ScriptContent $runnerHttpScript -OutputFile (Join-Path $runOutputDir 'runner-http-checks.txt') -AllowFailure

if ($FailureMode.IsPresent) {
  Write-Note '==> Failure mode enabled: collecting extended diagnostics'

  Invoke-AzCapture -Description 'Collect recent activity log events for the resource group' -Arguments @('monitor', 'activity-log', 'list', '--resource-group', $ResourceGroup, '--offset', '2h', '--max-events', '200', '-o', 'json') -OutputFile (Join-Path $runOutputDir 'activity-log-last-2h.json') -AllowFailure

  $extendedRunnerScriptTemplate = @'
set -eu
host='__APP_HOST__'

echo '== DNS lookup for app host =='
getent hosts "$host" || true

echo ''
echo '== Curl with verbose output =='
curl -k -v --max-time 30 "https://$host/" || true
'@
  $extendedRunnerScript = $extendedRunnerScriptTemplate.Replace('__APP_HOST__', $appHostName)
  Invoke-RunnerCapture -ScriptContent $extendedRunnerScript -OutputFile (Join-Path $runOutputDir 'runner-extended-diagnostics.txt') -AllowFailure
}

$summaryLines = @()
foreach ($item in $summary.GetEnumerator()) {
  $summaryLines += "$($item.Key)=$($item.Value)"
}
Set-Content -Path $summaryPath -Value $summaryLines -Encoding UTF8

Write-Host ''
Write-Host "Log collection complete. Artifacts saved to: $runOutputDir"
