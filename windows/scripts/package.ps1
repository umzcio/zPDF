<#
.SYNOPSIS
  Builds the zPDF Windows installer (Velopack): engine runtime, self-contained publish,
  Setup.exe and update packages in windows\build\releases. Publishes nothing.
.PARAMETER SignParams
  signtool parameters for a code-signing certificate (e.g. '/a /fd sha256 /tr http://timestamp.digicert.com /td sha256 /f cert.pfx /p ...').
  Without it the installer is unsigned and Windows SmartScreen warns when it's run.
.PARAMETER Version
  Package this version instead of the project's (e.g. a 0.1.4 test build to try updating).
.PARAMETER OutputDir
  Where Setup.exe and the packages go (default windows\build\releases).
#>
param([string]$SignParams = $env:ZPDF_SIGN_PARAMS, [string]$Version = "", [string]$OutputDir = "")
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
$project = "$root\windows\zPDF.Windows\zPDF.Windows.csproj"
$version = if ($Version) { $Version } else { ([xml](Get-Content $project)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1 }
$publish = "$root\windows\build\publish"
$releases = if ($OutputDir) { $OutputDir } else { "$root\windows\build\releases" }

Write-Host "==> zPDF $version for Windows x64"
py -3 "$root\windows\scripts\prepare_runtime.py"
if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
dotnet publish $project -c Release -r win-x64 -p:Platform=x64 "-p:Version=$version" --self-contained -o $publish
if ($LASTEXITCODE) { throw "dotnet publish failed" }
if (-not (Test-Path "$publish\EngineRuntime\python\python.exe")) { throw "The engine runtime is missing from the publish folder." }

if (-not (Get-Command vpk -ErrorAction SilentlyContinue)) { dotnet tool install -g vpk --version 1.2.158 }
$pack = @('pack', '--packId', 'zPDF', '--packVersion', $version, '--packDir', $publish, '--mainExe', 'zPDF.exe',
          '--packTitle', 'zPDF', '--packAuthors', 'zPDF', '--icon', "$root\windows\zPDF.Windows\zPDF.ico", '--outputDir', $releases,
          '--channel', 'win')
if ($SignParams) { $pack += @('--signParams', $SignParams) } else { Write-Warning "No code-signing certificate: the installer is unsigned." }
vpk @pack
if ($LASTEXITCODE) { throw "vpk pack failed" }
Write-Host "==> Installer and update packages in $releases"
Get-ChildItem $releases | Format-Table Name, Length
