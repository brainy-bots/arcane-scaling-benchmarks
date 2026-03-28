Describe 'Benchmark repository layout' {
  It 'documents canonical results layout' {
    $p = Join-Path (Join-Path $PSScriptRoot '..') 'results'
    $p = Join-Path $p 'README.md'
    Test-Path -LiteralPath $p | Should -Be $true
  }

  It 'exposes a single Run-Benchmark.ps1 entry script' {
    $p = Join-Path $PSScriptRoot '..\scripts\Run-Benchmark.ps1'
    Test-Path -LiteralPath $p | Should -Be $true
  }

  It 'exposes optional AWS launcher' {
    $p = Join-Path $PSScriptRoot '..\scripts\cloud\Run-Benchmark-Aws.ps1'
    Test-Path -LiteralPath $p | Should -Be $true
  }

  It 'exposes AWS setup and cleanup entry scripts' {
    $root = Join-Path $PSScriptRoot '..\scripts\cloud'
    Test-Path -LiteralPath (Join-Path $root 'Setup-AwsBenchmark.ps1') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $root 'Cleanup-AwsBenchmark.ps1') | Should -Be $true
    Test-Path -LiteralPath (Join-Path (Join-Path $root 'Tools') 'Import-AwsBenchmarkEnvironment.ps1') | Should -Be $true
    Test-Path -LiteralPath (Join-Path (Join-Path $root 'Common') 'AwsHelpers.ps1') | Should -Be $true
  }

  It 'exposes SingleInstance environment module' {
    $base = Join-Path (Join-Path (Join-Path $PSScriptRoot '..\scripts\cloud') 'environments') 'SingleInstance'
    Test-Path -LiteralPath (Join-Path $base 'Setup.ps1') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $base 'RemoteBenchmark.ps1') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $base 'Cleanup.ps1') | Should -Be $true
  }

  It 'exposes shared Docker deps script (local + cloud)' {
    $sh = Join-Path $PSScriptRoot '..\scripts\start-benchmark-deps.sh'
    $ps1 = Join-Path $PSScriptRoot '..\scripts\Start-BenchmarkDeps.ps1'
    Test-Path -LiteralPath $sh | Should -Be $true
    Test-Path -LiteralPath $ps1 | Should -Be $true
  }
}
