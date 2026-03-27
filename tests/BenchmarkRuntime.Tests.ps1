Import-Module "$PSScriptRoot\..\scripts\common\BenchmarkRuntime.psm1" -Force

Describe "Benchmark runtime helpers" {
  It "returns base container names when no cluster names are supplied" {
    $names = Get-LogContainerNames -ClusterNames @()
    $names.Count | Should Be 2
    $names[0] | Should Be "arcane-v2-redis"
    $names[1] | Should Be "arcane-v2-manager"
  }

  It "builds base container log names plus cluster names" {
    $names = Get-LogContainerNames -ClusterNames @("arcane-v2-cluster-0", "arcane-v2-cluster-1")
    $names.Count | Should Be 4
    $names[0] | Should Be "arcane-v2-redis"
    $names[1] | Should Be "arcane-v2-manager"
    $names[2] | Should Be "arcane-v2-cluster-0"
    $names[3] | Should Be "arcane-v2-cluster-1"
  }

  It "writes docker stats rows with scenario metadata" {
    $tmp = Join-Path $env:TEMP ("benchmark_runtime_test_" + [guid]::NewGuid().ToString() + ".csv")
    try {
      Write-DockerStatsCsv -OutPath $tmp -ScenarioTag "arcane_plus_spacetimedb" -Players 250 -NumServers 1 -Rows @(
        "container1,10.0%,100MiB / 2GiB,1kB / 2kB,0B / 0B"
      )
      $content = Get-Content $tmp -Raw
      $content | Should Match "arcane_plus_spacetimedb,1,250,container1,10.0%"
    }
    finally {
      if (Test-Path $tmp) { Remove-Item $tmp -Force }
    }
  }
}
