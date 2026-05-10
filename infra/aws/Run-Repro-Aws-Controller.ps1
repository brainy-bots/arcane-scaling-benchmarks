<#
.SYNOPSIS
  One-shot AWS reproduction for the controller + terminal-dashboard path:
  preflight → Setup-Benchmark-Aws → Run-Benchmark-Aws-Controller → headline table
  + interactive rerun / destroy (unless -NonInteractive).

.DESCRIPTION
  Use -SkipSetup / -SkipCleanup when you are iterating (fleet already up, or keep
  instances for inspection).

  When stdin is interactive (default): after each benchmark run, prints a README-style
  headline summary table and prompts [1] Rerun or [2] Destroy (quiet terraform destroy).

  Use -NonInteractive for CI or pipelines: runs cleanup automatically unless -SkipCleanup.

  Exit code is the last controller run exit code when the run step executes; cleanup
  failures from auto-mode are written to stderr but do not mask a successful benchmark
  exit code when choosing destroy from the menu (destroy throws on leak).
#>

[CmdletBinding()]
param(
    [string] $Tfvars = 'arcaneperhost.clusters_4.drivers_12.tfvars',
    [string] $Region = 'us-east-1',
    [Parameter(Mandatory)] [string] $PlanFile,
    [Parameter(Mandatory)] [string] $BenchmarkImage,
    [string] $StatePath,
    [string] $ResultsDir,
    [switch] $S3UploadResults,
    [switch] $SkipPreflight,
    [switch] $SkipSetup,
    [switch] $SkipCleanup,
    [switch] $NonInteractive
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $StatePath) {
    $StatePath = Join-Path $repoRoot '.benchmark-aws-terraform.json'
}
$StatePath = [System.IO.Path]::GetFullPath($StatePath)

if (-not [System.IO.Path]::IsPathRooted($PlanFile)) {
    $PlanFile = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PlanFile))
}
if ($ResultsDir -and -not [System.IO.Path]::IsPathRooted($ResultsDir)) {
    $ResultsDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ResultsDir))
}

$setupScript = Join-Path $PSScriptRoot 'Setup-Benchmark-Aws.ps1'
$runScript = Join-Path $PSScriptRoot 'Run-Benchmark-Aws-Controller.ps1'
$cleanupScript = Join-Path $PSScriptRoot 'Cleanup-Benchmark-Aws.ps1'
$preflightScript = Join-Path $PSScriptRoot 'Test-ReproPrereqs.ps1'

. (Join-Path $PSScriptRoot 'lib/PostRunMenu.ps1')

$metaPath = Join-Path $repoRoot '.benchmark-last-controller-run.json'
$tfvarsFull = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "infra/terraform/aws_benchmark/$Tfvars"))

if (-not $SkipPreflight) {
    & $preflightScript -Region $Region -Tfvars $Tfvars
}

if (-not $SkipSetup) {
    & $setupScript -Tfvars $Tfvars -Region $Region
} elseif (-not (Test-Path -LiteralPath $StatePath)) {
    throw "SkipSetup requires an existing state file: $StatePath"
}

$runArgs = @{
    StatePath      = $StatePath
    PlanFile       = $PlanFile
    BenchmarkImage = $BenchmarkImage
}
if ($ResultsDir) { $runArgs['ResultsDir'] = $ResultsDir }
if ($S3UploadResults) { $runArgs['S3UploadResults'] = $true }

$interactive = -not $NonInteractive -and -not [Console]::IsInputRedirected
$runExit = 1

function Invoke-Cleanup {
    if ($SkipCleanup) { return }
    try {
        & $cleanupScript -Tfvars $Tfvars -Region $Region
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Cleanup-Benchmark-Aws exited $LASTEXITCODE (check AWS console for leaks)."
        }
    } catch {
        Write-Warning "Cleanup failed: $($_.Exception.Message)"
    }
}

try {
    while ($true) {
        & $runScript @runArgs
        $runExit = $LASTEXITCODE

        if (Test-Path -LiteralPath $metaPath) {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding utf8 | ConvertFrom-Json
            Show-BenchmarkHeadlineTable -ResultsDir $meta.results_dir -StatePath $StatePath `
                -RunId $meta.run_id -TfvarsPath $tfvarsFull -RepoRoot $repoRoot `
                -ControllerExitCode $runExit
        } else {
            Write-Warning "Missing $metaPath — headline table skipped."
        }

        if (-not $interactive) {
            Invoke-Cleanup
            exit $runExit
        }

        while ($true) {
            Write-Host ''
            Write-Host '  [1] Rerun the benchmark' -ForegroundColor Yellow
            Write-Host '  [2] Destroy the AWS environment (terraform destroy)' -ForegroundColor Yellow
            $choice = Read-Host 'Enter 1 or 2'
            if ($choice -eq '2') {
                Invoke-Cleanup
                exit $runExit
            }
            if ($choice -eq '1') {
                break
            }
            Write-Host 'Please enter 1 or 2.' -ForegroundColor Red
        }
    }
} catch {
    Write-Error "Run failed: $($_.Exception.Message)"
    Invoke-Cleanup
    exit 1
}
