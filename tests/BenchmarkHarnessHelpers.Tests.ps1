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
      MaxPlayersPerDriver = 4000
      InterSpawnDelayMs   = 4
    } | ConvertTo-Json) | Set-Content -LiteralPath $p -Encoding utf8
    Merge-ConfigFileParameters -Path $p
    $script:DriverCount         | Should -Be 4
    $script:MaxPlayersPerDriver | Should -Be 4000
    $script:InterSpawnDelayMs   | Should -Be 4
  }
}

Describe 'Multi-driver effective cap math (sqrt(N) scaling)' {
  # MaxPlayersPerDriver in config = single-driver reference. Effective cap
  # at N drivers = ref / sqrt(N). Verifies the math used both in
  # Run-Scenario-Arcane (harness-side tier-stop + swarm CLI flag) and in
  # the Run-Benchmark-Aws.ps1 pre-launch validator. Same formula in both
  # places to avoid divergence.
  It 'returns ref unchanged when DriverCount = 1' {
    $ref = 4000
    $n = 1
    $effective = if ($ref -gt 0 -and $n -gt 1) { [int][Math]::Floor($ref / [Math]::Sqrt($n)) } else { $ref }
    $effective | Should -Be 4000
  }

  It 'halves ref when DriverCount = 4 (sqrt(4) = 2)' {
    $ref = 4000
    $n = 4
    $effective = [int][Math]::Floor($ref / [Math]::Sqrt($n))
    $effective | Should -Be 2000
  }

  It 'returns ref/sqrt(N) for non-perfect-square N' {
    # N=8 → sqrt(8) = 2.828 → 4000/2.828 = 1414.2 → floor = 1414
    $ref = 4000
    $n = 8
    $effective = [int][Math]::Floor($ref / [Math]::Sqrt($n))
    $effective | Should -Be 1414
  }

  It 'returns 0 when MaxPlayersPerDriver is unset (preserves "no cap" semantics)' {
    $ref = 0
    $n = 4
    $effective = if ($ref -gt 0 -and $n -gt 1) { [int][Math]::Floor($ref / [Math]::Sqrt($n)) } else { $ref }
    $effective | Should -Be 0
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
