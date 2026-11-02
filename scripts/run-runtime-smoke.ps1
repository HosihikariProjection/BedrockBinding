param(
    [Parameter(Mandatory = $true)]
    [string]$ServerRoot,
    [string]$Configuration = "win-x64-server",
    [string]$Output = "artifacts/runtime-smoke",
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ServerRoot = (Resolve-Path $ServerRoot).Path
$Output = if ([System.IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path $RepoRoot $Output }

$ServerExecutable = Join-Path $ServerRoot "bedrock_server_mod.exe"
if (-not (Test-Path $ServerExecutable)) {
    throw "bedrock_server_mod.exe was not found under $ServerRoot."
}

dotnet build (Join-Path $RepoRoot "Hosihikari.Bindings.Bedrock.slnx") -c Release --nologo -v:q
if ($LASTEXITCODE -ne 0) {
    throw "dotnet build failed with exit code $LASTEXITCODE."
}
& (Join-Path $RepoRoot "native\BindingShim\build.ps1") -Configuration $Configuration -Output (Join-Path $Output "Hosihikari.Bindings.Bedrock.Shim.dll")
if ($LASTEXITCODE -ne 0) {
    throw "the shim build failed with exit code $LASTEXITCODE."
}

$InteropDll = Join-Path $RepoRoot "src\Hosihikari.Bindings.Bedrock.Interop\bin\Release\net10.0\Hosihikari.Bindings.Bedrock.Interop.dll"
$AbiDll = Join-Path (Split-Path $InteropDll -Parent) "Hosihikari.Bindings.Abi.dll"
$ShimDll = Join-Path $Output "Hosihikari.Bindings.Bedrock.Shim.dll"
$PluginSource = Join-Path $RepoRoot "tests\runtime-smoke"
$PluginTarget = Join-Path $ServerRoot "plugins\bedrock-smoke"
$DataTarget = Join-Path $ServerRoot "data\hosihikari\bedrock-smoke"

foreach ($file in @($InteropDll, $AbiDll, $ShimDll, (Join-Path $PluginSource "main.cs"), (Join-Path $PluginSource "manifest.json"))) {
    if (-not (Test-Path $file)) {
        throw "Runtime smoke input is missing: $file"
    }
}

if (Test-Path $PluginTarget) {
    Remove-Item $PluginTarget -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $PluginTarget | Out-Null
Copy-Item (Join-Path $PluginSource "main.cs") $PluginTarget -Force
Copy-Item (Join-Path $PluginSource "manifest.json") $PluginTarget -Force
Copy-Item $InteropDll $PluginTarget -Force
Copy-Item $AbiDll $PluginTarget -Force
Copy-Item $ShimDll $PluginTarget -Force

if (Test-Path $DataTarget) {
    Remove-Item $DataTarget -Recurse -Force
}

Set-Content -Path (Join-Path $ServerRoot "eula.txt") -Value "eula=true"
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$StandardOutput = Join-Path $Output "runtime-smoke.out.log"
$StandardError = Join-Path $Output "runtime-smoke.err.log"
Remove-Item $StandardOutput, $StandardError -Force -ErrorAction SilentlyContinue

$Process = Start-Process `
    -FilePath $ServerExecutable `
    -WorkingDirectory $ServerRoot `
    -RedirectStandardOutput $StandardOutput `
    -RedirectStandardError $StandardError `
    -PassThru `
    -NoNewWindow

$ResultPath = Join-Path $DataTarget "bedrock-smoke.txt"
$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while ([DateTime]::UtcNow -lt $Deadline) {
    if (Test-Path $ResultPath) {
        break
    }

    if ($Process.HasExited) {
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $Process.HasExited) {
    Stop-Process -Id $Process.Id -Force
    Start-Sleep -Seconds 2
}

if (-not (Test-Path $ResultPath)) {
    Get-Content $StandardOutput -Tail 80 -ErrorAction SilentlyContinue
    Get-Content $StandardError -Tail 40 -ErrorAction SilentlyContinue
    throw "Runtime smoke did not produce $ResultPath within $TimeoutSeconds seconds."
}

$Result = Get-Content $ResultPath -Raw
Write-Output $Result
if ($Result -notmatch "(?m)^result=OK\s*$") {
    Get-Content $StandardOutput -Tail 80 -ErrorAction SilentlyContinue
    throw "Runtime smoke failed; see $ResultPath."
}

Write-Output "Runtime smoke passed."
