param(
    [string]$MediaPath = 'test-output\smoke.mp4',
    [ValidateRange(1, 1000)][int]$Cycles = 50,
    [ValidateRange(1, 10000)][int]$QueueItems = 100,
    [ValidateRange(1, 60)][int]$WarmupSeconds = 5,
    [string]$ExecutablePath = 'build\windows\x64\runner\Release\mpvson.exe',
    [string]$OutputDirectory = 'test-output\performance-fixed-20261019'
)

$ErrorActionPreference = 'Stop'
$resolvedMedia = (Resolve-Path -LiteralPath $MediaPath).Path
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
$resolvedExecutable = (Resolve-Path -LiteralPath $ExecutablePath).Path
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$fixtureDirectory = Join-Path $resolvedOutput 'fixtures'
New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
$fixture = Join-Path $fixtureDirectory 'benchmark.mkv'
$fixtureSeconds = [math]::Max(120, $Cycles + $WarmupSeconds + 60)

# Distinct paths exercise queue/cache identities without duplicating large files.
# The synthetic fixture has silent audio and outlasts the complete test.
& ffmpeg -hide_banner -loglevel error -stream_loop -1 -i $resolvedMedia -f lavfi -i 'anullsrc=r=48000:cl=stereo' -map '0:v:0' -map '1:a:0' -c:v copy -c:a aac -t $fixtureSeconds -y $fixture
if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the benchmark video fixture.' }
$paths = [System.Collections.Generic.List[string]]::new()
$linkTarget = $fixture
# NTFS allows at most 1024 links per file. Rotate backing files before that
# limit so a 10,000-row run cannot silently turn into thousands of full copies.
$linksPerBackingFile = 512
for ($index = 0; $index -lt $QueueItems; $index++) {
    if ($index -gt 0 -and $index % $linksPerBackingFile -eq 0) {
        $linkTarget = Join-Path $fixtureDirectory ('backing-{0:D3}.mkv' -f [int]($index / $linksPerBackingFile))
        Copy-Item -LiteralPath $fixture -Destination $linkTarget -Force
    }
    $item = Join-Path $fixtureDirectory ('fixture-{0:D5}.mkv' -f $index)
    if (Test-Path -LiteralPath $item) { Remove-Item -LiteralPath $item -Force }
    try { New-Item -ItemType HardLink -Path $item -Target $linkTarget -ErrorAction Stop | Out-Null }
    catch { throw "Could not create benchmark hard links. Use an NTFS output directory with permission to create hard links. No per-row copies will be made. $($_.Exception.Message)" }
    $paths.Add($item)
}
$queuePath = Join-Path $resolvedOutput 'benchmark-queue.json'
ConvertTo-Json -InputObject @($paths) | Set-Content -LiteralPath $queuePath -Encoding utf8NoBOM
$smokeReport = Join-Path $resolvedOutput 'benchmark-smoke.json'
$benchmarkReport = Join-Path $resolvedOutput 'benchmark-results.json'
$progressReport = "$benchmarkReport.progress.json"
foreach ($stale in @($smokeReport, $benchmarkReport, $progressReport)) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
}

