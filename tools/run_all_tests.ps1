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
    param([string]$SceneResPath, [string[]]$ExtraArgs = @())
    $p = Start-Process -FilePath $Godot -ArgumentList (@(
        "--headless",
        "--path", $ProjectRoot,
        $SceneResPath
    ) + $ExtraArgs) -Wait -PassThru -NoNewWindow
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
Write-Host "=== Headless TestTradeMigration.tscn ===" -ForegroundColor Cyan
$ec = Invoke-GodotHeadlessScene "res://scenes/TestTradeMigration.tscn"
if ($ec -ne 0) {
    Write-Host "TestTradeMigration FAILED (exit $ec)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestTradeMigration OK." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Headless TestSurvival.tscn (30 days, real game at 10x) ===" -ForegroundColor Cyan
$ec = Invoke-GodotHeadlessScene "res://scenes/TestSurvival.tscn" @("--", "--days=30")
if ($ec -ne 0) {
    Write-Host "TestSurvival FAILED (exit $ec)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestSurvival OK." -ForegroundColor Green
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
Write-Host "=== Headless TestFeatures.tscn (each feature set up and checked) ===" -ForegroundColor Cyan
$ec3 = Invoke-GodotHeadlessScene "res://scenes/TestFeatures.tscn"
if ($ec3 -ne 0) {
    Write-Host "TestFeatures FAILED (exit $ec3)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestFeatures OK." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Headless TestShocks.tscn (troubles set off on purpose, recovery checked) ===" -ForegroundColor Cyan
$ec4 = Invoke-GodotHeadlessScene "res://scenes/TestShocks.tscn"
if ($ec4 -ne 0) {
    Write-Host "TestShocks FAILED (exit $ec4)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestShocks OK." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Headless TestDevMode.tscn (dev mode: settings, starting town, menu) ===" -ForegroundColor Cyan
$ec5 = Invoke-GodotHeadlessScene "res://scenes/TestDevMode.tscn"
if ($ec5 -ne 0) {
    Write-Host "TestDevMode FAILED (exit $ec5)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestDevMode OK." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Headless TestLogPanel.tscn (Event Log shows the right text without redrawing every frame) ===" -ForegroundColor Cyan
$ec6 = Invoke-GodotHeadlessScene "res://scenes/TestLogPanel.tscn"
if ($ec6 -ne 0) {
    Write-Host "TestLogPanel FAILED (exit $ec6)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestLogPanel OK." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Headless TestMarket.tscn (price rules, shortage, books) ===" -ForegroundColor Cyan
$ec7 = Invoke-GodotHeadlessScene "res://scenes/TestMarket.tscn"
if ($ec7 -ne 0) {
    Write-Host "TestMarket FAILED (exit $ec7)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestMarket OK." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Headless TestRecovery.tscn (a town gets its farmer back) ===" -ForegroundColor Cyan
$ec8 = Invoke-GodotHeadlessScene "res://scenes/TestRecovery.tscn"
if ($ec8 -ne 0) {
    Write-Host "TestRecovery FAILED (exit $ec8)" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "TestRecovery OK." -ForegroundColor Green
}

Write-Host ""
if ($failed) {
    Write-Host "SUITE: FAIL" -ForegroundColor Red
    exit 1
}
Write-Host "SUITE: PASS" -ForegroundColor Green
exit 0
