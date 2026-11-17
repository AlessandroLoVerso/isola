# Serializes on-screen testing between parallel agents.
# Usage: powershell -NoProfile -File tools/visual-lock.ps1 acquire <owner>
#        powershell -NoProfile -File tools/visual-lock.ps1 release <owner>
param([string]$Action, [string]$Owner)
$lock = Join-Path $env:TEMP 'isola-visual.lock'
if ($Action -eq 'acquire') {
  $deadline = (Get-Date).AddMinutes(30)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $lock) {
      $age = (Get-Date) - (Get-Item $lock).LastWriteTime
      if ($age.TotalMinutes -gt 8) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
    }
    try {
      $fs = [IO.File]::Open($lock, 'CreateNew', 'Write', 'None')
      $b = [Text.Encoding]::UTF8.GetBytes($Owner); $fs.Write($b, 0, $b.Length); $fs.Close()
      # make sure no other Isola instance is on screen
      Get-Process -Name Isola -ErrorAction SilentlyContinue | Stop-Process -Force
      Write-Output "ACQUIRED by $Owner"; exit 0
    } catch { Start-Sleep -Seconds 5 }
  }
  Write-Output "TIMEOUT"; exit 1
}
if ($Action -eq 'release') {
  Get-Process -Name Isola -ErrorAction SilentlyContinue | Stop-Process -Force
  if ((Test-Path $lock) -and ((Get-Content $lock -Raw) -eq $Owner)) { Remove-Item $lock -Force }
  Write-Output "RELEASED"; exit 0
}
