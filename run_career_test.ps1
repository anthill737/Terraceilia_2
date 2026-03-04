# Career switching validation test runner
# Runs the headless test scene for 36 days and validates career logs.
#
# Usage:
#   .\run_career_test.ps1
#   .\run_career_test.ps1 -GodotPath "C:\path\to\Godot.exe"

param(
    [string]$GodotPath = ""
)

$projectPath = $PSScriptRoot

Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Career Switching Validation Test" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Find Godot executable
if ($GodotPath -eq "") {
    $searchPaths = @(
        "C:\Program Files\Godot\Godot_v4*\Godot*.exe",
        "C:\Program Files (x86)\Godot\Godot_v4*\Godot*.exe",
        "$env:LOCALAPPDATA\Godot\Godot*.exe",
        "$env:LOCALAPPDATA\Programs\Godot\Godot*.exe",
        "C:\Godot\Godot*.exe",
        "$env:USERPROFILE\Godot\Godot*.exe",
        "$env:USERPROFILE\scoop\apps\godot*\*\Godot*.exe"
    )

    foreach ($pattern in $searchPaths) {
        $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $GodotPath = $found.FullName
            break
        }
    }

    # Try PATH
    if ($GodotPath -eq "") {
        $inPath = Get-Command "godot" -ErrorAction SilentlyContinue
        if ($inPath) {
            $GodotPath = $inPath.Source
        }
    }
}

if ($GodotPath -eq "" -or -not (Test-Path $GodotPath)) {
    Write-Host "ERROR: Godot executable not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Please specify the path manually:" -ForegroundColor Yellow
    Write-Host "  .\run_career_test.ps1 -GodotPath ""C:\path\to\Godot.exe""" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Or from the Godot Editor:" -ForegroundColor Yellow
    Write-Host "  1. Open scenes/TestCareer.tscn" -ForegroundColor Yellow
    Write-Host "  2. Press F6 (Run Current Scene)" -ForegroundColor Yellow
    exit 1
}

Write-Host "Godot: $GodotPath" -ForegroundColor Gray
Write-Host "Project: $projectPath" -ForegroundColor Gray
Write-Host ""
Write-Host "Running headless test (36 game days)..." -ForegroundColor White

$outputFile = Join-Path $projectPath "test_career_output.txt"
$errorFile = Join-Path $projectPath "test_career_errors.txt"

& $GodotPath --headless --path "$projectPath" "res://scenes/TestCareer.tscn" 2>$errorFile | Tee-Object -FilePath $outputFile

$exitCode = $LASTEXITCODE

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "TEST PASSED" -ForegroundColor Green
} else {
    Write-Host "TEST FAILED (exit code: $exitCode)" -ForegroundColor Red
}

# Show errors if any
$errors = Get-Content $errorFile -ErrorAction SilentlyContinue | Where-Object { $_ -match "ERROR|SCRIPT ERROR" }
if ($errors) {
    Write-Host ""
    Write-Host "Script Errors:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}

Write-Host ""
Write-Host "Full output: $outputFile" -ForegroundColor Gray
Write-Host "Errors: $errorFile" -ForegroundColor Gray

exit $exitCode
