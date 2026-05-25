param(
  [Parameter(Mandatory = $true)]
  [string]$ResourceGroup,

  [Parameter(Mandatory = $true)]
  [string]$RunnerVmName,

  [Parameter(Mandatory = $true)]
  [string]$StorageAccountName,

  [string]$ConfigDirectory = (Join-Path $PSScriptRoot '..\app-config'),

  [string]$ContainerName = 'app-config'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) is required but was not found in PATH."
}

if (-not (Test-Path $ConfigDirectory)) {
  throw "Config directory '$ConfigDirectory' does not exist."
}

$configFiles = Get-ChildItem -Path $ConfigDirectory -File -Filter '*.json'
if (@($configFiles).Count -eq 0) {
  throw "Config directory '$ConfigDirectory' has no .json files to upload."
}

az group show --name $ResourceGroup -o none
if ($LASTEXITCODE -ne 0) {
  throw "Resource group '$ResourceGroup' was not found or is not accessible."
}

az vm show --resource-group $ResourceGroup --name $RunnerVmName -o none
if ($LASTEXITCODE -ne 0) {
  throw "Runner VM '$RunnerVmName' was not found in resource group '$ResourceGroup'."
}

az storage account show --resource-group $ResourceGroup --name $StorageAccountName -o none
if ($LASTEXITCODE -ne 0) {
  throw "Storage account '$StorageAccountName' was not found in resource group '$ResourceGroup'."
}

$filePayload = @{}
foreach ($file in $configFiles) {
  $filePayload[$file.Name] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
}

$payloadJson = $filePayload | ConvertTo-Json -Compress
$payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))
$storageAccountNameBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($StorageAccountName))
$containerNameBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ContainerName))

$runnerScriptTemplate = @'
set -eu
workdir=$(mktemp -d)
export WORKDIR="$workdir"
export CONFIG_PAYLOAD_B64='__CONFIG_PAYLOAD_B64__'
export STORAGE_ACCOUNT_NAME_B64='__STORAGE_ACCOUNT_NAME_B64__'
export CONTAINER_NAME_B64='__CONTAINER_NAME_B64__'
python3 - <<'PY'
import base64
import json
import os
from pathlib import Path

workdir = Path(os.environ['WORKDIR'])
payload = json.loads(base64.b64decode(os.environ['CONFIG_PAYLOAD_B64']).decode('utf-8'))
for filename, content_b64 in payload.items():
    (workdir / filename).write_bytes(base64.b64decode(content_b64))
PY
storage_account_name=$(python3 - <<'PY'
import base64
import os
print(base64.b64decode(os.environ['STORAGE_ACCOUNT_NAME_B64']).decode('utf-8'), end='')
PY
)
container_name=$(python3 - <<'PY'
import base64
import os
print(base64.b64decode(os.environ['CONTAINER_NAME_B64']).decode('utf-8'), end='')
PY
)
if ! command -v az >/dev/null 2>&1; then
  curl -sL https://aka.ms/InstallAzureCLIDeb | bash
fi
az login --identity --allow-no-subscriptions >/dev/null
az storage container create --name "$container_name" --account-name "$storage_account_name" --auth-mode login >/dev/null
for file_path in "$workdir"/*.json; do
  file_name=$(basename "$file_path")
  az storage blob upload --account-name "$storage_account_name" --container-name "$container_name" --name "$file_name" --file "$file_path" --overwrite true --auth-mode login >/dev/null
  echo "Uploaded $file_name to $container_name"
done
rm -rf "$workdir"
'@

$runnerScript = $runnerScriptTemplate.
  Replace('__CONFIG_PAYLOAD_B64__', $payloadBase64).
  Replace('__STORAGE_ACCOUNT_NAME_B64__', $storageAccountNameBase64).
  Replace('__CONTAINER_NAME_B64__', $containerNameBase64)

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
  throw "Runner config upload failed for storage account '$StorageAccountName'."
}
