function Get-DockerStatsRows {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $line = & docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.BlockIO}}' 2>&1
  } finally {
    $ErrorActionPreference = $prevEap
  }
  $rows = @()
  foreach ($row in $line) {
    if ($row -is [System.Management.Automation.ErrorRecord]) { continue }
    if (-not [string]::IsNullOrWhiteSpace([string]$row)) {
      $rows += [string]$row
    }
  }
  return $rows
}

function Write-DockerStatsCsv {
  param(
    [Parameter(Mandatory = $true)]
    [string]$OutPath,
    [Parameter(Mandatory = $true)]
    [string]$ScenarioTag,
    [Parameter(Mandatory = $true)]
    [int]$Players,
    [Parameter(Mandatory = $true)]
    [int]$NumServers,
    [Parameter(Mandatory = $true)]
    [string[]]$Rows
  )

  $ts = (Get-Date).ToString('o')
  foreach ($row in $Rows) {
    "$ts,$ScenarioTag,$NumServers,$Players,$row" | Add-Content $OutPath
  }
}

function Get-LogContainerNames {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$ClusterNames
  )

  return @('arcane-v2-redis', 'arcane-v2-manager') + $ClusterNames
}

Export-ModuleMember -Function Get-DockerStatsRows, Write-DockerStatsCsv, Get-LogContainerNames
