<#
.SYNOPSIS
    Build and deploy the FastAPI application to the Linux App Service.

.DESCRIPTION
    PowerShell version of deploy.sh — for Windows users who don't have Git Bash.
    Reads the Terraform outputs, packs the application as a ZIP, deploys it via
    `az webapp deploy`, and polls /healthz until it returns 200.

.NOTES
    Prerequisites:
      - Terraform was applied successfully in ../terraform
      - You are logged in with `az login` against the right subscription
      - PowerShell 5.1 or newer (built-in on Windows 10/11)

.EXAMPLE
    cd C:\path\to\part2_repo
    .\scripts\deploy.ps1
#>

$ErrorActionPreference = "Stop"

# ---- locate repo root --------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir   = Resolve-Path (Join-Path $scriptDir "..")
Set-Location $rootDir

# ---- check prerequisites -----------------------------------------------------
foreach ($cmd in @("terraform", "az")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "$cmd CLI not found on PATH"
        exit 1
    }
}

# ---- read Terraform outputs --------------------------------------------------
Push-Location terraform
try {
    $rgName  = (terraform output -raw resource_group_name).Trim()
    $appName = (terraform output -raw app_service_name).Trim()
    $appUrl  = (terraform output -raw app_service_url).Trim()
} finally {
    Pop-Location
}

Write-Host "Resource Group : $rgName"
Write-Host "App Service    : $appName"
Write-Host "Public URL     : $appUrl"
Write-Host ""

# ---- build ZIP artifact ------------------------------------------------------
$artifact = Join-Path $env:TEMP "app-$(Get-Random).zip"
Write-Host "==> Building zip artifact at $artifact"

# Stage only the files App Service needs.
$staging = Join-Path $env:TEMP "app-stage-$(Get-Random)"
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    Copy-Item -Path "app" -Destination $staging -Recurse
    Copy-Item -Path "requirements.txt" -Destination $staging

    # Remove __pycache__ folders that may have been created locally.
    Get-ChildItem -Path $staging -Recurse -Directory -Filter "__pycache__" |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $artifact -Force
    $sizeKb = [math]::Round((Get-Item $artifact).Length / 1KB, 1)
    Write-Host "    artifact size: $sizeKb KB"
} finally {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- deploy ------------------------------------------------------------------
Write-Host "==> Deploying to App Service..."
az webapp deploy `
    --resource-group $rgName `
    --name $appName `
    --src-path $artifact `
    --type zip `
    --async false `
    --restart true

# ---- smoke test --------------------------------------------------------------
Write-Host ""
Write-Host "==> Waiting for /healthz to return 200..."
$healthUrl = "$appUrl/healthz"
$ok = $false
for ($i = 1; $i -le 18; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $code = $resp.StatusCode
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    }
    Write-Host "    attempt $i -> HTTP $code"
    if ($code -eq 200) {
        $ok = $true
        break
    }
    Start-Sleep -Seconds 10
}

# ---- cleanup -----------------------------------------------------------------
Remove-Item $artifact -Force -ErrorAction SilentlyContinue

if ($ok) {
    Write-Host ""
    Write-Host "Deployment succeeded." -ForegroundColor Green
    Write-Host "Open: $appUrl"
    exit 0
} else {
    Write-Host ""
    Write-Error "App did not become healthy in time. Check logs with:"
    Write-Host "  az webapp log tail -g $rgName -n $appName"
    exit 1
}
