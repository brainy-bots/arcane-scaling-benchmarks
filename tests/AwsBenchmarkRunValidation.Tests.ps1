BeforeAll {
  $script:ValPath = Join-Path $PSScriptRoot '..\infra\aws\lib\AwsBenchmarkRunValidation.ps1'
  . $ValPath
}

Describe 'Assert-BenchmarkPwshArgsCompatibleWithRemoteAwsTemplate' {
  It 'allows empty args' {
    { Assert-BenchmarkPwshArgsCompatibleWithRemoteAwsTemplate -Environment AwsArcanePerHost -BenchmarkPwshArgs '' } |
      Should -Not -Throw
  }

  It 'rejects -Environment in args' {
    {
      Assert-BenchmarkPwshArgsCompatibleWithRemoteAwsTemplate -Environment AwsArcanePerHost `
        -BenchmarkPwshArgs '-Environment Local -ConfigFile ./x.json'
    } | Should -Throw '*must not include -Environment*'
  }

  It 'rejects -BenchmarkMode for AwsSpacetimeOnly' {
    {
      Assert-BenchmarkPwshArgsCompatibleWithRemoteAwsTemplate -Environment AwsSpacetimeOnly `
        -BenchmarkPwshArgs '-BenchmarkMode SpacetimeOnly'
    } | Should -Throw '*must not include -BenchmarkMode*'
  }

  It 'allows -BenchmarkMode for AwsArcanePerHost' {
    { Assert-BenchmarkPwshArgsCompatibleWithRemoteAwsTemplate -Environment AwsArcanePerHost `
        -BenchmarkPwshArgs '-BenchmarkMode ArcanePlusSpacetime -ArcaneClusterCount 2' } |
      Should -Not -Throw
  }

  It 'rejects -Environment when it is the last token' {
    { Assert-BenchmarkPwshArgsCompatibleWithRemoteAwsTemplate -Environment AwsArcanePerHost `
        -BenchmarkPwshArgs '-ConfigFile ./x.json -Environment' } |
      Should -Throw '*must not include -Environment*'
  }
}

Describe 'Get-AllBenchmarkPwshArgsConfigFilePaths' {
  It 'collects multiple -ConfigFile paths in order' {
    $paths = Get-AllBenchmarkPwshArgsConfigFilePaths -BenchmarkPwshArgs '-ConfigFile first.json -ConfigFile second.json'
    @($paths).Count | Should -Be 2
    $paths[0] | Should -Be 'first.json'
    $paths[1] | Should -Be 'second.json'
  }

  It 'uses the last -ConfigFile for resolved intent' {
    $a = Join-Path $TestDrive 'first.json'
    @{ BenchmarkMode = 'SpacetimeOnly' } | ConvertTo-Json | Set-Content -LiteralPath $a -Encoding utf8
    $b = Join-Path $TestDrive 'second.json'
    @{ BenchmarkMode = 'ArcanePlusSpacetime'; ArcaneClusterCount = 2 } | ConvertTo-Json | Set-Content -LiteralPath $b -Encoding utf8
    $aFull = (Resolve-Path -LiteralPath $a).Path
    $bFull = (Resolve-Path -LiteralPath $b).Path
    $line = '-ConfigFile "{0}" -ConfigFile "{1}"' -f $aFull, $bFull
    $intent = Get-BenchmarkRunIntentFromBenchmarkPwshArgs -BenchmarkPwshArgs $line -ConfigSearchBasePaths @($TestDrive)
    $intent.BenchmarkMode | Should -Be 'ArcanePlusSpacetime'
    $intent.ArcaneClusterCount | Should -Be 2
  }
}

