[CmdletBinding()]
param(
    [string]$Region = 'us-east-1',
    [string]$Tfvars = 'arcaneperhost.clusters_4.drivers_12.tfvars',
    [switch]$SkipAwsChecks
)

$ErrorActionPreference = 'Stop'

function Test-CommandAvailable {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    [pscustomobject]@{
        name   = $Name
        ok     = ($null -ne $cmd)
        detail = if ($cmd) { $cmd.Source } else { 'not found on PATH' }
    }
}

function Test-CurlAvailable {
    foreach ($name in @('curl.exe', 'curl')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c -and $c.CommandType -ne 'Alias') {
            return [pscustomobject]@{ name = 'curl'; ok = $true; detail = $c.Source }
        }
    }
    return [pscustomobject]@{ name = 'curl'; ok = $false; detail = 'not found (non-alias curl required for Run-Benchmark-Aws-Controller.ps1)' }
}

function Invoke-AwsProbe {
    param(
        [string[]]$AwsArgs,
        [string]$Label
    )
    $raw = & aws @AwsArgs 2>&1
    $detail = 'ok'
    if ($LASTEXITCODE -ne 0) {
        if ($raw) {
            $detail = (($raw | ForEach-Object { $_.ToString() }) -join "`n")
        } else {
            $detail = 'unknown aws CLI error'
        }
    }
    [pscustomobject]@{
        name   = $Label
        ok     = ($LASTEXITCODE -eq 0)
        detail = $detail
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$tfDir = Join-Path $repoRoot 'infra/terraform/aws_benchmark'
$tfvarsPath = Join-Path $tfDir $Tfvars

Write-Host "==> Repro preflight"
Write-Host "    region: $Region"
Write-Host "    tfvars: $Tfvars"

$checks = New-Object System.Collections.Generic.List[object]

$checks.Add((Test-CommandAvailable -Name 'pwsh'))
$checks.Add((Test-CommandAvailable -Name 'terraform'))
$checks.Add((Test-CommandAvailable -Name 'aws'))
$checks.Add((Test-CurlAvailable))

$ctrlCandidates = @(
    (Join-Path $repoRoot 'target/release/benchmark-controller.exe'),
    (Join-Path $repoRoot 'target/release/benchmark-controller'),
    (Join-Path $repoRoot 'target/debug/benchmark-controller.exe'),
    (Join-Path $repoRoot 'target/debug/benchmark-controller'),
    (Join-Path $repoRoot 'crates/benchmark-controller/target/release/benchmark-controller.exe'),
    (Join-Path $repoRoot 'crates/benchmark-controller/target/release/benchmark-controller'),
    (Join-Path $repoRoot 'crates/benchmark-controller/target/debug/benchmark-controller.exe'),
    (Join-Path $repoRoot 'crates/benchmark-controller/target/debug/benchmark-controller')
)
$ctrlPath = $ctrlCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$hasCargo = $null -ne (Get-Command cargo -ErrorAction SilentlyContinue)
if ($ctrlPath) {
    $checks.Add([pscustomobject]@{ name = 'benchmark-controller binary'; ok = $true; detail = $ctrlPath })
} elseif ($hasCargo) {
    $checks.Add([pscustomobject]@{ name = 'benchmark-controller binary'; ok = $true; detail = 'not built yet — `cd crates/benchmark-controller; cargo build --release` before run' })
} else {
    $checks.Add([pscustomobject]@{ name = 'benchmark-controller binary'; ok = $false; detail = 'missing: install Rust/cargo or build benchmark-controller (see repo README)' })
}

if (Test-Path -LiteralPath $tfvarsPath) {
    $checks.Add([pscustomobject]@{ name = 'tfvars file'; ok = $true; detail = $tfvarsPath })
} else {
    $checks.Add([pscustomobject]@{ name = 'tfvars file'; ok = $false; detail = "missing: $tfvarsPath" })
}

if (-not $SkipAwsChecks) {
    $checks.Add((Invoke-AwsProbe -AwsArgs @('sts', 'get-caller-identity', '--output', 'json') -Label 'aws sts identity'))
    $checks.Add((Invoke-AwsProbe -AwsArgs @('ec2', 'describe-availability-zones', '--region', $Region, '--all-availability-zones', '--output', 'json') -Label "ec2 access ($Region)"))
    $checks.Add((Invoke-AwsProbe -AwsArgs @('ssm', 'describe-instance-information', '--region', $Region, '--max-results', '5', '--output', 'json') -Label "ssm access ($Region)"))
}

Write-Host ''
$checks |
    Select-Object @{Name='Check';Expression={$_.name}}, @{Name='Status';Expression={if ($_.ok) { 'PASS' } else { 'FAIL' }}}, @{Name='Detail';Expression={$_.detail}} |
    Format-Table -AutoSize | Out-String | Write-Host

$failed = @($checks | Where-Object { -not $_.ok })
if ($failed.Count -gt 0) {
    throw "Preflight failed ($($failed.Count) checks). Fix failures before running setup/run."
}

Write-Host 'Preflight passed. Next: Setup-Benchmark-Aws.ps1 (or Run-Repro-Aws-Controller.ps1 for full loop).' -ForegroundColor Green
