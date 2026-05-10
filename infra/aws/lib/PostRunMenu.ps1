# Post-run headline summary (README-style) + interactive rerun / destroy menu.

function Read-TfvarsHeadlineHints {
    param([string]$TfvarsPath)
    $hints = @{
        instance_type             = $null
        arph_driver_instance_type = $null
        data_instance_type        = $null
        redis_instance_type       = $null
        arcane_cluster_count      = $null
        arph_driver_count         = $null
        aws_region                = $null
    }
    if (-not $TfvarsPath -or -not (Test-Path -LiteralPath $TfvarsPath)) {
        return $hints
    }
    Get-Content -LiteralPath $TfvarsPath | ForEach-Object {
        $line = $_ -replace '#.*$', ''
        if ($line -match '^\s*(\w+)\s*=\s*"([^"]+)"') {
            $hints[$Matches[1]] = $Matches[2]
        }
        elseif ($line -match '^\s*(\w+)\s*=\s*(\d+)\s*$') {
            $hints[$Matches[1]] = [int]$Matches[2]
        }
    }
    return $hints
}

function Show-BenchmarkHeadlineTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResultsDir,
        [Parameter(Mandatory)] [string] $StatePath,
        [Parameter(Mandatory)] [string] $RunId,
        [string] $TfvarsPath,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [int] $ControllerExitCode = 0
    )

    $summaryPath = Join-Path $ResultsDir 'benchmark_repro_summary.json'
    $manifestPath = Join-Path $ResultsDir 'manifest.json'
    $summary = $null
    $manifest = $null
    if (Test-Path -LiteralPath $summaryPath) {
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding utf8 | ConvertFrom-Json
    }
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    }
    elseif (-not $summary) {
        # Neither summary nor manifest exists.
    }
    if (-not $summary -and $manifest) {
        $summary = [pscustomobject]@{
            overall   = [string]$manifest.overall
            plan_name = [string]$manifest.plan_name
            phases    = @()
        }
    }
    else {
        Write-Warning "No manifest or benchmark_repro_summary.json under $ResultsDir — headline table is partial."
    }

    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json
    $hints = Read-TfvarsHeadlineHints -TfvarsPath $TfvarsPath

    $topCcu = $null
    if ($summary -and $summary.top_phase) {
        $topCcu = $summary.top_phase.aggregate_ccu
    }

    # Prefer real per-phase telemetry from phase_*.json (new controller output).
    $phaseFiles = @()
    if (Test-Path -LiteralPath $ResultsDir) {
        $phaseFiles = @(Get-ChildItem -LiteralPath $ResultsDir -Filter 'phase_*.json' -File | Sort-Object Name)
    }
    $phaseByIndex = @{}
    $overallMaxEntities = $null
    $topPassEntities = $null
    $topPassWorstTickMs = $null
    $overallWorstTickMs = $null
    foreach ($pf in $phaseFiles) {
        try {
            $p = Get-Content -LiteralPath $pf.FullName -Raw -Encoding utf8 | ConvertFrom-Json
            $idx = [int]$p.phase_index
            $phaseByIndex[$idx] = $p

            $entMax = $p.cluster_deltas.entities_total.max
            if ($null -ne $entMax) {
                $entMax = [double]$entMax
                if ($null -eq $overallMaxEntities -or $entMax -gt $overallMaxEntities) {
                    $overallMaxEntities = $entMax
                }
            }
            $tickMax = $p.cluster_deltas.worst_tick_ms.max
            if ($null -ne $tickMax) {
                $tickMax = [double]$tickMax
                if ($null -eq $overallWorstTickMs -or $tickMax -gt $overallWorstTickMs) {
                    $overallWorstTickMs = $tickMax
                }
            }
        } catch { }
    }

    if ($manifest -and $manifest.phase_outcomes) {
        $passEntries = @($manifest.phase_outcomes | Where-Object { $_.outcome.outcome -eq 'pass' } | Sort-Object phase_index)
        if ($passEntries.Count -gt 0) {
            $lastPass = $passEntries[-1]
            $idx = [int]$lastPass.phase_index
            if ($phaseByIndex.ContainsKey($idx)) {
                $p = $phaseByIndex[$idx]
                if ($null -ne $p.cluster_deltas.entities_total.max) {
                    $topPassEntities = [double]$p.cluster_deltas.entities_total.max
                }
                if ($null -ne $p.cluster_deltas.worst_tick_ms.max) {
                    $topPassWorstTickMs = [double]$p.cluster_deltas.worst_tick_ms.max
                }
            }
            # If old summary parsing missed top tier names, use telemetry fallback.
            if ($null -eq $topCcu -and $null -ne $topPassEntities) {
                $topCcu = [int][Math]::Round($topPassEntities)
            }
        }
    }

    $clusterN = 0
    if ($state.ClusterInstanceIds) { $clusterN = @($state.ClusterInstanceIds).Count }
    elseif ($hints.arcane_cluster_count) { $clusterN = [int]$hints.arcane_cluster_count }

    $driverN = 0
    if ($state.BenchmarkInstanceIds) { $driverN = @($state.BenchmarkInstanceIds).Count }
    elseif ($hints.arph_driver_count) { $driverN = [int]$hints.arph_driver_count }

    $region = [string]$state.Region
    if (-not $region -and $hints.aws_region) { $region = [string]$hints.aws_region }

    $clusterFleet = if ($hints.instance_type -and $clusterN -gt 0) {
        "$clusterN × $($hints.instance_type)"
    }
    elseif ($clusterN -gt 0) {
        "$clusterN × (see tfvars)"
    }
    else { '—' }

    $driversStr = if ($hints.arph_driver_instance_type -and $driverN -gt 0) {
        "$driverN × $($hints.arph_driver_instance_type)"
    }
    elseif ($driverN -gt 0) {
        "$driverN drivers"
    }
    else { '—' }

    $supporting = @()
    if ($hints.data_instance_type) {
        $supporting += "SpacetimeDB / manager sidecars $($hints.data_instance_type)"
    }
    if ($hints.redis_instance_type) {
        $supporting += "Redis $($hints.redis_instance_type)"
    }
    $supportingStr = if ($supporting.Count -gt 0) { ($supporting -join ' · ') } else { '—' }

    $outcomeStr = if ($summary) { [string]$summary.overall } else { '—' }
    if ($ControllerExitCode -ne 0) {
        $outcomeStr = "fail (controller exit $ControllerExitCode)"
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add([pscustomobject]@{ Variable = 'Concurrent players (CCU) — top passing tier'; Value = $(if ($null -ne $topCcu) { [int]$topCcu } else { '—' }) })
    $rows.Add([pscustomobject]@{ Variable = 'Peak aggregate entities observed (any phase)'; Value = $(if ($null -ne $overallMaxEntities) { [int][Math]::Round($overallMaxEntities) } else { '—' }) })
    $rows.Add([pscustomobject]@{ Variable = 'Server tick / broadcast rate'; Value = '60 Hz (workload default in Run-Benchmark-Aws-Controller)' })
    $rows.Add([pscustomobject]@{ Variable = 'Per-entity user_data payload'; Value = '1,000 bytes (driver workload default)' })
    $rows.Add([pscustomobject]@{ Variable = 'Worst server tick ms (top passing phase)'; Value = $(if ($null -ne $topPassWorstTickMs) { ('{0:N2} ms' -f $topPassWorstTickMs) } else { '—' }) })
    $rows.Add([pscustomobject]@{ Variable = 'Worst server tick ms (any phase)'; Value = $(if ($null -ne $overallWorstTickMs) { ('{0:N2} ms' -f $overallWorstTickMs) } else { '—' }) })
    $rows.Add([pscustomobject]@{ Variable = 'Controller outcome'; Value = $outcomeStr })
    $rows.Add([pscustomobject]@{ Variable = 'Plan'; Value = $(if ($summary) { [string]$summary.plan_name } else { '—' }) })
    $rows.Add([pscustomobject]@{ Variable = 'Cluster fleet'; Value = $clusterFleet })
    $rows.Add([pscustomobject]@{ Variable = 'Load drivers'; Value = $driversStr })
    $rows.Add([pscustomobject]@{ Variable = 'Supporting nodes (from tfvars)'; Value = $supportingStr })
    $rows.Add([pscustomobject]@{ Variable = 'AWS region'; Value = $(if ($region) { $region } else { '—' }) })
    $rows.Add([pscustomobject]@{ Variable = 'Environment'; Value = [string]$state.Environment })
    $rows.Add([pscustomobject]@{ Variable = 'Run ID'; Value = $RunId })
    $rows.Add([pscustomobject]@{ Variable = 'Results directory'; Value = $ResultsDir })

    Write-Host ''
    Write-Host 'Headline summary (same shape as README claim table):' -ForegroundColor Cyan
    $rows | Format-Table -AutoSize -Wrap | Out-String | Write-Host
}
