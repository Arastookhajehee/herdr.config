param([switch]$Preview)

$ErrorActionPreference = 'Stop'

# The server runs custom commands independently of the pane, so query its
# current focus rather than using the command process's inherited environment.
$snapshot = (herdr api snapshot | ConvertFrom-Json).result.snapshot
$layout = $snapshot.layouts | Where-Object tab_id -EQ $snapshot.focused_tab_id | Select-Object -First 1
if (-not $layout) { throw 'Herdr did not report a layout for the focused tab.' }

$rect = if ($layout.zoomed) {
    $layout.area
} else {
    $layout.panes | Where-Object pane_id -EQ $snapshot.focused_pane_id | Select-Object -First 1 -ExpandProperty rect
}
if (-not $rect) { throw 'Herdr did not report the focused pane rectangle.' }

# A shell custom command cannot itself access the client-side mouse. Only act
# when the local WezTerm GUI is foreground, rather than moving the mouse over
# an unrelated application or guessing which remote client invoked the key.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HerdrCursor {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
'@

# WezTerm reports physical pixels; opt out of PowerShell's DPI virtualization.
[void][HerdrCursor]::SetProcessDpiAwarenessContext([IntPtr](-4))
$window = [HerdrCursor]::GetForegroundWindow()
$processId = [uint32]0
[void][HerdrCursor]::GetWindowThreadProcessId($window, [ref]$processId)
if (-not $processId -or (Get-Process -Id $processId).ProcessName -ne 'wezterm-gui') {
    if ($Preview) { throw 'The foreground window is not WezTerm.' }
    return
}

$weztermPanes = @(wezterm cli --no-auto-start list --format json | ConvertFrom-Json)
$clientPane = $weztermPanes | Where-Object is_active | Select-Object -First 1
if (-not $clientPane -or $clientPane.size.cols -lt $layout.area.width -or $clientPane.size.rows -lt $layout.area.height) {
    throw 'WezTerm did not report the active Herdr client dimensions.'
}

$client = New-Object HerdrCursor+Rect
$origin = New-Object HerdrCursor+Point
if (-not [HerdrCursor]::GetClientRect($window, [ref]$client) -or
    -not [HerdrCursor]::ClientToScreen($window, [ref]$origin)) {
    throw 'Could not locate the WezTerm client area.'
}

$cellWidth = [double]$clientPane.size.pixel_width / $clientPane.size.cols
$cellHeight = [double]$clientPane.size.pixel_height / $clientPane.size.rows
$paddingX = ($client.Right - $client.Left - $clientPane.size.pixel_width) / 2
$paddingY = ($client.Bottom - $client.Top - $clientPane.size.pixel_height) / 2

# Herdr's pane layout is relative to its terminal area. The unused columns
# are the left sidebar; the unused row is the top tab bar (default placement).
$x = [int][Math]::Round($origin.X + $paddingX +
    ($clientPane.size.cols - $layout.area.width + $rect.x + $rect.width / 2) * $cellWidth)
$y = [int][Math]::Round($origin.Y + $paddingY +
    ($clientPane.size.rows - $layout.area.height + $rect.y + $rect.height / 2) * $cellHeight)

if ($Preview) {
    Write-Output "Mouse target: $x,$y (pane $($snapshot.focused_pane_id))"
} elseif (-not [HerdrCursor]::SetCursorPos($x, $y)) {
    throw 'Windows could not move the mouse cursor.'
}
