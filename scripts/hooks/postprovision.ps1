<#
.SYNOPSIS
  postprovision hook: configures Storage RBAC and SQL DB roles for the app
  managed identity from a host that has private connectivity.

.NOTES
  Called automatically by azd up / azd provision via the hooks block in azure.yaml.
  IMPORTANT: The SQL role-assignment step (Invoke-Sqlcmd) requires that this
  script runs from a host with private connectivity and private DNS resolution
  for the SQL private endpoint. Public access is intentionally left disabled for
  all PaaS resources in this deployment.
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

$sqlServerName     = "sql-$baseName"
$sqlServerFqdn     = "$sqlServerName.database.windows.net"
$sqlDatabaseName   = 'sqldb-adventureworks'
$storageAccountName = "stapp$($baseName.Replace('-', ''))"
$appIdentityName   = "id-app-$baseName"
$runnerVmName      = "vm-runner-$baseName"

function Invoke-SqlRoleAssignmentThroughRunner {
  param(
    [string]$ResourceGroup,
    [string]$VmName,
    [string]$SqlServerFqdn,
    [string]$SqlDatabaseName,
    [string]$SqlQuery,
    [string]$SqlAccessToken
  )

  $encodedToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($SqlAccessToken))
  $encodedQuery = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($SqlQuery))
  $runnerScript = @"
set -eu
export SQL_SERVER='$SqlServerFqdn'
export SQL_DATABASE='$SqlDatabaseName'
export SQL_TOKEN_B64='$encodedToken'
export SQL_QUERY_B64='$encodedQuery'

for attempt in {1..30}; do
  if python3 -c "import pyodbc" >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

for attempt in {1..30}; do
  if getent hosts "$`SQL_SERVER" >/dev/null 2>&1; then
    if timeout 5 bash -c '</dev/tcp/'"$`SQL_SERVER"'/1433' >/dev/null 2>&1; then
      echo "SQL endpoint is reachable on attempt $`attempt"
      break
    fi
  fi

  if [ "$`attempt" -eq 30 ]; then
    echo "SQL endpoint $`SQL_SERVER:1433 did not become reachable in time" >&2
    exit 1
  fi

  sleep 10
done

python3 - <<'PY'
import base64
import os
import struct
import time
import pyodbc

raw_token = base64.b64decode(os.environ['SQL_TOKEN_B64']).decode('utf-8').encode('utf-16-le')
sql_query = base64.b64decode(os.environ['SQL_QUERY_B64']).decode('utf-8')
token_struct = struct.pack(f"<I{len(raw_token)}s", len(raw_token), raw_token)

last_error = None
for attempt in range(1, 7):
    try:
        connection = pyodbc.connect(
            "Driver={ODBC Driver 18 for SQL Server};"
            f"Server=tcp:{os.environ['SQL_SERVER']},1433;"
            f"Database={os.environ['SQL_DATABASE']};"
            "Encrypt=yes;"
            "TrustServerCertificate=no;"
            "Connection Timeout=30;",
            attrs_before={1256: token_struct},
        )

        connection.autocommit = True
        cursor = connection.cursor()
        cursor.execute(sql_query)
        connection.commit()
        connection.close()
        break
    except pyodbc.Error as exc:
        last_error = exc
        error_text = str(exc)
        if attempt < 6 and any(code in error_text for code in ("HYT00", "08001", "Login timeout expired")):
            wait_seconds = attempt * 10
            print(f"SQL connection attempt {attempt}/6 failed; retrying in {wait_seconds}s...", flush=True)
            time.sleep(wait_seconds)
            continue
        raise
else:
    raise last_error
