# Test script to check if Godot project loads without errors
$projectPath = "c:\Users\AnthonyHill\OneDrive - Visionary Wealth Advisors, LLC\Documents\Personal\SCRIPTS\Terraceilia"

Write-Host "Testing Godot project load..."
Write-Host "Project path: $projectPath"
Write-Host ""

# Try to find Godot executable
$godotPaths = @(
    "C:\Program Files\Godot\Godot_v4*\Godot*.exe",
    "C:\Program Files (x86)\Godot\Godot_v4*\Godot*.exe",
    "$env:LOCALAPPDATA\Godot\Godot_v4*\Godot*.exe",
    "C:\Godot\Godot*.exe"
)

$godotExe = $null
foreach ($path in $godotPaths) {
    $found = Get-ChildItem $path -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $godotExe = $found.FullName
        break
    }
}

if (-not $godotExe) {
    Write-Host "Godot executable not found. Please run the project manually from Godot Editor."
    Write-Host "Check for parse errors in the Output panel."
    exit 1
}

Write-Host "Found Godot at: $godotExe"
Write-Host ""
Write-Host "Running validation check..."

cd $projectPath
& $godotExe --headless --quit 2>&1 | Tee-Object -Variable output

$errors = $output | Select-String -Pattern "ERROR|Parse error|Failed to load"
if ($errors) {
    Write-Host ""
    Write-Host "ERRORS FOUND:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
} else {
    Write-Host ""
    Write-Host "SUCCESS: No errors detected!" -ForegroundColor Green
    exit 0
}
