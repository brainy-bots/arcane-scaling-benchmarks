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
}
