BeforeAll {
  $h = Join-Path $PSScriptRoot '..\scripts\cloud\Common\AwsHelpers.ps1'
  . $h
}

Describe 'Escape-BashDoubleQuoted' {
  It 'returns empty string for null' {
    Escape-BashDoubleQuoted $null | Should -Be ''
  }

  It 'escapes characters that break double-quoted bash strings' {
    Escape-BashDoubleQuoted 'a\b' | Should -Be 'a\\b'
    Escape-BashDoubleQuoted 'say "hi"' | Should -Be 'say \"hi\"'
    Escape-BashDoubleQuoted 'echo $PATH' | Should -Be 'echo \$PATH'
    Escape-BashDoubleQuoted 'cmd `sub`' | Should -Be 'cmd \`sub\`'
  }

  It 'handles combined special characters' {
    Escape-BashDoubleQuoted '\$"`' | Should -Be '\\\$\"\`'
  }
}

Describe 'Get-AwsCliFileUri' {
  It 'returns an AWS-CLI-compatible file URI including the target file name' {
    $tmp = Join-Path $TestDrive 'params.json'
    '{}' | Set-Content -LiteralPath $tmp
    $uri = Get-AwsCliFileUri $tmp
    $uri | Should -Match '^file://'
    $uri | Should -Match 'params\.json'
    if ($tmp -match '^[A-Za-z]:\\') {
      $uri | Should -Match '^file://[A-Za-z]:\\'
    } else {
      $uri | Should -Match '^file:///'
    }
  }
}