PY
"@

  $tempRunnerScript = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.sh')
  $result = $null

  try {
    [System.IO.File]::WriteAllText($tempRunnerScript, $runnerScript, [System.Text.UTF8Encoding]::new($false))

    $result = az vm run-command invoke `
      --resource-group $ResourceGroup `
      --name $VmName `
      --command-id RunShellScript `
      --scripts "@$tempRunnerScript" `
      -o json | ConvertFrom-Json
  }
  finally {
    if (Test-Path $tempRunnerScript) { Remove-Item $tempRunnerScript -Force }
  }

  if ($LASTEXITCODE -ne 0) {
    throw "Runner VM '$VmName' failed to execute the SQL role-assignment step."
  }

  $messages = @($result.value | ForEach-Object { $_.message }) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  foreach ($message in $messages) {
    Write-Host $message
  }

  $stderrOutput = @(
    foreach ($message in $messages) {
      if ($message -match '(?s)\[stderr\]\s*(.+)$') {
        $matches[1].Trim()
      }
    }
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  if (@($stderrOutput).Count -gt 0) {
    throw "Runner VM '$VmName' reported SQL role-assignment errors: $($stderrOutput -join ' | ')"
  }
}
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

# ---- Step 2: SQL DB roles for app managed identity ------------------------------
Write-Host ""
Write-Host "==> Configuring SQL DB roles for app managed identity"
Write-Host "NOTE: SQL role assignment is executed only through runner VM '$runnerVmName'"

$token = az account get-access-token --resource https://database.windows.net -o json | ConvertFrom-Json
if (-not $token.accessToken) { throw 'Failed to acquire Azure SQL access token.' }

$sql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$appIdentityName')
  CREATE USER [$appIdentityName] FROM EXTERNAL PROVIDER WITH OBJECT_ID = '$principalId';
IF IS_ROLEMEMBER('db_datareader', '$appIdentityName') = 0
  ALTER ROLE db_datareader ADD MEMBER [$appIdentityName];
IF IS_ROLEMEMBER('db_datawriter', '$appIdentityName') = 0
  ALTER ROLE db_datawriter ADD MEMBER [$appIdentityName];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$appIdentityName')
  THROW 51000, 'SQL verification failed: database user was not created.', 1;
IF IS_ROLEMEMBER('db_datareader', '$appIdentityName') <> 1
  THROW 51000, 'SQL verification failed: db_datareader role not assigned.', 1;
IF IS_ROLEMEMBER('db_datawriter', '$appIdentityName') <> 1
  THROW 51000, 'SQL verification failed: db_datawriter role not assigned.', 1;
"@

try {
  Invoke-SqlRoleAssignmentThroughRunner `
    -ResourceGroup $resourceGroup `
    -VmName $runnerVmName `
    -SqlServerFqdn $sqlServerFqdn `
    -SqlDatabaseName $sqlDatabaseName `
    -SqlQuery $sql `
    -SqlAccessToken $token.accessToken
  Write-Host "SQL DB roles configured and verified for $appIdentityName"
}
catch {
  throw @"
Unable to configure SQL roles for the app managed identity.
Ensure the runner VM '$runnerVmName' is provisioned and healthy in the agents subnet,
and that it has private connectivity plus private DNS resolution for $sqlServerFqdn.
Original error: $($_.Exception.Message)
"@
}

# ---- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host "==> Publishing app code through private runner"
$deployScriptPath = Join-Path $PSScriptRoot '..\deploy-api-via-runner.ps1'
if (-not (Test-Path $deployScriptPath)) {
  throw "Runner deploy script not found at '$deployScriptPath'."
}

& $deployScriptPath `
  -ResourceGroup $resourceGroup `
  -RunnerVmName $runnerVmName `
  -WebAppName "app-$baseName"

if ($LASTEXITCODE -ne 0) {
  throw "Runner-based app publish failed for web app 'app-$baseName'."
}

Write-Host "App publish complete for app-$baseName"

# ---- Test API endpoints through private runner ---------------------------------
Write-Host ""
Write-Host "==> Testing API endpoints from runner"
$testScriptPath = Join-Path $PSScriptRoot '..\test-api-via-runner.ps1'
if (-not (Test-Path $testScriptPath)) {
  throw "API test script not found at '$testScriptPath'."
}

& $testScriptPath `
  -ResourceGroup $resourceGroup `
  -RunnerVmName $runnerVmName `
  -WebAppName "app-$baseName"

if ($LASTEXITCODE -ne 0) {
  Write-Warning "API tests completed with warnings. Check output above for details."
}

Write-Host ""
Write-Host "postprovision complete."
az webapp show --resource-group $resourceGroup --name ("app-" + $baseName) --query '{appName:name, defaultHostName:defaultHostName, hostNames:hostNames, state:state}' -o table
