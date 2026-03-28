# Run static GDScript checks and headless game tests for Terraceilia.
# Usage: .\tools\run_all_tests.ps1
# Optional: $env:GODOT = "C:\path\to\Godot.exe"

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Godot = if ($env:GODOT) { $env:GODOT } else { "C:\Users\antho\Projects\Games\Godot_v4.6.1-stable_win64.exe" }

if (-not (Test-Path -LiteralPath $Godot)) {
    Write-Error "Godot not found: $Godot`nSet `$env:GODOT to your Godot 4.x executable."
}

function Invoke-GodotHeadlessScene {
    param([string]$SceneResPath)
    $p = Start-Process -FilePath $Godot -ArgumentList @(
        "--headless",
        "--path", $ProjectRoot,
        $SceneResPath
    ) -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

Write-Host "Project: $ProjectRoot"
Write-Host "Godot:   $Godot"
Write-Host ""

$failed = $false

Write-Host "=== GDScript parse (--check-only --script) ===" -ForegroundColor Cyan
$gdFiles = Get-ChildItem -Path $ProjectRoot -Recurse -Filter "*.gd"
foreach ($f in $gdFiles) {
    $rel = $f.FullName.Substring($ProjectRoot.Length).TrimStart("\", "/") -replace "\\", "/"
    $res = "res://$rel"
    $p = Start-Process -FilePath $Godot -ArgumentList @(
        "--headless", "--path", $ProjectRoot, "--check-only", "--script", $res
    ) -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        Write-Host "FAIL parse: $res (exit $($p.ExitCode))" -ForegroundColor Red
        $failed = $true
    }
}
if (-not $failed) { Write-Host "All $($gdFiles.Count) scripts OK." -ForegroundColor Green }

Write-Host ""
Write-Host "=== Headless TestCareer.tscn ===" -ForegroundColor Cyan
$ec = Invoke-GodotHeadlessScene "res://scenes/TestCareer.tscn"
if ($ec -ne 0) {
    Write-Host "TestCareer FAILED (exit $ec)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestCareer OK." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Headless TestEconomy.tscn ===" -ForegroundColor Cyan
$ec2 = Invoke-GodotHeadlessScene "res://scenes/TestEconomy.tscn"
if ($ec2 -ne 0) {
    Write-Host "TestEconomy FAILED (exit $ec2)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestEconomy OK." -ForegroundColor Green
}

Write-Host ""
if ($failed) {
    Write-Host "SUITE: FAIL" -ForegroundColor Red
    exit 1
}
Write-Host "SUITE: PASS" -ForegroundColor Green
exit 0
