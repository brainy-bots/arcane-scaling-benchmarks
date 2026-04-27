BeforeAll {
  $helpers = Join-Path $PSScriptRoot '..\scripts\BenchmarkHarnessHelpers.ps1'
  . $helpers
}

Describe 'Get-SafeResultsEnvironmentSegment' {
  It 'returns Local for empty or whitespace' {
    Get-SafeResultsEnvironmentSegment '' | Should -Be 'Local'
    Get-SafeResultsEnvironmentSegment '   ' | Should -Be 'Local'
    Get-SafeResultsEnvironmentSegment $null | Should -Be 'Local'
  }

  It 'passes through safe names' {
    Get-SafeResultsEnvironmentSegment 'Local' | Should -Be 'Local'
    Get-SafeResultsEnvironmentSegment 'DistributedComponents' | Should -Be 'DistributedComponents'
    Get-SafeResultsEnvironmentSegment 'SingleInstance' | Should -Be 'SingleInstance'
  }

  It 'replaces Windows-invalid path characters with underscore' {
    Get-SafeResultsEnvironmentSegment 'a/b' | Should -Be 'a_b'
    Get-SafeResultsEnvironmentSegment 'x:y' | Should -Be 'x_y'
    Get-SafeResultsEnvironmentSegment 'a|b*c?d<e>f"g\h' | Should -Be 'a_b_c_d_e_f_g_h'
  }

}