Describe 'AwsBenchmarkRunValidation' {
  It 'prefers BenchmarkMode from config over CLI when the key exists in JSON' {
    $cfg = Join-Path $TestDrive 'c.json'
    @{ BenchmarkMode = 'SpacetimeOnly'; ArcaneClusterCount = 2 } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding utf8
    $cfg = (Resolve-Path -LiteralPath $cfg).Path
    $argsLine = '-ConfigFile "{0}" -BenchmarkMode ArcanePlusSpacetime -ArcaneClusterCount 4' -f $cfg
    $intent = Get-BenchmarkRunIntentFromBenchmarkPwshArgs -BenchmarkPwshArgs $argsLine `
      -ConfigSearchBasePaths @($TestDrive)
    $intent.BenchmarkMode | Should -Be 'SpacetimeOnly'
    $intent.ArcaneClusterCount | Should -Be 2
  }

  It 'uses CLI for ArcaneClusterCount when JSON omits the property' {
    $cfg = Join-Path $TestDrive 'm.json'
    @{ BenchmarkMode = 'ArcanePlusSpacetime' } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding utf8
    $cfgFull = (Resolve-Path -LiteralPath $cfg).Path
    $argsLine = '-ConfigFile "{0}" -ArcaneClusterCount 3' -f $cfgFull
    $intent = Get-BenchmarkRunIntentFromBenchmarkPwshArgs -BenchmarkPwshArgs $argsLine `
      -ConfigSearchBasePaths @($TestDrive)
    $intent.ArcaneClusterCount | Should -Be 3
  }

  It 'fails when ArcaneClusterCount exceeds MaxArcaneClusters' {
    $cfg = Join-Path $TestDrive 'k.json'
    @{ BenchmarkMode = 'ArcanePlusSpacetime'; ArcaneClusterCount = 4 } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding utf8
    $cfgFull = (Resolve-Path -LiteralPath $cfg).Path
    $st = [pscustomobject]@{ MaxArcaneClusters = 2 }
    {
      Assert-BenchmarkRunMatchesAwsEnvironment -Environment AwsArcanePerHost -State $st `
        -BenchmarkPwshArgs ('-ConfigFile "{0}"' -f $cfgFull) -RemoteProvisionProfile Full `
        -ConfigSearchBasePaths @($TestDrive)
    } | Should -Throw -ExceptionType ([System.Management.Automation.RuntimeException])
  }

  It 'allows ArcaneClusterCount equal to MaxArcaneClusters' {
    $cfg = Join-Path $TestDrive 'ok.json'
    @{ BenchmarkMode = 'ArcanePlusSpacetime'; ArcaneClusterCount = 2 } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding utf8
    $cfgFull = (Resolve-Path -LiteralPath $cfg).Path
    $st = [pscustomobject]@{ MaxArcaneClusters = 2 }
    {
      Assert-BenchmarkRunMatchesAwsEnvironment -Environment AwsArcanePerHost -State $st `
        -BenchmarkPwshArgs ('-ConfigFile "{0}"' -f $cfgFull) -RemoteProvisionProfile Full `
        -ConfigSearchBasePaths @($TestDrive)
    } | Should -Not -Throw
  }

  It 'rejects ArcanePlusSpacetime on AwsSpacetimeOnly' {
    $cfg = Join-Path $TestDrive 'a.json'
    @{ BenchmarkMode = 'ArcanePlusSpacetime'; ArcaneClusterCount = 1 } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding utf8
    $cfgFull = (Resolve-Path -LiteralPath $cfg).Path
    {
      Assert-BenchmarkRunMatchesAwsEnvironment -Environment AwsSpacetimeOnly -State @{} `
        -BenchmarkPwshArgs ('-ConfigFile "{0}"' -f $cfgFull) -RemoteProvisionProfile Full `
        -ConfigSearchBasePaths @($TestDrive)
    } | Should -Throw -ExceptionType ([System.Management.Automation.RuntimeException])
  }

  It 'allows SpacetimeOnly on AwsSpacetimeOnly' {
    $cfg = Join-Path $TestDrive 'st.json'
    @{ BenchmarkMode = 'SpacetimeOnly' } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding utf8
    $cfgFull = (Resolve-Path -LiteralPath $cfg).Path
    {
      Assert-BenchmarkRunMatchesAwsEnvironment -Environment AwsSpacetimeOnly -State @{} `
        -BenchmarkPwshArgs ('-ConfigFile "{0}"' -f $cfgFull) -RemoteProvisionProfile Full `
        -ConfigSearchBasePaths @($TestDrive)
    } | Should -Not -Throw
  }

  It 'throws for unrecognized BenchmarkMode in config' {
    $cfg = Join-Path $TestDrive 'badmode.json'
    @{ BenchmarkMode = 'NotARealMode' } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding utf8
    $cfgFull = (Resolve-Path -LiteralPath $cfg).Path
    {
      Assert-BenchmarkRunMatchesAwsEnvironment -Environment AwsSpacetimeOnly -State @{} `
        -BenchmarkPwshArgs ('-ConfigFile "{0}"' -f $cfgFull) -RemoteProvisionProfile Full `
        -ConfigSearchBasePaths @($TestDrive)
    } | Should -Throw '*Unrecognized BenchmarkMode*'
  }

  It 'rejects SpacetimeOnly intent on AwsArcanePerHost' {
    $cfg = Join-Path $TestDrive 'stonly.json'
    @{ BenchmarkMode = 'SpacetimeOnly' } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding utf8
    $cfgFull = (Resolve-Path -LiteralPath $cfg).Path
    $st = [pscustomobject]@{ MaxArcaneClusters = 2 }
    {
      Assert-BenchmarkRunMatchesAwsEnvironment -Environment AwsArcanePerHost -State $st `
        -BenchmarkPwshArgs ('-ConfigFile "{0}" -ArcaneClusterCount 1' -f $cfgFull) -RemoteProvisionProfile Full `
        -ConfigSearchBasePaths @($TestDrive)
    } | Should -Throw '*requires*ArcanePlusSpacetime*'
  }

  It 'rejects AwsArcanePerHost when MaxArcaneClusters is zero' {
    $cfg = Join-Path $TestDrive 'arc2.json'
    @{ BenchmarkMode = 'ArcanePlusSpacetime'; ArcaneClusterCount = 1 } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding utf8
    $cfgFull = (Resolve-Path -LiteralPath $cfg).Path
    $st = [pscustomobject]@{ MaxArcaneClusters = 0 }
    {
      Assert-BenchmarkRunMatchesAwsEnvironment -Environment AwsArcanePerHost -State $st `
        -BenchmarkPwshArgs ('-ConfigFile "{0}"' -f $cfgFull) -RemoteProvisionProfile Full `
        -ConfigSearchBasePaths @($TestDrive)
    } | Should -Throw '*MaxArcaneClusters*'
  }
}
