function New-ClusterConfig {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ClusterCount
  )

  $ids = @()
  $entries = @()
  for ($i = 0; $i -lt $ClusterCount; $i++) {
    $ids += ([guid]::NewGuid().ToString())
    $entries += "$($ids[$i]):arcane-v2-cluster-$($i):$([int](8090 + $i))"
  }

  [PSCustomObject]@{
    Ids = $ids
    ManagerClusters = ($entries -join ',')
  }
}

function New-ManagerEnvLines {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$ManagerClusters
  )

  @(
    "MANAGER_CLUSTERS=$ManagerClusters",
    'NEIGHBOR_IDS_1=',
    'NEIGHBOR_IDS_2=',
    'NEIGHBOR_IDS_3='
  )
}

Export-ModuleMember -Function New-ClusterConfig, New-ManagerEnvLines
