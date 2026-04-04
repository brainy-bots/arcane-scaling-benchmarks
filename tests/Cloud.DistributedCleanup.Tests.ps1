BeforeAll {
  $cleanup = Join-Path $PSScriptRoot '..\scripts\cloud\environments\DistributedComponents\Cleanup.ps1'
  . $cleanup
}

Describe 'Get-DistributedComponentsCleanupInstanceIdPlan' {
  It 'marks all three missing when no ids' {
    $s = [pscustomobject]@{
      RedisInstanceId     = ''
      SpacetimeInstanceId = $null
      BenchmarkInstanceId = '  '
    }
    $p = Get-DistributedComponentsCleanupInstanceIdPlan -State $s
    $p.AllThreeMissing | Should -BeTrue
    $p.InstanceIdsToTerminate.Count | Should -Be 0
    $p.MissingFieldNames.Count | Should -Be 3
  }

  It 'lists only non-empty instance ids' {
    $s = [pscustomobject]@{
      RedisInstanceId     = 'i-redis'
      SpacetimeInstanceId = ''
      BenchmarkInstanceId = 'i-bench'
    }
    $p = Get-DistributedComponentsCleanupInstanceIdPlan -State $s
    $p.AllThreeMissing | Should -BeFalse
    $p.InstanceIdsToTerminate | Should -Be @('i-redis', 'i-bench')
    $p.MissingFieldNames | Should -Be @('SpacetimeInstanceId')
  }

  It 'returns all three ids when complete' {
    $s = [pscustomobject]@{
      RedisInstanceId     = 'r'
      SpacetimeInstanceId = 's'
      BenchmarkInstanceId = 'b'
    }
    $p = Get-DistributedComponentsCleanupInstanceIdPlan -State $s
    $p.AllThreeMissing | Should -BeFalse
    $p.MissingFieldNames.Count | Should -Be 0
    $p.InstanceIdsToTerminate | Should -Be @('r', 's', 'b')
  }
}
