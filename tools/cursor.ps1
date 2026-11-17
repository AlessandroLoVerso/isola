# Usage: powershell -NoProfile -File tools/cursor.ps1 <x> <y> [hover|click|rclick|jump]
#        powershell -NoProfile -File tools/cursor.ps1 pill [hover|click|...]
#   x,y in physical pixels; "pill" (or -1 -1) = the island pill (top centre of the primary monitor).
#   Note: arguments are read from $args on purpose. With a param() block, "powershell -File"
#   takes "-1" for a parameter NAME, so "-1 -1" used to silently become 0,0 (top-left corner):
#   that, not the jump itself, is why the old "-1 -1" often didn't open the card.
#   hover: glides to the point in small steps (real WM_MOUSEMOVE sequence, like a hand would),
#          then rests there; the island only opens after the pointer rests on it, and a single
#          jump onto the pill is often not seen as "entering" the window.
#   click: glides like hover, then left-clicks.  rclick: glides, then right-clicks.
#   jump:  teleports (old behaviour).
$a = @($args)
if ($a.Count -gt 0 -and $a[0] -eq 'pill') { $X = -1; $Y = -1; $Mode = if ($a.Count -gt 1) { $a[1] } else { 'hover' } }
elseif ($a.Count -ge 2) { $X = [int]$a[0]; $Y = [int]$a[1]; $Mode = if ($a.Count -gt 2) { $a[2] } else { 'hover' } }
else { Write-Output 'usage: cursor.ps1 <x> <y> [hover|click|rclick|jump] | cursor.ps1 pill [mode]'; exit 1 }
Add-Type -AssemblyName System.Windows.Forms
Add-Type 'using System; using System.Runtime.InteropServices; public static class C { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y); [DllImport("user32.dll")] public static extern void mouse_event(int f,int x,int y,int d,IntPtr e); }'
[C]::SetProcessDPIAware() | Out-Null
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($X -lt 0) { $X = $b.X + [int]($b.Width / 2); $Y = $b.Y + 25 }

if ($Mode -eq 'jump') {
  [C]::SetCursorPos($X, $Y) | Out-Null
} else {
  $p = [System.Windows.Forms.Cursor]::Position
  $sx = $p.X; $sy = $p.Y
  # Start a bit away from the target when we're already on it, so the window sees an entry.
  if ([Math]::Abs($sx - $X) -lt 40 -and [Math]::Abs($sy - $Y) -lt 40) { $sx = $X; $sy = $Y + 220 }
  $steps = 14
  for ($i = 1; $i -le $steps; $i++) {
    $t = $i / $steps
    $e = 1 - [Math]::Pow(1 - $t, 3)   # ease-out
    [C]::SetCursorPos([int]($sx + ($X - $sx) * $e), [int]($sy + ($Y - $sy) * $e)) | Out-Null
    Start-Sleep -Milliseconds 18
  }
  # small jiggle at the end: a couple of real moves inside the target
  [C]::SetCursorPos($X + 1, $Y) | Out-Null; Start-Sleep -Milliseconds 20
  [C]::SetCursorPos($X, $Y) | Out-Null
}
if ($Mode -eq 'click') { Start-Sleep -Milliseconds 60; [C]::mouse_event(2,0,0,0,[IntPtr]::Zero); [C]::mouse_event(4,0,0,0,[IntPtr]::Zero) }
if ($Mode -eq 'rclick') { Start-Sleep -Milliseconds 60; [C]::mouse_event(8,0,0,0,[IntPtr]::Zero); [C]::mouse_event(16,0,0,0,[IntPtr]::Zero) }
