param(
  [Parameter(Mandatory = $true)]
  [string]$ResourceGroup,

  [Parameter(Mandatory = $true)]
  [string]$RunnerVmName,

  [Parameter(Mandatory = $true)]
  [string]$WebAppName,

  [string]$AppDirectory = (Join-Path $PSScriptRoot '..\app')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) is required but was not found in PATH."
}

if (-not (Test-Path $AppDirectory)) {
  throw "App directory '$AppDirectory' does not exist."
}

$appFiles = Get-ChildItem -Path $AppDirectory -Recurse -File
if (@($appFiles).Count -eq 0) {
  throw "App directory '$AppDirectory' has no files to deploy."
}

az group show --name $ResourceGroup -o none
if ($LASTEXITCODE -ne 0) {
  throw "Resource group '$ResourceGroup' was not found or is not accessible."
}

az vm show --resource-group $ResourceGroup --name $RunnerVmName -o none
if ($LASTEXITCODE -ne 0) {
  throw "Runner VM '$RunnerVmName' was not found in resource group '$ResourceGroup'."
}

az webapp show --resource-group $ResourceGroup --name $WebAppName -o none
if ($LASTEXITCODE -ne 0) {
  throw "Web app '$WebAppName' was not found in resource group '$ResourceGroup'."
}

$webAppResourceId = az webapp show `
  --resource-group $ResourceGroup `
  --name $WebAppName `
  --query id -o tsv
if (-not $webAppResourceId) {
  throw "Unable to resolve the resource ID for web app '$WebAppName'."
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$tempZipPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.zip')
$baseDirectory = [System.IO.Path]::GetFullPath($AppDirectory)
[System.IO.File]::Delete($tempZipPath)

try {
  $zipArchive = [System.IO.Compression.ZipFile]::Open($tempZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($file in $appFiles) {
      $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
      $entryName = $fullPath.Substring($baseDirectory.Length).TrimStart('\', '/')
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $fullPath, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
  }
  finally {
    $zipArchive.Dispose()
  }

  $appZipBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($tempZipPath))
}
finally {
  if (Test-Path $tempZipPath) {
    Remove-Item $tempZipPath -Force
  }
}

$webAppResourceIdBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($webAppResourceId))

$runnerScriptTemplate = @'
set -eu
workdir=$(mktemp -d)
export WORKDIR="$workdir"
export APP_ZIP_B64='__APP_ZIP_B64__'
export WEB_APP_RESOURCE_ID_B64='__WEB_APP_RESOURCE_ID_B64__'
python3 - <<'PY'
import base64
import os
from pathlib import Path

workdir = Path(os.environ['WORKDIR'])
zip_path = workdir / 'app.zip'
zip_path.write_bytes(base64.b64decode(os.environ['APP_ZIP_B64']))
PY
web_app_resource_id=$(python3 - <<'PY'
import base64
import os
print(base64.b64decode(os.environ['WEB_APP_RESOURCE_ID_B64']).decode('utf-8'), end='')
PY
)
if ! command -v az >/dev/null 2>&1; then
  curl -sL https://aka.ms/InstallAzureCLIDeb | bash
fi
az login --identity --allow-no-subscriptions >/dev/null
az webapp deploy --ids "$web_app_resource_id" --src-path "$workdir/app.zip" --type zip --async true --track-status false >/dev/null
rm -rf "$workdir"
'@

$runnerScript = $runnerScriptTemplate.
  Replace('__APP_ZIP_B64__', $appZipBase64).
  Replace('__WEB_APP_RESOURCE_ID_B64__', $webAppResourceIdBase64)

$tempScriptPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.sh')

try {
  [System.IO.File]::WriteAllText($tempScriptPath, $runnerScript, [System.Text.UTF8Encoding]::new($false))

  az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $RunnerVmName `
    --command-id RunShellScript `
    --scripts "@$tempScriptPath"
}
finally {
  if (Test-Path $tempScriptPath) {
    Remove-Item $tempScriptPath -Force
  }
}

if ($LASTEXITCODE -ne 0) {
  throw "Runner deployment failed for web app '$WebAppName'."
}