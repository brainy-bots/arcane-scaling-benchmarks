# Shared JSONC reader used by the local harness (Merge-ConfigFileParameters in
# BenchmarkHarnessHelpers.ps1) and the AWS pre-SSM validator
# (AwsBenchmarkRunValidation.ps1). Both places call this so the config files
# under configs/ can carry human-readable `//` comments that explain every
# field without either reader drifting from the other.
#
# Strips `//` line comments and `/* */` block comments while preserving the
# contents of string literals — important because a JSON string may legitimately
# contain `//` (e.g. a URL) and that must not be stripped.

function ConvertFrom-BenchmarkConfigJsonc {
  param([Parameter(Mandatory)][string]$Text)
  $clean = [regex]::Replace($Text, '("(?:\\.|[^"\\])*")|(//[^\r\n]*)|(/\*[\s\S]*?\*/)', {
    param($m)
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return ''
  })
  return ($clean | ConvertFrom-Json -ErrorAction Stop)
}
