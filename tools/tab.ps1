# Usage: powershell -NoProfile -File tools/tab.ps1 <Tab title>   e.g. "Mensola"
#   Selects a tab of the open island card through UI Automation (no mouse needed; the card must
#   be open, e.g. after tools/cursor.ps1 -1 -1 hover). Lists the tabs when the title is missing.
param([string]$Title = '')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$p = Get-Process -Name Isola -ErrorAction Stop | Select-Object -First 1
$root = [Windows.Automation.AutomationElement]::RootElement
$cond = New-Object Windows.Automation.AndCondition(
  (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)),
  (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::RadioButton)))
$tabs = $root.FindAll([Windows.Automation.TreeScope]::Descendants, $cond)
if (-not $Title) { $tabs | ForEach-Object { $_.Current.Name }; exit 0 }
$t = $tabs | Where-Object { $_.Current.Name -eq $Title } | Select-Object -First 1
if (-not $t) { Write-Output "tab '$Title' not found"; exit 1 }
$t.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
Write-Output "selected $Title"
