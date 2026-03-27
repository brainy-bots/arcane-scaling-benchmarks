function Get-SwarmFinal {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text
  )

  $m = [regex]::Matches($Text, 'FINAL:\s*players=(\d+)\s+total_calls=(\d+)\s+total_oks=(\d+)\s+total_errs=(\d+)\s+lat_avg_ms=([\d.]+)')
  if ($m.Count -eq 0) { return $null }
  $x = $m[$m.Count - 1]

  $s = [regex]::Matches($Text, 'FINAL_SPACETIMEDB:\s*action_calls=(\d+)\s+action_oks=(\d+)\s+action_errs=(\d+)')
  $actionCalls = 0L
  $actionErrs = 0L
  if ($s.Count -gt 0) {
    $sx = $s[$s.Count - 1]
    $actionCalls = [long]$sx.Groups[1].Value
    $actionErrs = [long]$sx.Groups[3].Value
  }

  [PSCustomObject]@{
    players = [int]$x.Groups[1].Value
    total_calls = [long]$x.Groups[2].Value
    total_oks = [long]$x.Groups[3].Value
    total_errs = [long]$x.Groups[4].Value
    lat_avg_ms = [double]$x.Groups[5].Value
    action_calls = $actionCalls
    action_errs = $actionErrs
  }
}

function Test-BenchmarkPass {
  param(
    [Parameter(Mandatory = $false)]
    $ParsedFinal,
    [Parameter(Mandatory = $true)]
    [double]$MaxErrRate,
    [Parameter(Mandatory = $true)]
    [double]$MaxLatencyMs
  )

  if (-not $ParsedFinal) { return $false }
  $calls = $ParsedFinal.total_calls + $ParsedFinal.action_calls
  $errs = $ParsedFinal.total_errs + $ParsedFinal.action_errs
  $err = if ($calls -gt 0) { $errs / $calls } else { 1.0 }
  return ($err -lt $MaxErrRate -and $ParsedFinal.lat_avg_ms -lt $MaxLatencyMs)
}

Export-ModuleMember -Function Get-SwarmFinal, Test-BenchmarkPass
