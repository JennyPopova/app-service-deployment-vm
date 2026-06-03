param(
  [string]$AppDirectory = (Join-Path $PSScriptRoot '..\app'),
  [bool]$InstallDependencies = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PythonCommand {
  if (Get-Command python -ErrorAction SilentlyContinue) {
    return ,@('python')
  }

  if (Get-Command py -ErrorAction SilentlyContinue) {
    return ,@('py', '-3')
  }

  throw "Python was not found in PATH. Install Python 3 and retry."
}

$pythonCommand = @(Get-PythonCommand)
$pythonExe = $pythonCommand[0]
$pythonPrefixArgs = @()
if ($pythonCommand.Count -gt 1) {
  $pythonPrefixArgs = $pythonCommand[1..($pythonCommand.Count - 1)]
}

function Invoke-Python {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [string]$Description = 'python command'
  )

  Write-Host "==> $Description"
  & $pythonExe @pythonPrefixArgs @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Python command failed: $Description"
  }
}

function Invoke-PythonScriptFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptContent,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $tempScriptPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.py')

  try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempScriptPath, $ScriptContent, $utf8NoBom)
    $allArgs = @($tempScriptPath) + $Arguments
    Invoke-Python -Description $Description -Arguments $allArgs
  }
  finally {
    if (Test-Path $tempScriptPath) {
      Remove-Item $tempScriptPath -Force
    }
  }
}

$appPath = [System.IO.Path]::GetFullPath($AppDirectory)
if (-not (Test-Path $appPath)) {
  throw "App directory '$appPath' does not exist."
}

$requirementsPath = Join-Path $appPath 'requirements.txt'
if ($InstallDependencies -and (Test-Path $requirementsPath)) {
  Invoke-Python -Description 'Install Python dependencies from app/requirements.txt' -Arguments @('-m', 'pip', 'install', '--disable-pip-version-check', '-r', $requirementsPath)
} else {
  Write-Host "==> Skipping dependency installation (requirements.txt missing or disabled)."
}

$pythonFiles = Get-ChildItem -Path $appPath -Recurse -File -Filter '*.py' | Select-Object -ExpandProperty FullName
if (@($pythonFiles).Count -eq 0) {
  throw "No Python files found under '$appPath'."
}

$pythonFileListPath = [System.IO.Path]::GetTempFileName()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($pythonFileListPath, $pythonFiles, $utf8NoBom)

$compileScript = @'
import py_compile
import sys
from pathlib import Path

list_path = Path(sys.argv[1])
paths = [line.strip() for line in list_path.read_text(encoding="utf-8").splitlines() if line.strip()]
errors = []
for path in paths:
    try:
        py_compile.compile(path, doraise=True)
    except Exception as exc:
        errors.append(f"{path}: {exc}")

if errors:
    print("Python compile checks failed:")
    for item in errors:
        print(f"- {item}")
    raise SystemExit(1)

print(f"Compile checks passed for {len(paths)} file(s).")
'@
try {
  Invoke-PythonScriptFile -Description 'Run syntax compile checks for app Python files' -ScriptContent $compileScript -Arguments @($pythonFileListPath)
}
finally {
  if (Test-Path $pythonFileListPath) {
    Remove-Item $pythonFileListPath -Force
  }
}

$smokeScript = @'
import pathlib
import sys

app_dir = pathlib.Path(sys.argv[1]).resolve()
sys.path.insert(0, str(app_dir))

modules = ["app", "db_to_parquet"]
errors = []

for module_name in modules:
    try:
        __import__(module_name)
    except Exception as exc:
        errors.append(f"{module_name}: {exc}")

if errors:
    print("Import smoke checks failed:")
    for item in errors:
        print(f"- {item}")
    raise SystemExit(1)

print("Import smoke checks passed for app and db_to_parquet modules.")
'@
Invoke-PythonScriptFile -Description 'Run import smoke checks for application modules' -ScriptContent $smokeScript -Arguments @($appPath)

Write-Host ''
Write-Host 'Python pre-deployment checks completed successfully.'
