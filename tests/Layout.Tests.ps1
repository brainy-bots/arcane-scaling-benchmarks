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

  It 'exposes shared benchmark harness helpers' {
    $p = Join-Path $PSScriptRoot '..\scripts\BenchmarkHarnessHelpers.ps1'
    Test-Path -LiteralPath $p | Should -Be $true
  }

  It 'exposes Terraform module for AWS environment provisioning' {
    $root = Join-Path $PSScriptRoot '..\infra\terraform\aws_benchmark'
    Test-Path -LiteralPath (Join-Path $root 'versions.tf') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $root 'variables.tf') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $root 's3_iam.tf') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $root 'ec2_spacetime.tf') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $root 'ec2_arcane.tf') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $root 'outputs.tf') | Should -Be $true
  }

  It 'exposes AWS run-phase PowerShell (run + collect only)' {
    $root = Join-Path $PSScriptRoot '..\infra\aws'
    Test-Path -LiteralPath (Join-Path $root 'Run-Benchmark-Aws.ps1') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $root 'Collect-AwsBenchmarkResults.ps1') | Should -Be $true
    Test-Path -LiteralPath (Join-Path $root 'Sync-AwsBenchmarkResultsFromS3.ps1') | Should -Be $true
    Test-Path -LiteralPath (Join-Path (Join-Path $root 'lib') 'AwsHelpers.ps1') | Should -Be $true
  }

  It 'exposes AwsSpacetimeOnly and AwsArcanePerHost RemoteBenchmark modules' {
    $base = Join-Path $PSScriptRoot '..\infra\aws\topologies'
    Test-Path -LiteralPath (Join-Path (Join-Path $base 'AwsSpacetimeOnly') 'RemoteBenchmark.ps1') | Should -Be $true
    Test-Path -LiteralPath (Join-Path (Join-Path $base 'AwsArcanePerHost') 'RemoteBenchmark.ps1') | Should -Be $true
  }

  It 'does not expose PowerShell setup or cleanup scripts (Terraform owns that)' {
    # Provisioning and teardown must only be possible via Terraform; enforce that setup/cleanup PS does not creep back in.
    $root = Join-Path $PSScriptRoot '..\infra\aws'
    Test-Path -LiteralPath (Join-Path $root 'Setup-AwsBenchmark.ps1') | Should -Be $false
    Test-Path -LiteralPath (Join-Path $root 'Cleanup-AwsBenchmark.ps1') | Should -Be $false
    Test-Path -LiteralPath (Join-Path (Join-Path $root 'lib') 'Ensure-AwsBenchmarkAwsResources.ps1') | Should -Be $false
    foreach ($topology in @('AwsSpacetimeOnly', 'AwsArcanePerHost')) {
      $b = Join-Path (Join-Path $root 'topologies') $topology
      Test-Path -LiteralPath (Join-Path $b 'Setup.ps1') | Should -Be $false
      Test-Path -LiteralPath (Join-Path $b 'Cleanup.ps1') | Should -Be $false
    }
  }

  It 'exposes shared Docker deps script (local + cloud)' {
    $sh = Join-Path $PSScriptRoot '..\scripts\start-benchmark-deps.sh'
    $ps1 = Join-Path $PSScriptRoot '..\scripts\Start-BenchmarkDeps.ps1'
    Test-Path -LiteralPath $sh | Should -Be $true
    Test-Path -LiteralPath $ps1 | Should -Be $true
  }
}
