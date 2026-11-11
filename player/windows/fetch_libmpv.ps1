# Fetches the full-FFmpeg libmpv-2.dll (shinchiro/mpv-winbuild-cmake) into third_party\libmpv\ and
# verifies it. media_kit's own libmpv lacks dynaudnorm/acompressor/alimiter (volume leveling).
# The DLL (~122 MB) is too big for git, so it is fetched; windows\CMakeLists.txt calls this script.
# Offline/rebuild: drop the .7z into third_party\libmpv\ (backup copy: _build\libmpv\ in the project).
$ErrorActionPreference = 'Stop'
$Archive    = 'mpv-dev-x86_64-20261111-git-bcde6b93cc.7z'
$Url        = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261111/$Archive"
$ArchiveSha = '273C079B11EA5575822F972756F4C9A71149A5C10130353ABEB8586738938452'
$DllSha     = '88504EE5560942A955405E99DFB5971368E4CF851321F36565BF2A667271DB1B'

$dir = Join-Path $PSScriptRoot '..\third_party\libmpv'
$dll = Join-Path $dir 'libmpv-2.dll'
$a7z = Join-Path $dir $Archive
New-Item -ItemType Directory -Force $dir | Out-Null
# .NET hash: Get-FileHash can be missing when powershell.exe inherits pwsh's PSModulePath (cmake from pwsh).
function Sha256($p) { $s = [IO.File]::OpenRead($p); try { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($s) | % { $_.ToString('X2') }) } finally { $s.Dispose() } }

if ((Test-Path $dll) -and (Sha256 (Resolve-Path $dll)) -eq $DllSha) { exit 0 }

if (-not (Test-Path $a7z) -or (Sha256 (Resolve-Path $a7z)) -ne $ArchiveSha) {
  Write-Host "Downloading $Url"
  Invoke-WebRequest $Url -OutFile $a7z -UseBasicParsing
  if ((Sha256 (Resolve-Path $a7z)) -ne $ArchiveSha) { Remove-Item $a7z; throw "libmpv archive SHA256 mismatch" }
}

# cmake's tar reads 7z; use the one on PATH or the copy shipped with VS Build Tools.
$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
if (-not $cmake) { $cmake = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio\*\*\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe", "$env:ProgramFiles\Microsoft Visual Studio\*\*\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
if (-not $cmake) { throw "cmake not found (needed to extract $Archive)" }
$tmp = Join-Path $dir 'x'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $tmp | Out-Null
Push-Location $tmp
try { & $cmake -E tar xf $a7z libmpv-2.dll } finally { Pop-Location }
Move-Item (Join-Path $tmp 'libmpv-2.dll') $dll -Force
Remove-Item $tmp -Recurse -Force
if ((Sha256 (Resolve-Path $dll)) -ne $DllSha) { Remove-Item $dll; throw "libmpv-2.dll SHA256 mismatch" }
Write-Host "libmpv-2.dll ready: $dll"