Describe 'Merge-ConfigFileParameters' {
  BeforeEach {
    $script:SpacetimeMaxPlayers = 1
    $script:Environment = 'Local'
  }

  It 'no-ops when path is empty' {
    { Merge-ConfigFileParameters -Path '' } | Should -Not -Throw
    $script:SpacetimeMaxPlayers | Should -Be 1
  }

  It 'applies supported keys from JSON' {
    $p = Join-Path $TestDrive 'bench.json'
    (@{ SpacetimeMaxPlayers = 4242; Environment = 'SingleInstance' } | ConvertTo-Json) | Set-Content -LiteralPath $p -Encoding utf8
    Merge-ConfigFileParameters -Path $p
    $script:SpacetimeMaxPlayers | Should -Be 4242
    $script:Environment | Should -Be 'SingleInstance'
  }

  It 'throws on unsupported keys' {
    $p = Join-Path $TestDrive 'bad.json'
    (@{ NotARealKey = 1 } | ConvertTo-Json) | Set-Content -LiteralPath $p -Encoding utf8
    { Merge-ConfigFileParameters -Path $p } | Should -Throw '*Unsupported config key*'
  }

  It 'throws when file missing' {
    { Merge-ConfigFileParameters -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
  }

  It 'applies Arcane topology keys from JSON' {
    $p = Join-Path $TestDrive 'arcane-topo.json'
    (@{
      ArcaneManagerHost        = '10.0.0.1'
      ArcaneManagerPort        = 9090
      ArcaneClusterHosts       = @('10.0.0.2', '10.0.0.3')
      ArcaneClusterBasePort    = 7000
      ArcaneClusterPortStride  = 0
      ArcaneExternalProcesses  = $true
    } | ConvertTo-Json) | Set-Content -LiteralPath $p -Encoding utf8
    Merge-ConfigFileParameters -Path $p
    $script:ArcaneManagerHost | Should -Be '10.0.0.1'
    $script:ArcaneManagerPort | Should -Be 9090
    @($script:ArcaneClusterHosts) | Should -Be @('10.0.0.2', '10.0.0.3')
    $script:ArcaneClusterBasePort | Should -Be 7000
    $script:ArcaneClusterPortStride | Should -Be 0
    $script:ArcaneExternalProcesses | Should -BeTrue
  }

  It 'accepts multi-driver keys (DriverCount, MaxPlayersPerDriver, InterSpawnDelayMs)' {
    $p = Join-Path $TestDrive 'multi-driver.json'
    (@{
      DriverCount         = 4
      MaxPlayersPerDriver = 2000
      InterSpawnDelayMs   = 4
    } | ConvertTo-Json) | Set-Content -LiteralPath $p -Encoding utf8
    Merge-ConfigFileParameters -Path $p
    $script:DriverCount         | Should -Be 4
    $script:MaxPlayersPerDriver | Should -Be 2000
    $script:InterSpawnDelayMs   | Should -Be 4
  }
}

Describe 'Test-IsLocalLoopbackHostName' {
  It 'treats blank as loopback' {
    Test-IsLocalLoopbackHostName '' | Should -BeTrue
    Test-IsLocalLoopbackHostName '   ' | Should -BeTrue
    Test-IsLocalLoopbackHostName $null | Should -BeTrue
  }

  It 'recognizes common loopback spellings' {
    Test-IsLocalLoopbackHostName '127.0.0.1' | Should -BeTrue
    Test-IsLocalLoopbackHostName 'LOCALHOST' | Should -BeTrue
    Test-IsLocalLoopbackHostName '::1' | Should -BeTrue
  }

  It 'returns false for non-loopback' {
    Test-IsLocalLoopbackHostName '10.0.0.1' | Should -BeFalse
    Test-IsLocalLoopbackHostName 'my-vm.internal' | Should -BeFalse
  }
}

Describe 'Invoke-SpacetimeDbEntityCountQuery' {
  It 'returns $null when the host is unreachable' {
    # Port 1 is always refused on Linux/Windows test runners; keeps the test hermetic.
    $r = Invoke-SpacetimeDbEntityCountQuery -SpacetimeHost 'http://127.0.0.1:1' -Database 'nope' -TimeoutSec 2
    $r | Should -BeNullOrEmpty
  }
}

Describe 'Wait-SpacetimeDbReachEntityCount' {
  It 'returns Ready=false and reports timeout when the host is unreachable' {
    $r = Wait-SpacetimeDbReachEntityCount -SpacetimeHost 'http://127.0.0.1:1' -Database 'nope' `
      -TargetEntities 100 -TimeoutSeconds 2 -PollIntervalSeconds 1
    $r.Ready | Should -BeFalse
    $r.Detail | Should -Match 'ramp timed out'
  }
}

Describe 'Assert-ArcaneTopologyForSweep' {
  It 'no-ops when ArcaneClusterCounts is empty' {
    { Assert-ArcaneTopologyForSweep -ArcaneClusterCounts @() -ArcaneClusterHosts @() -ArcaneClusterPortStride 1 -ArcaneExternalProcesses $false -ArcaneManagerHost '127.0.0.1' } | Should -Not -Throw
  }

  It 'throws when ArcaneClusterHosts is too short for max cluster count' {
    { Assert-ArcaneTopologyForSweep -ArcaneClusterCounts @(1, 3) -ArcaneClusterHosts @('a') -ArcaneClusterPortStride 1 -ArcaneExternalProcesses $true -ArcaneManagerHost '127.0.0.1' } | Should -Throw '*at least 3 hostnames*'
  }

  It 'throws for stride 0 on localhost without per-host list' {
    { Assert-ArcaneTopologyForSweep -ArcaneClusterCounts @(2) -ArcaneClusterHosts @() -ArcaneClusterPortStride 0 -ArcaneExternalProcesses $false -ArcaneManagerHost '127.0.0.1' } | Should -Throw '*Set ArcaneClusterHosts*'
  }

  It 'throws for stride 0 with duplicate hosts' {
    { Assert-ArcaneTopologyForSweep -ArcaneClusterCounts @(2) -ArcaneClusterHosts @('h1', 'h1') -ArcaneClusterPortStride 0 -ArcaneExternalProcesses $true -ArcaneManagerHost '127.0.0.1' } | Should -Throw '*distinct ArcaneClusterHosts*'
  }

  It 'throws for non-loopback manager without external processes' {
    { Assert-ArcaneTopologyForSweep -ArcaneClusterCounts @(1) -ArcaneClusterHosts @() -ArcaneClusterPortStride 1 -ArcaneExternalProcesses $false -ArcaneManagerHost '10.0.0.1' } | Should -Throw '*ArcaneExternalProcesses*'
  }

  It 'throws for non-loopback cluster host without external processes' {
    { Assert-ArcaneTopologyForSweep -ArcaneClusterCounts @(1) -ArcaneClusterHosts @('10.0.0.2') -ArcaneClusterPortStride 1 -ArcaneExternalProcesses $false -ArcaneManagerHost '127.0.0.1' } | Should -Throw '*remote hosts*'
  }

  It 'allows non-loopback when ArcaneExternalProcesses is true' {
    { Assert-ArcaneTopologyForSweep -ArcaneClusterCounts @(2) -ArcaneClusterHosts @('10.0.0.2', '10.0.0.3') -ArcaneClusterPortStride 0 -ArcaneExternalProcesses $true -ArcaneManagerHost '10.0.0.1' } | Should -Not -Throw
  }
}
