Import-Module "$PSScriptRoot\..\scripts\common\BenchmarkScenario.psm1" -Force

Describe "Benchmark scenario helpers" {
  It "creates cluster config entries for each cluster" {
    $cfg = New-ClusterConfig -ClusterCount 3

    $cfg | Should Not BeNullOrEmpty
    $cfg.Ids.Count | Should Be 3
    $cfg.ManagerClusters | Should Match "arcane-v2-cluster-0:8090"
    $cfg.ManagerClusters | Should Match "arcane-v2-cluster-1:8091"
    $cfg.ManagerClusters | Should Match "arcane-v2-cluster-2:8092"
  }

  It "returns manager env lines with neighbor placeholders" {
    $lines = New-ManagerEnvLines -ManagerClusters "id1:arcane-v2-cluster-0:8090"

    $lines.Count | Should Be 4
    $lines[0] | Should Be "MANAGER_CLUSTERS=id1:arcane-v2-cluster-0:8090"
    $lines[1] | Should Be "NEIGHBOR_IDS_1="
    $lines[2] | Should Be "NEIGHBOR_IDS_2="
    $lines[3] | Should Be "NEIGHBOR_IDS_3="
  }
}
