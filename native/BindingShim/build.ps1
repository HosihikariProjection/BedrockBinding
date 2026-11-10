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
# The carrier builds with these; they decide which standard library branches the inline
# bodies see, so they have to match the carrier's own build.
$Defines = "/DLL_PLAT_S /DLL_EXPORT /D_HAS_CXX23=1 /D_AMD64_ /DUNICODE /DWIN32_LEAN_AND_MEAN /DNDEBUG"
$Compile = "`"$ClangCl`" /nologo /std:c++20 /EHsc /MD /O2 /utf-8 /bigobj $Defines /c `"$ShimSource`" /I `"$ShimDirectory`" $IncludeArgs /Fo:`"$Object`""
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

# Prelink only imports the helpers the emitter names explicitly. An inline body can also
# call a game function directly: a template destructor, a vector algorithm helper. Those
# names cannot be known up front, so link, read the unresolved ones back from the linker's
# output, and retry with an import library that supplies them. The delayed load switch keeps
# a name the running build lacks a null thunk until it is used.
$FmtLibraries = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA (".xmake" + [IO.Path]::DirectorySeparatorChar + "packages" + [IO.Path]::DirectorySeparatorChar + "f" + [IO.Path]::DirectorySeparatorChar + "fmt")) -Recurse -Filter "fmt.lib" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending)
if ($FmtLibraries.Count -eq 0) { throw "fmt.lib was not found; the carrier headers need it." }

$LinkLog = Join-Path $OutputDirectory "shim-link.log"
function Invoke-ShimLink([string]$DirectLibrary) {
    $DirectArgument = if ($DirectLibrary) { "`"$DirectLibrary`"" } else { "" }
    $Command = "`"$ClangCl`" /nologo /LD `"$Object`" `"$BedrockRuntimeLibrary`" $DirectArgument `"$($FmtLibraries[0].FullName)`" /Fe:`"$Output`" /link /DEMANGLE:NO /DELAYLOAD:bedrock_runtime.dll delayimp.lib > `"$LinkLog`" 2>&1"
    & cmd.exe /c "`"$DevCmd`" -arch=x64 -host_arch=x64 -no_logo >nul 2>&1 && $Command"
    return $LASTEXITCODE
}

$DirectLibrary = Join-Path $PrelinkDirectory (Join-Path "lib" "bedrock_runtime_direct.lib")
$DefFile = [System.IO.Path]::ChangeExtension($DirectLibrary, ".def")
$MsvcRoot = Join-Path $VsRoot (Join-Path "VC" (Join-Path "Tools" "MSVC"))
$MsvcVersion = Get-ChildItem $MsvcRoot | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty Name
$LibExe = Join-Path $MsvcRoot (Join-Path $MsvcVersion (Join-Path "bin" (Join-Path "Hostx64" (Join-Path "x64" "lib.exe"))))

# Each retry can leave a name for the next one: resolving a symbol pulls in its own
# dependencies. Every name here is one the prelink data does not carry, so a round that
# yields none means the object is as far as import libraries can take it.
$Imported = @()
for ($Attempt = 1; $Attempt -le 8; $Attempt++) {
    if ((Invoke-ShimLink $(if ($Imported.Count) { $DirectLibrary } else { $null })) -eq 0) { break }
    # The linker reports an unresolved import as "undefined symbol: __imp_<name>". Demangling
    # is off so the message keeps the mangled spelling the def file needs; the prefix is
    # only there when the reference came through __declspec(dllimport).
    $Unresolved = @(Get-Content $LinkLog |
        Where-Object { $_ -match 'undefined symbol:' } |
        ForEach-Object { [regex]::Match($_, 'undefined symbol: (?:__imp_)?(\S+)') } |
        Where-Object { $_.Success } |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -match '^\?' -and $Imported -notcontains $_ } |
        Sort-Object -Unique)
    if ($Unresolved.Count -eq 0 -or $Attempt -eq 8) {
        Get-Content $LinkLog -Tail 20
        throw "clang-cl could not link the shim."
    }

    $Imported += $Unresolved
    $Lines = @("LIBRARY bedrock_runtime.dll", "EXPORTS") + ($Imported | ForEach-Object { "  $_" })
    [System.IO.File]::WriteAllLines($DefFile, $Lines)
    & cmd.exe /c "`"$LibExe`" /nologo `/def:`"$DefFile`" `/out:`"$DirectLibrary`" /machine:x64 > nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "lib.exe could not build the direct import library." }
    Write-Output "Link retry $Attempt with $($Imported.Count) direct import(s)."
}

Remove-Item $LinkLog -Force -ErrorAction SilentlyContinue

Remove-Item $Object -Force -ErrorAction SilentlyContinue

Write-Output "Built $Output"
