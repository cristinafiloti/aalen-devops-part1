<#
.SYNOPSIS
    Deploy via WEBSITE_RUN_FROM_PACKAGE (mounts zip read-only, no extract).
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir   = Resolve-Path (Join-Path $scriptDir "..")
Set-Location $rootDir

if (-not (Get-Command "py" -ErrorAction SilentlyContinue)) {
    Write-Error "Python launcher (py) not found."
    exit 1
}
foreach ($cmd in @("terraform", "az")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "$cmd not found on PATH"
        exit 1
    }
}

Push-Location terraform
try {
    $rgName  = (terraform.exe output -raw resource_group_name).Trim()
    $appName = (terraform.exe output -raw app_service_name).Trim()
    $appUrl  = (terraform.exe output -raw app_service_url).Trim()
    $saName  = (terraform.exe output -raw storage_account_name).Trim()
} finally {
    Pop-Location
}

Write-Host "Resource Group : $rgName"
Write-Host "App Service    : $appName"
Write-Host "Storage Account: $saName"
Write-Host "Public URL     : $appUrl"
Write-Host ""

# ---- build artifact -------------------------------------------------------
$staging = Join-Path $env:TEMP "app-stage-$(Get-Random)"
$artifact = Join-Path $env:TEMP "app-$(Get-Random).zip"
New-Item -ItemType Directory -Path $staging | Out-Null

Write-Host "==> Creating virtual environment (Python 3.12)..."
& py -3.12 -m venv (Join-Path $staging "antenv")
if ($LASTEXITCODE -ne 0) { Write-Error "venv creation failed"; exit 1 }

$pip = Join-Path $staging "antenv\Scripts\pip.exe"
Write-Host "==> Installing requirements.txt..."
& $pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { Write-Error "pip install failed"; exit 1 }

Write-Host "==> Copying application code..."
Copy-Item -Path "app" -Destination $staging -Recurse
Copy-Item -Path "requirements.txt" -Destination $staging

Write-Host "==> Converting venv to Linux layout..."
$antenvDir       = Join-Path $staging "antenv"
$winSitePackages = Join-Path $antenvDir "Lib\site-packages"

$tempSP = Join-Path $staging "_sp_temp"
Move-Item -Path $winSitePackages -Destination $tempSP

Remove-Item (Join-Path $antenvDir "Lib")     -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $antenvDir "Scripts") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $antenvDir "pyvenv.cfg") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $antenvDir "Include") -Recurse -Force -ErrorAction SilentlyContinue

$linuxAntenvLib = Join-Path $antenvDir "lib\python3.12\site-packages"
New-Item -ItemType Directory -Path $linuxAntenvLib -Force | Out-Null
Move-Item -Path "$tempSP\*" -Destination $linuxAntenvLib -Force
Remove-Item $tempSP -Recurse -Force

Write-Host "==> Building zip artifact..."
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $artifact -Force -CompressionLevel Optimal
$sizeMb = [math]::Round((Get-Item $artifact).Length / 1MB, 1)
Write-Host "    artifact size: $sizeMb MB"

Remove-Item $staging -Recurse -Force

# ---- upload to storage as blob -------------------------------------------
$containerName = "deploys"
$blobName = "app-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"

Write-Host "==> Getting storage account key..."
$storageKey = az storage account keys list `
    --resource-group $rgName `
    --account-name $saName `
    --query "[0].value" -o tsv

Write-Host "==> Ensuring deploys container exists in $saName..."
az storage container create `
    --account-name $saName `
    --name $containerName `
    --account-key $storageKey `
    --output none 2>&1 | Out-Null

Write-Host "==> Uploading ZIP to storage account..."
az storage blob upload `
    --account-name $saName `
    --container-name $containerName `
    --name $blobName `
    --file $artifact `
    --account-key $storageKey `
    --overwrite `
    --output none

Write-Host "==> Generating SAS URL (valid 1 year)..."
$expiry = (Get-Date).AddYears(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
$sasToken = az storage blob generate-sas `
    --account-name $saName `
    --container-name $containerName `
    --name $blobName `
    --permissions r `
    --expiry $expiry `
    --account-key $storageKey `
    -o tsv

$sasUrl = "https://$saName.blob.core.windows.net/$containerName/$blobName" + "?" + $sasToken

Write-Host "==> Pointing App Service to the new package..."
az webapp config appsettings set `
    --resource-group $rgName `
    --name $appName `
    --settings "WEBSITE_RUN_FROM_PACKAGE=$sasUrl" "SCM_DO_BUILD_DURING_DEPLOYMENT=false" "ENABLE_ORYX_BUILD=false" `
    --output none

Remove-Item $artifact -Force -ErrorAction SilentlyContinue

Write-Host "==> Starting app..."
az webapp start --resource-group $rgName --name $appName --output none
Start-Sleep -Seconds 30

Write-Host ""
Write-Host "==> Waiting for /healthz to return 200..."
$healthUrl = "$appUrl/healthz"
$ok = $false
for ($i = 1; $i -le 36; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $code = $resp.StatusCode
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    }
    Write-Host "    attempt $i -> HTTP $code"
    if ($code -eq 200) { $ok = $true; break }
    Start-Sleep -Seconds 10
}

if ($ok) {
    Write-Host ""
    Write-Host "Deployment succeeded." -ForegroundColor Green
    Write-Host "Open: $appUrl"
} else {
    Write-Host ""
    Write-Error "App did not become healthy. Check: az webapp log tail -g $rgName -n $appName"
}