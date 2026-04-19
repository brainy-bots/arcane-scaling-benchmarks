# Resolves effective BenchmarkMode / ArcaneClusterCount from -BenchmarkPwshArgs the same way
# Run-Benchmark.ps1 does: apply -ConfigFile JSON first (it is the source of truth for workload
# parameters), then overlay CLI-style tokens (cloud-injected overrides). Used by
# Run-Benchmark-Aws.ps1 to fail before SSM when the run does not match provisioned topology.

function Assert-BenchmarkPwshArgsCompatibleWithRemoteAwsTemplate {
  param(
    [Parameter(Mandatory)][string]$Environment,
    [string]$BenchmarkPwshArgs = ''
  )
  if ([string]::IsNullOrWhiteSpace($BenchmarkPwshArgs)) { return }
  $s = $BenchmarkPwshArgs
  if ($s -match '(?i)-Environment(?:\s|$)') {
    throw @"
-BenchmarkPwshArgs must not include -Environment: the remote script already sets -Environment for this AWS topology ($Environment). Duplicate binding will fail on the instance.
"@
  }
  if ($Environment -eq 'AwsSpacetimeOnly' -and $s -match '(?i)-BenchmarkMode(?:\s|$)') {
    throw @"
-BenchmarkPwshArgs must not include -BenchmarkMode for Environment AwsSpacetimeOnly: the remote script always runs -BenchmarkMode SpacetimeOnly. Use -ConfigFile and/or other parameters only.
"@
  }
}

function Get-AllBenchmarkPwshArgsConfigFilePaths {
  param([string]$BenchmarkPwshArgs)
  if ([string]::IsNullOrWhiteSpace($BenchmarkPwshArgs)) { return @() }
  $paths = [System.Collections.Generic.List[string]]::new()
  $s = $BenchmarkPwshArgs
  $token = '-ConfigFile'
  $i = 0
  while ($i -lt $s.Length) {
    $idx = $s.IndexOf($token, $i, [StringComparison]::OrdinalIgnoreCase)
    if ($idx -lt 0) { break }
    $pos = $idx + $token.Length
    while ($pos -lt $s.Length -and [char]::IsWhiteSpace($s[$pos])) { $pos++ }
    if ($pos -ge $s.Length) { break }
    $q = $s[$pos]
    if ($q -eq '"' -or $q -eq [char]0x201C -or $q -eq [char]0x201D) {
      $pos++
      $end = $s.IndexOf($q, $pos)
      if ($end -lt 0) { $i = $pos; continue }
      $p = $s.Substring($pos, $end - $pos).Trim()
      if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$paths.Add($p) }
      $i = $end + 1
      continue
    }
    if ($q -eq "'") {
      $pos++
      $end = $s.IndexOf("'", $pos)
      if ($end -lt 0) { $i = $pos; continue }
      $p = $s.Substring($pos, $end - $pos).Trim()
      if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$paths.Add($p) }
      $i = $end + 1
      continue
    }
    $startTok = $pos
    while ($pos -lt $s.Length -and -not [char]::IsWhiteSpace($s[$pos])) { $pos++ }
    $p = $s.Substring($startTok, $pos - $startTok).Trim()
    if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$paths.Add($p) }
    $i = $pos
  }
  if ($paths.Count -eq 0) { return @() }
  # Comma forces a real single-element array return (otherwise PS unwraps @($x) to a scalar string).
  return , @([string[]]@($paths))
}

function Resolve-BenchmarkConfigFilePathForValidation {
  param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string[]]$SearchBasePaths
  )
  $bases = @($SearchBasePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | ForEach-Object { (Resolve-Path -LiteralPath $_ -ErrorAction SilentlyContinue).Path } | Where-Object { $_ }
  if ($bases.Count -eq 0) { $bases = @((Get-Location).Path) }

  if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
    if (Test-Path -LiteralPath $ConfigPath) { return (Resolve-Path -LiteralPath $ConfigPath).Path }
    return $null
  }
  foreach ($base in $bases) {
    $joined = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $ConfigPath))
    if (Test-Path -LiteralPath $joined) { return $joined }
  }
  return $null
}

function Get-BenchmarkRunIntentFromBenchmarkPwshArgs {
  [CmdletBinding()]
  param(
    [string]$BenchmarkPwshArgs = '',
    [string[]]$ConfigSearchBasePaths = @()
  )

  $mode = $null
  $clusterCount = $null
  $configLoaded = $false
  $missingConfigPath = $null

  $cfgPaths = Get-AllBenchmarkPwshArgsConfigFilePaths -BenchmarkPwshArgs $BenchmarkPwshArgs
  if ($cfgPaths.Count -gt 0) {
    $cfgRel = $cfgPaths[$cfgPaths.Count - 1]
    $full = Resolve-BenchmarkConfigFilePathForValidation -ConfigPath $cfgRel -SearchBasePaths $ConfigSearchBasePaths
    if (-not $full) {
      $missingConfigPath = $cfgRel
    }
    else {
      $raw = Get-Content -LiteralPath $full -Raw -Encoding utf8 -ErrorAction Stop
      # Strip JSONC comments before parsing — configs/*.json carry inline `//`
      # descriptions for every field. Keep this in sync with
      # ConvertFrom-BenchmarkConfigJsonc in scripts/BenchmarkHarnessHelpers.ps1.
      $cleaned = [regex]::Replace($raw, '("(?:\\.|[^"\\])*")|(//[^\r\n]*)|(/\*[\s\S]*?\*/)', {
        param($m)
        if ($m.Groups[1].Success) { return $m.Groups[1].Value }
        return ''
      })
      $cfg = $cleaned | ConvertFrom-Json -ErrorAction Stop
      $configLoaded = $true
      foreach ($prop in $cfg.PSObject.Properties) {
        $pn = $prop.Name
        if ($pn.Equals('BenchmarkMode', [StringComparison]::OrdinalIgnoreCase)) {
          $v = $prop.Value
          if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
            $mode = [string]$v
          }
        }
        elseif ($pn.Equals('ArcaneClusterCount', [StringComparison]::OrdinalIgnoreCase)) {
          $clusterCount = [int]$prop.Value
        }
      }
    }
  }

  if ($BenchmarkPwshArgs -match '(?i)-BenchmarkMode\s+(\S+)') {
    if ($null -eq $mode) { $mode = [string]$Matches[1] }
  }
  if ($BenchmarkPwshArgs -match '(?i)-ArcaneClusterCount\s+(\d+)') {
    if ($null -eq $clusterCount) { $clusterCount = [int]$Matches[1] }
  }

  [pscustomobject]@{
    BenchmarkMode           = $mode
    ArcaneClusterCount      = $clusterCount
    ConfigFileResolved      = $configLoaded
    MissingConfigFilePath   = $missingConfigPath
  }
}

