param(
    [string]$Configuration = "win-x64-server",
    [string]$Surface = "bedrock",
    [string]$ShimSource = "",
    [string]$Output = "artifacts/native/Hosihikari.Bindings.Bedrock.Shim.dll",
    [string]$LeviLaminaRoot = "",
    [string]$BedrockRuntimeData = "",
    [string]$PrelinkExe = "",
    [string[]]$AdditionalIncludePath = @()
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ([string]::IsNullOrWhiteSpace($LeviLaminaRoot)) {
    $LeviLaminaRoot = Join-Path $RepoRoot "..\Third\LeviLamina"
}
$LeviLaminaRoot = (Resolve-Path $LeviLaminaRoot).Path
$Output = if ([System.IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path $RepoRoot $Output }
$ShimDirectory = Join-Path $PSScriptRoot "generated\$Configuration\$Surface"
if ([string]::IsNullOrWhiteSpace($ShimSource)) {
    $ShimSource = Join-Path $ShimDirectory "binding_table.cpp"
}
$ShimSource = (Resolve-Path $ShimSource).Path
if (-not (Test-Path (Join-Path $ShimDirectory "hosihikari_abi.h"))) {
    throw "Generated BindingShim sources are missing under $ShimDirectory."
}

$OutputDirectory = Split-Path $Output -Parent
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$VsRoot = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $VsRoot) { throw "Visual Studio with the C++ toolchain was not found." }
$DevCmd = Join-Path $VsRoot "Common7\Tools\VsDevCmd.bat"

# The shim calls inline member bodies of template instances, so it needs the carrier
# headers and the packages the carrier builds with. The paths mirror those the IR
# frontend used; nothing else in the shim includes game headers.
$Includes = @(
    "-I", (Join-Path $LeviLaminaRoot "src"),
    "-I", (Join-Path $LeviLaminaRoot "src\mc"),
    "-I", (Join-Path $LeviLaminaRoot "src-server")
)
# entt is pinned as a source checkout locally, but CI only has the xmake package of it.
$EnttRoot = "$env:LOCALAPPDATA\Temp\entt-41aab92\src"
if (Test-Path $EnttRoot) {
    $Includes += @("-I", $EnttRoot)
}
foreach ($package in Get-ChildItem "$env:LOCALAPPDATA\.xmake\packages" -Recurse -Directory -Filter "include" -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-Path $EnttRoot) -or $_.FullName -notmatch '\\e\\entt\\' } | Sort-Object FullName -Unique) {
    $Includes += @("-I", $package.FullName)
}
foreach ($nested in @("magic_enum", "stb", "concurrentqueue\moodycamel")) {
    foreach ($package in Get-ChildItem "$env:LOCALAPPDATA\.xmake\packages" -Recurse -Directory -Filter "include" -ErrorAction SilentlyContinue) {
        $candidate = Join-Path $package.FullName $nested
        if (Test-Path $candidate) { $Includes += @("-I", $candidate) }
    }
}
foreach ($additional in $AdditionalIncludePath) {
    $Includes += @("-I", (Resolve-Path $additional).Path)
}
$IncludeArgs = ($Includes | ForEach-Object { "-I `"$_`"" }) -join " "

# clang-cl, not cl: the carrier headers the inline bodies come from are not all accepted
# by MSVC (a deleted copy assignment under C++20, an injected-class-name in a template).
$ClangCl = if ($env:HOSIHIKARI_CLANG_CL) {
    $env:HOSIHIKARI_CLANG_CL
} else {
    Join-Path "C:\Program Files\LLVM" "bin\clang-cl.exe"
}
if (-not (Test-Path $ClangCl)) { throw "clang-cl was not found at $ClangCl." }
# Inline bodies call game functions, so compile once and let prelink turn the decorated
# imports into a delay-loaded import library against the run-time data. Prelink skips names
# the data does not have; those stay unresolved imports of bedrock_runtime.dll either way.
$Object = [System.IO.Path]::ChangeExtension($Output, ".obj")
$Compile = "`"$ClangCl`" /nologo /std:c++20 /EHsc /MD /O2 /utf-8 /bigobj /c `"$ShimSource`" /I `"$ShimDirectory`" $IncludeArgs /Fo:`"$Object`""
& cmd.exe /c "`"$DevCmd`" -arch=x64 -host_arch=x64 -no_logo >nul 2>&1 && $Compile"
if ($LASTEXITCODE -ne 0) { throw "clang-cl could not compile the shim." }

if ([string]::IsNullOrWhiteSpace($BedrockRuntimeData)) {
    $Data = Get-ChildItem "$env:LOCALAPPDATA\.xmake\packages\b\bedrockdata" -Recurse -Filter bedrock_runtime_data -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $Data) { throw "bedrock_runtime_data was not found; pass -BedrockRuntimeData." }
    $BedrockRuntimeData = $Data.FullName
} else {
    # prelink runs from the caller's directory; an explicit relative path must survive that.
    $BedrockRuntimeData = (Resolve-Path $BedrockRuntimeData).Path
}
if ([string]::IsNullOrWhiteSpace($PrelinkExe)) {
    $Prelink = Get-ChildItem "$env:LOCALAPPDATA\.xmake\packages\p\prelink" -Recurse -Filter prelink.exe -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $Prelink) { throw "prelink.exe was not found; pass -PrelinkExe." }
    $PrelinkExe = $Prelink.FullName
}

$PrelinkDirectory = Join-Path $OutputDirectory "prelink"
if (Test-Path $PrelinkDirectory) { Remove-Item $PrelinkDirectory -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $PrelinkDirectory "lib") | Out-Null
& $PrelinkExe "server-windows-x64" $PrelinkDirectory $BedrockRuntimeData $Object
if ($LASTEXITCODE -ne 0) { throw "prelink exited with $LASTEXITCODE." }

$BedrockRuntimeLibrary = Join-Path $PrelinkDirectory "lib\bedrock_runtime_api.lib"
$Link = "`"$ClangCl`" /nologo /LD `"$Object`" `"$BedrockRuntimeLibrary`" /Fe:`"$Output`" /link /DELAYLOAD:bedrock_runtime.dll delayimp.lib"
& cmd.exe /c "`"$DevCmd`" -arch=x64 -host_arch=x64 -no_logo >nul 2>&1 && $Link"
if ($LASTEXITCODE -ne 0) { throw "clang-cl could not link the shim." }
Remove-Item $Object -Force -ErrorAction SilentlyContinue

Write-Output "Built $Output"
