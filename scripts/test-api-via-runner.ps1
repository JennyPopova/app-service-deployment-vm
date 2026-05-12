param(
  [Parameter(Mandatory = $true)]
  [string]$ResourceGroup,

  [Parameter(Mandatory = $true)]
  [string]$RunnerVmName,

  [Parameter(Mandatory = $true)]
  [string]$WebAppName
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

az vm show --resource-group $ResourceGroup --name $RunnerVmName -o none
if ($LASTEXITCODE -ne 0) {
  throw "Runner VM '$RunnerVmName' was not found in resource group '$ResourceGroup'."
}

$webApp = az webapp show `
  --resource-group $ResourceGroup `
  --name $WebAppName `
  -o json | ConvertFrom-Json
if (-not $webApp) {
  throw "Web app '$WebAppName' was not found in resource group '$ResourceGroup'."
}

$appHostName = $webApp.defaultHostName
if (-not $appHostName) {
  throw "Unable to resolve default hostname for web app '$WebAppName'."
}

$storageAccountName = az webapp config appsettings list `
  --resource-group $ResourceGroup `
  --name $WebAppName `
  --query "[?name=='AZURE_STORAGE_ACCOUNT'].value | [0]" -o tsv
if (-not $storageAccountName) {
  throw "Unable to resolve AZURE_STORAGE_ACCOUNT from app settings for '$WebAppName'."
}

$storageScope = az storage account show `
  --resource-group $ResourceGroup `
  --name $storageAccountName `
  --query id -o tsv
if (-not $storageScope) {
  throw "Unable to resolve storage account scope for '$storageAccountName'."
}

$runnerPrincipalId = az vm show `
  --resource-group $ResourceGroup `
  --name $RunnerVmName `
  --query identity.principalId -o tsv
if (-not $runnerPrincipalId) {
  throw "Unable to resolve system-assigned identity principalId for runner VM '$RunnerVmName'."
}

$runnerStorageRole = az role assignment list `
  --assignee $runnerPrincipalId `
  --scope $storageScope `
  --role "Storage Blob Data Reader" -o json | ConvertFrom-Json

if (@($runnerStorageRole).Count -eq 0) {
  az role assignment create `
    --assignee-object-id $runnerPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Reader" `
    --scope $storageScope | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "Failed to assign Storage Blob Data Reader role to runner VM identity '$runnerPrincipalId'."
  }
}

# Allow RBAC assignment propagation before testing data-plane access.
Start-Sleep -Seconds 10

Write-Host ""
Write-Host "==> Testing API endpoints from runner VM"
Write-Host "Target: https://$appHostName"

$testScriptTemplate = @'
set -eu
export APP_HOST='__APP_HOST__'
export STORAGE_ACCOUNT='__STORAGE_ACCOUNT__'

az login --identity --allow-no-subscriptions >/dev/null

python3 - <<'PY'
import urllib.request
import json
import sys
import subprocess
import time
from urllib.error import URLError, HTTPError

app_host = "__APP_HOST__"
storage_account = "__STORAGE_ACCOUNT__"
results = {"health": False, "pipeline": False, "storage": False, "errors": []}

def list_parquet_blobs():
  cmd = [
    "az", "storage", "blob", "list",
    "--account-name", storage_account,
    "--auth-mode", "login",
    "--container-name", "output",
    "--query", "[?ends_with(name, '.parquet')].name",
    "-o", "json",
  ]
  completed = subprocess.run(cmd, capture_output=True, text=True)
  if completed.returncode != 0:
    message = (completed.stderr or completed.stdout or "Unknown az storage error").strip()
    if "ContainerNotFound" in message or "The specified container does not exist" in message:
      return []
    raise RuntimeError(message)

  payload = completed.stdout.strip()
  if not payload:
    return []
  return json.loads(payload)

def get_baseline_with_retry(max_attempts=12, sleep_seconds=10):
  last_error = None
  for attempt in range(1, max_attempts + 1):
    try:
      return list_parquet_blobs()
    except Exception as e:
      last_error = str(e)
      if "required permissions" in last_error.lower() and attempt < max_attempts:
        print("\n  ! Waiting for RBAC propagation ({}/{}), retrying in {}s...".format(attempt, max_attempts, sleep_seconds))
        time.sleep(sleep_seconds)
        continue
      raise

  raise RuntimeError(last_error or "Unable to list baseline blobs")

# Capture baseline parquet count before triggering the pipeline
try:
  before_blobs = get_baseline_with_retry()
  print("\nBaseline output parquet blobs: {}".format(len(before_blobs)))
except Exception as e:
  print("\n  ✗ FAIL: Unable to list baseline parquet blobs: {}".format(str(e)))
  results["errors"].append("Storage baseline check failed: {}".format(str(e)))
  before_blobs = None

# Test health endpoint
print("\nTesting health endpoint: GET https://{}/".format(app_host))
try:
    response = urllib.request.urlopen("https://{}/".format(app_host), timeout=30)
    status = response.status
    body = response.read().decode('utf-8')
    print("  Response Code: {}".format(status))
    print("  Response Body: {}".format(body[:200]))
    if status == 200:
        print("  ✓ PASS: Health endpoint is responding")
        results["health"] = True
    else:
        print("  ✗ FAIL: Expected 200, got {}".format(status))
        results["errors"].append("Health endpoint returned status {}".format(status))