function Normalize-BenchmarkModeName {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $x = $Raw.Trim().ToLowerInvariant()
  switch ($x) {
    'spacetimeonly' { return 'SpacetimeOnly' }
    'arcaneplusspacetime' { return 'ArcanePlusSpacetime' }
    default { return $null }
  }
}

function Assert-BenchmarkRunMatchesAwsEnvironment {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][object]$State,
    [string]$BenchmarkPwshArgs = '',
    [Parameter(Mandatory)][string]$RemoteProvisionProfile,
    [string[]]$ConfigSearchBasePaths = @()
  )

  Assert-BenchmarkPwshArgsCompatibleWithRemoteAwsTemplate -Environment $Environment -BenchmarkPwshArgs $BenchmarkPwshArgs

  $intent = Get-BenchmarkRunIntentFromBenchmarkPwshArgs -BenchmarkPwshArgs $BenchmarkPwshArgs `
    -ConfigSearchBasePaths $ConfigSearchBasePaths
  $normMode = Normalize-BenchmarkModeName -Raw $intent.BenchmarkMode

  if ($null -ne $intent.MissingConfigFilePath) {
    $tried = @($ConfigSearchBasePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ', '
    if ([string]::IsNullOrWhiteSpace($tried)) { $tried = (Get-Location).Path }
    $arcPhIncomplete = ($Environment -eq 'AwsArcanePerHost') -and (
      ($null -eq $normMode) -or ($null -eq $intent.ArcaneClusterCount))
    if ($arcPhIncomplete) {
      throw "Cannot validate this run: -ConfigFile '$($intent.MissingConfigFilePath)' was not found locally (search bases: $tried), and -BenchmarkPwshArgs does not set both -BenchmarkMode ArcanePlusSpacetime and -ArcaneClusterCount. Fix the config path or pass those parameters explicitly."
    }
  }

  $envsThatResolveMode = @(
    'AwsArcanePerHost',
    'AwsSpacetimeOnly'
  )
  if ($envsThatResolveMode -contains $Environment -and
    -not [string]::IsNullOrWhiteSpace($intent.BenchmarkMode) -and $null -eq $normMode) {
    throw "Unrecognized BenchmarkMode '$($intent.BenchmarkMode)' in -BenchmarkPwshArgs or -ConfigFile (expected SpacetimeOnly or ArcanePlusSpacetime)."
  }

  switch ($Environment) {
    'AwsArcanePerHost' {
      $maxN = [int]$State.MaxArcaneClusters
      if ($maxN -lt 1) {
        throw "State MaxArcaneClusters is missing or invalid for AwsArcanePerHost (got '$($State.MaxArcaneClusters)')."
      }
      if ($null -eq $normMode -or $null -eq $intent.ArcaneClusterCount) {
        throw @"
Run intent is incomplete for Environment AwsArcanePerHost. This topology requires a fixed Arcane cluster layout.
Pass -BenchmarkPwshArgs that includes -ArcaneClusterCount and -BenchmarkMode ArcanePlusSpacetime, or a -ConfigFile whose JSON defines both (see configs/arcane_plus_spacetimedb.*.json).
Resolved: BenchmarkMode=$($intent.BenchmarkMode), ArcaneClusterCount=$($intent.ArcaneClusterCount).
"@
      }
      if ($normMode -ne 'ArcanePlusSpacetime') {
        throw "Environment AwsArcanePerHost requires -BenchmarkMode ArcanePlusSpacetime (resolved: '$normMode')."
      }
      $k = [int]$intent.ArcaneClusterCount
      if ($k -lt 1) {
        throw "ArcaneClusterCount must be >= 1 for ArcanePlusSpacetime (resolved: $k)."
      }
      if ($k -gt $maxN) {
        throw "ArcaneClusterCount $k exceeds provisioned MaxArcaneClusters $maxN for this state file. Re-run 'terraform apply -var=arcane_cluster_count=<N>' with a larger N, or use a smaller cluster count."
      }
    }
    'AwsSpacetimeOnly' {
      if ($null -ne $normMode -and $normMode -eq 'ArcanePlusSpacetime') {
        throw "Environment AwsSpacetimeOnly does not provision Redis or Arcane cluster hosts. Resolved BenchmarkMode is ArcanePlusSpacetime; use AwsArcanePerHost, or switch to a SpacetimeOnly config."
      }
    }
    default { }
  }
}
