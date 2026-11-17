# Builds the shippable exe: publish\Isola.exe (one self-contained file, no .NET needed).
# Usage: powershell -NoProfile -File tools/publish.ps1
$root = Split-Path -Parent $PSScriptRoot
dotnet publish "$root\src\Isola\Isola.csproj" -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o "$root\publish"
if ($LASTEXITCODE -eq 0) { Get-Item "$root\publish\Isola.exe" | Select-Object FullName, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} }
