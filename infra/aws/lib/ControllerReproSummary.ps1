# Summarize a controller-path run: manifest.json + optional Terraform state →
# benchmark_repro_summary.json + a short console table.

function Get-ControllerPhaseAggregateCcu {
    param(
        [string]$PhaseName,
        [int] $DriverCount
    )
    if ($PhaseName -match '^tier-(\d+)-aggregate$') {
        return [int]$Matches[1]
    }
    if ($PhaseName -match '^tier-(\d+)-per-driver$') {
        if ($DriverCount -lt 1) { return $null }
        return [int]$Matches[1] * $DriverCount
    }
    return $null
}

function Export-ControllerReproSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResultsDir,
        [Parameter(Mandatory)] [string] $StatePath,
        [Parameter(Mandatory)] [string] $RunId
    )

    $manifestPath = Join-Path $ResultsDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "manifest.json not found under $ResultsDir (controller may have exited before writing results)."
    }

    $stateRaw = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8
    $state = $stateRaw | ConvertFrom-Json
    $environment = [string]$state.Environment
    $driverIds = @($state.BenchmarkInstanceIds) | Where-Object { $_ }
    $driverCount = [int]$driverIds.Count

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json

    $phaseRows = New-Object System.Collections.Generic.List[object]
    foreach ($po in @($manifest.phase_outcomes)) {
        $outcome = $po.outcome.outcome
        $ccu = Get-ControllerPhaseAggregateCcu -PhaseName $po.phase_name -DriverCount $driverCount
        $phaseRows.Add([pscustomobject]@{
                phase_index    = [int]$po.phase_index
                phase_name     = [string]$po.phase_name
                outcome        = $outcome
                aggregate_ccu  = $ccu
            })
    }

    $passedWithCcu = @($phaseRows | Where-Object { $_.outcome -eq 'pass' -and $null -ne $_.aggregate_ccu })
    $top = $null
    if ($passedWithCcu.Count -gt 0) {
        $top = $passedWithCcu | Sort-Object -Property aggregate_ccu | Select-Object -Last 1
    }

    $summary = [pscustomobject]@{
        schema_version = 2
        repro_path     = 'controller'
        environment    = $environment
        run_id         = $RunId
        generated_utc  = [DateTime]::UtcNow.ToString('o')
        overall        = [string]$manifest.overall
        plan_name      = [string]$manifest.plan_name
        driver_count   = $driverCount
        top_phase      = $top
        phases         = $phaseRows.ToArray()
    }

    $outPath = Join-Path $ResultsDir 'benchmark_repro_summary.json'
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outPath -Encoding utf8
    Write-Host "Machine-readable summary: $outPath" -ForegroundColor Green

    Write-Host ''
    Write-Host 'Controller run — phase outcomes:' -ForegroundColor Cyan
    $phaseRows | Select-Object phase_index, phase_name, outcome, aggregate_ccu |
        Format-Table -AutoSize | Out-String | Write-Host

    if ($top) {
        Write-Host 'Top passing tier (from plan phase names):' -ForegroundColor Cyan
        @(
            [pscustomobject]@{ Metric = 'Phase'; Value = $top.phase_name }
            [pscustomobject]@{ Metric = 'Aggregate CCU (parsed)'; Value = $top.aggregate_ccu }
            [pscustomobject]@{ Metric = 'Driver count'; Value = $driverCount }
        ) | Format-Table -AutoSize | Out-String | Write-Host
    }

    return $summary
}