except HTTPError as e:
    print("  Response Code: {}".format(e.code))
    print("  ✗ FAIL: HTTP error {}".format(e.code))
    results["errors"].append("Health endpoint HTTP error: {}".format(e.code))
except URLError as e:
    print("  ✗ FAIL: Connection error: {}".format(e.reason))
    results["errors"].append("Health endpoint connection error: {}".format(e.reason))
except Exception as e:
    print("  ✗ FAIL: {}".format(str(e)))
    results["errors"].append("Health endpoint error: {}".format(str(e)))

# Test pipeline endpoint
print("\nTesting pipeline endpoint: POST https://{}/run".format(app_host))
try:
    req = urllib.request.Request("https://{}/run".format(app_host), data=b'{}', method='POST')
    req.add_header('Content-Type', 'application/json')
    response = urllib.request.urlopen(req, timeout=30)
    status = response.status
    body = response.read().decode('utf-8')
    print("  Response Code: {}".format(status))
    print("  Response Body: {}".format(body[:200]))
    if status in [200]:
        print("  ✓ PASS: Pipeline endpoint is responding")
        results["pipeline"] = True
    else:
        print("  ✗ FAIL: Unexpected status code {}".format(status))
        results["errors"].append("Pipeline endpoint returned status {}".format(status))
except HTTPError as e:
    status = e.code
    print("  Response Code: {}".format(status))
    error_body = ""
    try:
        error_body = e.read().decode('utf-8')
        print("  Response Body: {}".format(error_body[:800]))
    except:
        pass
    if status == 200:
        print("  ✓ PASS: Pipeline endpoint is responding")
        results["pipeline"] = True
    else:
        print("  ✗ FAIL: Unexpected status code {}".format(status))
        if error_body:
            results["errors"].append("Pipeline endpoint returned status {} with body: {}".format(status, error_body[:400]))
        else:
            results["errors"].append("Pipeline endpoint returned status {}".format(status))
except URLError as e:
    print("  ✗ FAIL: Connection error: {}".format(e.reason))
    results["errors"].append("Pipeline endpoint connection error: {}".format(e.reason))
except Exception as e:
    print("  ✗ FAIL: {}".format(str(e)))
    results["errors"].append("Pipeline endpoint error: {}".format(str(e)))

# Verify that /run created a new parquet file in output container
print("\nVerifying blob output: container 'output' has a newly created parquet file")
if before_blobs is None:
  print("  ✗ FAIL: Skipping post-run blob verification because baseline listing failed")
  results["errors"].append("Storage post-run verification skipped due to baseline listing failure")
else:
  try:
    after_blobs = list_parquet_blobs()
    print("  Baseline parquet blobs: {}".format(len(before_blobs)))
    print("  Current parquet blobs : {}".format(len(after_blobs)))
    if len(after_blobs) > len(before_blobs):
      print("  ✓ PASS: New parquet blob detected in output container")
      results["storage"] = True
    else:
      print("  ✗ FAIL: No new parquet blob was created")
      results["errors"].append(
        "Expected output container to gain a new parquet blob after /run, but count stayed at {}".format(len(after_blobs))
      )
  except Exception as e:
    print("  ✗ FAIL: Blob verification failed: {}".format(str(e)))
    results["errors"].append("Blob verification failed: {}".format(str(e)))

# Summary
print("\n" + "="*50)
print("Summary:")
print("  [{}] Health endpoint".format("PASS" if results["health"] else "FAIL"))
print("  [{}] Pipeline endpoint".format("PASS" if results["pipeline"] else "FAIL"))
print("  [{}] Blob output check".format("PASS" if results["storage"] else "FAIL"))

if results["health"] and results["pipeline"] and results["storage"]:
    print("\n✓ All tests passed!")
    sys.exit(0)
else:
    print("\n✗ Some tests failed")
    if results["errors"]:
        print("\nErrors:")
        for err in results["errors"]:
            print("  - {}".format(err))
    sys.exit(1)
PY
'@

$testScript = $testScriptTemplate.
  Replace('__APP_HOST__', $appHostName).
  Replace('__STORAGE_ACCOUNT__', $storageAccountName)

$tempScriptPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.sh')

try {
  [System.IO.File]::WriteAllText($tempScriptPath, $testScript, [System.Text.UTF8Encoding]::new($false))

  Write-Host ""
  Write-Host "Executing tests on runner VM..."
  Write-Host ""

  $result = az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $RunnerVmName `
    --command-id RunShellScript `
    --scripts "@$tempScriptPath" `
    -o json | ConvertFrom-Json

  # Extract stdout from the result
  if ($result.value -and @($result.value).Count -gt 0) {
    $stdout = $result.value[0].message
    Write-Host $stdout
  }

  if ($LASTEXITCODE -ne 0) {
    Write-Warning "API tests did not all pass. Check the output above for details."
    exit 1
  }
}
finally {
  if (Test-Path $tempScriptPath) {
    Remove-Item $tempScriptPath -Force
  }
}

Write-Host ""
Write-Host "API testing complete for $WebAppName"
