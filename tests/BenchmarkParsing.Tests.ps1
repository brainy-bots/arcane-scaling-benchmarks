Import-Module "$PSScriptRoot\..\scripts\common\BenchmarkParsing.psm1" -Force

Describe "Benchmark parsing helpers" {
  It "parses FINAL and FINAL_SPACETIMEDB lines" {
    $log = @"
noise line
FINAL: players=250 total_calls=1000 total_oks=995 total_errs=5 lat_avg_ms=42.5
FINAL_SPACETIMEDB: action_calls=200 action_oks=199 action_errs=1
"@
    $parsed = Get-SwarmFinal -Text $log

    $parsed | Should Not BeNullOrEmpty
    $parsed.players | Should Be 250
    $parsed.total_calls | Should Be 1000
    $parsed.total_errs | Should Be 5
    $parsed.action_calls | Should Be 200
    $parsed.action_errs | Should Be 1
    $parsed.lat_avg_ms | Should Be 42.5
  }

  It "returns null when FINAL line is missing" {
    $parsed = Get-SwarmFinal -Text "just some logs"
    $parsed | Should BeNullOrEmpty
  }

  It "uses the last FINAL record when multiple appear" {
    $log = @"
FINAL: players=100 total_calls=100 total_oks=100 total_errs=0 lat_avg_ms=10.0
noise
FINAL: players=200 total_calls=500 total_oks=490 total_errs=10 lat_avg_ms=30.0
"@
    $parsed = Get-SwarmFinal -Text $log
    $parsed.players | Should Be 200
    $parsed.total_calls | Should Be 500
    $parsed.total_errs | Should Be 10
  }

  It "evaluates pass criteria over combined call streams" {
    $parsed = [pscustomobject]@{
      total_calls = 1000L
      total_errs = 2L
      action_calls = 500L
      action_errs = 3L
      lat_avg_ms = 25.0
    }
    $ok = Test-BenchmarkPass -ParsedFinal $parsed -MaxErrRate 0.01 -MaxLatencyMs 200
    $ok | Should Be $true
  }

  It "fails when latency exceeds threshold" {
    $parsed = [pscustomobject]@{
      total_calls = 1000L
      total_errs = 0L
      action_calls = 0L
      action_errs = 0L
      lat_avg_ms = 250.0
    }
    $ok = Test-BenchmarkPass -ParsedFinal $parsed -MaxErrRate 0.01 -MaxLatencyMs 200
    $ok | Should Be $false
  }

  It "fails when there are zero calls" {
    $parsed = [pscustomobject]@{
      total_calls = 0L
      total_errs = 0L
      action_calls = 0L
      action_errs = 0L
      lat_avg_ms = 10.0
    }
    $ok = Test-BenchmarkPass -ParsedFinal $parsed -MaxErrRate 0.01 -MaxLatencyMs 200
    $ok | Should Be $false
  }
}
