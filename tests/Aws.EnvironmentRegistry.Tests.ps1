BeforeAll {
  $root = Join-Path $PSScriptRoot '..\infra\aws'
  . (Join-Path $root 'lib\Import-AwsBenchmarkEnvironment.ps1')
  . (Join-Path $root 'lib\AwsBenchmarkEnvironmentRegistry.ps1')
}

Describe 'Import-AwsBenchmarkEnvironment' {
  It 'includes Aws topologies' {
    $names = Get-AwsBenchmarkKnownEnvironments
    $names | Should -Contain 'AwsSpacetimeOnly'
    $names | Should -Contain 'AwsArcanePerHost'
    $names.Count | Should -Be 2
  }
}

Describe 'AwsBenchmarkEnvironmentRegistry' {
  It 'throws for unknown environment on RemoteBenchmark' {
    { Invoke-BenchmarkAwsEnvironmentRemoteBenchmark -Environment 'NoSuchTopology' -Parameters @{} } |
      Should -Throw '*remote benchmark*'
  }
}
