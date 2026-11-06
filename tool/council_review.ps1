param(
    [string]$ImagePath = "build\shots\current\dark_1240_Home.png",
    [string[]]$Models = @("opencode/crouton-alpha-free", "opencode/pulse-alpha-free", "opencode/nemotron-3.5-super-vl-free")
)

$prompt = @"
You are an expert UI/UX design judge on the Design Council reviewing screenshots for a desktop media player.
We require a 'robin-approved' UI standard:
- Exceptionally clean, modern, balanced, visually pleasing, and easy on the eyes.
- Great surface depth (layers, subtle glass/tint, elevation, soft borders), NOT a flat pitch-black void.
- Excellent layout symmetry, intentional spacing rhythm, and clear typography hierarchy.
- Seamless affordances (visible drop zone, clear controls, polished empty states, consistent sliders).

Do not use any tools. Inspect the attached image.
Provide:
1. Brief Strengths
2. Remaining Weaknesses (if any)
3. Score out of 10 in this exact format: SCORE: X/10 (e.g. SCORE: 9/10 or SCORE: 9.5/10)
"@

$results = @{}
$allPass = $true

foreach ($model in $Models) {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Querying Council Member: $model on $ImagePath" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    $fullPath = (Resolve-Path $ImagePath).Path
    $output = $prompt | opencode run -m $model -f $fullPath
    Write-Host $output
    
    if ($output -match "SCORE:\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*10") {
        $score = [double]$matches[1]
        $results[$model] = $score
        Write-Host ">> Parsed Score for $model: $score/10" -ForegroundColor Yellow
        if ($score -lt 9.0) {
            $allPass = $false
        }
    } else {
        Write-Host ">> Could not parse score for $model" -ForegroundColor Red
        $allPass = $false
    }
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "COUNCIL SUMMARY:" -ForegroundColor Green
foreach ($m in $results.Keys) {
    Write-Host "$m -> $($results[$m])/10"
}
if ($allPass) {
    Write-Host "STATUS: APPROVED (All >= 9/10)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "STATUS: NOT YET APPROVED (Requires iteration)" -ForegroundColor Yellow
    exit 1
}