$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = $resolvedExecutable
$start.WorkingDirectory = [System.IO.Path]::GetDirectoryName($resolvedExecutable)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.ArgumentList.Add('--smoke-test=' + $fixture)
$start.ArgumentList.Add('--smoke-report=' + $smokeReport)
$start.ArgumentList.Add('--benchmark-cycles=' + $Cycles)
$start.ArgumentList.Add('--benchmark-report=' + $benchmarkReport)
$start.ArgumentList.Add('--benchmark-queue=' + $queuePath)
$start.ArgumentList.Add('--benchmark-warmup-ms=' + ($WarmupSeconds * 1000))
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $start
$samples = [System.Collections.Generic.List[object]]::new()
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$timeoutSeconds = 120 + $Cycles * 3
$timedOut = $false
$started = $false
try {
    if (-not $process.Start()) { throw 'Could not start the benchmark process.' }
    $started = $true
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    while (-not $process.WaitForExit(250)) {
        if ($watch.Elapsed.TotalSeconds -gt $timeoutSeconds) {
            $timedOut = $true
            $process.Kill($true)
            $process.WaitForExit()
            break
        }
        $process.Refresh()
        if ($process.HasExited) { break }
        $phase = 'startup'
        try {
            if (Test-Path -LiteralPath $progressReport) {
                $phase = (Get-Content -LiteralPath $progressReport -Raw | ConvertFrom-Json).phase
            }
        } catch { $phase = 'transition' }
        $samples.Add([PSCustomObject]@{
            ElapsedMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 2)
            Phase = $phase
            WorkingSetBytes = $process.WorkingSet64
            PrivateBytes = $process.PrivateMemorySize64
            Handles = $process.HandleCount
            CpuSeconds = $process.TotalProcessorTime.TotalSeconds
        })
    }
    $output.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $resolvedOutput 'benchmark-stdout.log')
    $errors.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $resolvedOutput 'benchmark-stderr.log')
    ConvertTo-Json -InputObject @($samples) -Depth 5 | Set-Content -LiteralPath (Join-Path $resolvedOutput 'process-samples.json')
    $samples | Export-Csv -LiteralPath (Join-Path $resolvedOutput 'process-samples.csv') -NoTypeInformation
    if ($timedOut) { throw "Benchmark exceeded its $timeoutSeconds second deadline." }
    if ($process.ExitCode -ne 0) { throw "Benchmark process failed with exit code $($process.ExitCode)." }
    if (-not (Test-Path -LiteralPath $smokeReport) -or -not (Test-Path -LiteralPath $benchmarkReport)) {
        throw 'Benchmark did not produce both required reports.'
    }
    $smoke = Get-Content -LiteralPath $smokeReport -Raw | ConvertFrom-Json
    $benchmark = Get-Content -LiteralPath $benchmarkReport -Raw | ConvertFrom-Json
    if (-not $smoke.success -or $benchmark.cycles -ne $Cycles -or $benchmark.queueItems -ne $QueueItems -or $benchmark.cycleSamples.Count -ne $Cycles) {
        throw 'Benchmark failed or produced an incomplete workload.'
    }
    $steady = @($samples | Where-Object Phase -eq 'cycles')
    if ($steady.Count -lt 2) { throw 'Too few samples were collected after warm-up.' }
    $processor = $null
    $graphics = @()
    try {
        $processor = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
        $graphics = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)
    } catch { $processor = $env:PROCESSOR_IDENTIFIER }
    $summary = [ordered]@{
        Success = $true
        Executable = $resolvedExecutable
        Cycles = $Cycles
        QueueItems = $QueueItems
        Fixture = 'Distinct paths to one synthetic long video with silent audio'
        RestoreMetric = $benchmark.restoreMetric
        RestoreMetricLimit = $benchmark.restoreMetricLimit
        RestoreToTextureP95Ms = $benchmark.restoreToTextureMs.p95
        UiFrameP95Ms = $benchmark.uiFrameMs.p95
        RasterFrameP95Ms = $benchmark.rasterFrameMs.p95
        ColdViewportThumbnailMs = $benchmark.coldViewportThumbnailMs
        WarmViewportThumbnailMs = $benchmark.warmViewportThumbnailMs
        PrivateBytesAfterWarmup = $steady[0].PrivateBytes
        FinalPrivateBytes = $steady[-1].PrivateBytes
        MaxPrivateBytesAfterWarmup = ($steady | Measure-Object PrivateBytes -Maximum).Maximum
        HandlesAfterWarmup = $steady[0].Handles
        FinalHandles = $steady[-1].Handles
        CpuSecondsDuringCycles = [math]::Round($steady[-1].CpuSeconds - $steady[0].CpuSeconds, 3)
        Processor = $processor
        Graphics = $graphics
        LogicalProcessors = [Environment]::ProcessorCount
        OS = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        RawSamples = 'process-samples.json'
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resolvedOutput 'benchmark-summary.json')
    $summary | Format-List
} finally {
    if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    $process.Dispose()
}

