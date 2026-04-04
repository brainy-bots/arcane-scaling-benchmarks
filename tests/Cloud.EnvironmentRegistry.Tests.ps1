BeforeAll {
  $root = Join-Path $PSScriptRoot '..\scripts\cloud'
  . (Join-Path $root 'Common\AwsBenchmarkEnvironmentRegistry.ps1')
  . (Join-Path $root 'Tools\Import-AwsBenchmarkEnvironment.ps1')
}

Describe 'Import-AwsBenchmarkEnvironment' {
  It 'includes SingleInstance and DistributedComponents' {
    $names = Get-AwsBenchmarkKnownEnvironments
    $names | Should -Contain 'SingleInstance'
    $names | Should -Contain 'DistributedComponents'
  }
}

Describe 'AwsBenchmarkEnvironmentRegistry' {
  It 'throws for unknown environment on Initialize' {
    { Invoke-BenchmarkAwsEnvironmentInitialize -Environment 'NoSuchTopology' -Parameters @{} } |
      Should -Throw '*Initialize implementation*'
  }

  It 'throws for unknown environment on RemoteBenchmark' {
    { Invoke-BenchmarkAwsEnvironmentRemoteBenchmark -Environment 'NoSuchTopology' -Parameters @{} } |
      Should -Throw '*remote benchmark*'
  }

  It 'throws for unknown environment on Remove' {
    $fake = [pscustomobject]@{ Environment = 'SingleInstance' }
    { Invoke-BenchmarkAwsEnvironmentRemove -Environment 'NoSuchTopology' -State $fake } |
      Should -Throw '*Remove implementation*'
  }
}
