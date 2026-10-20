param(
    [Parameter(Mandatory = $true)][string]$MediaPath,
    [Alias('Executable')]
    [string]$ExecutablePath = '',
    [string]$OutputDirectory = '',
    [switch]$VerifyFullscreen
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
if (-not $ExecutablePath) {
    $ExecutablePath = Join-Path $scriptDir '..\build\windows\x64\runner\Release\mpvson.exe'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $scriptDir '..\test-output'
}

$resolvedExecutable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$resolvedMedia = (Resolve-Path -LiteralPath $MediaPath).Path
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$smokeReport = Join-Path $resolvedOutput 'native-smoke.json'
$smokeImage = Join-Path $resolvedOutput 'native-smoke.png'
foreach ($staleEvidence in @($smokeReport, $smokeImage)) {
    if (Test-Path -LiteralPath $staleEvidence -PathType Leaf) {
        Remove-Item -LiteralPath $staleEvidence -Force
    }
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $resolvedExecutable
$startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName($resolvedExecutable)
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.ArgumentList.Add('--smoke-test=' + $resolvedMedia)
$startInfo.ArgumentList.Add('--smoke-report=' + $smokeReport)
$startInfo.ArgumentList.Add('--smoke-screenshot=' + $smokeImage)
if ($VerifyFullscreen) { $startInfo.ArgumentList.Add('--smoke-fullscreen') }

$smokeProcess = [System.Diagnostics.Process]::new()
$smokeProcess.StartInfo = $startInfo
if (-not $smokeProcess.Start()) { throw 'Could not start the native player.' }
$stdoutTask = $smokeProcess.StandardOutput.ReadToEndAsync()
$stderrTask = $smokeProcess.StandardError.ReadToEndAsync()
$timedOut = -not $smokeProcess.WaitForExit(25000)
if ($timedOut) {
    $smokeProcess.Kill()
    $smokeProcess.WaitForExit()
}
$stdoutTask.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $resolvedOutput 'native-smoke.stdout.log') -Encoding utf8
$stderrTask.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $resolvedOutput 'native-smoke.stderr.log') -Encoding utf8
if ($timedOut) { throw 'Native playback verification exceeded its 25 second deadline. See test-output logs.' }
if (-not (Test-Path -LiteralPath $smokeReport)) { throw ('Native player did not produce a verification report. Exit code: ' + $smokeProcess.ExitCode) }
$result = Get-Content -LiteralPath $smokeReport -Raw | ConvertFrom-Json
$result | ConvertTo-Json
if ($smokeProcess.ExitCode -ne 0 -or -not $result.success -or -not $result.visualCaptureSuccess) {
    throw 'Native playback verification failed. See test-output logs and report.'
}
if ($VerifyFullscreen -and (-not $result.nativeFullscreen -or -not $result.fullscreenControlsHidden -or $null -eq $result.fullscreenControlsRenderedOpacity -or $result.fullscreenControlsRenderedOpacity -ne 0 -or -not $result.fullscreenCursorConfiguredHidden)) {
    throw 'Native fullscreen interface verification failed. See test-output logs and report.'
}
$smokeProcess.Dispose()
