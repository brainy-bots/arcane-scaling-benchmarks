[CmdletBinding()]
param(
    [string]$Tfvars = 'arcaneperhost.clusters_4.drivers_12.tfvars',
    [string]$Region = 'us-east-1',
    [int]$SsmWaitDeadlineSecs = 600
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$tfDir = Join-Path $repoRoot 'infra/terraform/aws_benchmark'
$stateOutTf = Join-Path $tfDir '.benchmark-aws-terraform.json'
$stateOutRoot = Join-Path $repoRoot '.benchmark-aws-terraform.json'

$tfCmd = (Get-Command terraform -ErrorAction SilentlyContinue) ?? (Get-Command terraform.exe -ErrorAction SilentlyContinue)
if (-not $tfCmd) {
    throw 'Setup-Benchmark-Aws.ps1: terraform not found on PATH. Install Terraform and ensure this shell resolves `terraform`.'
}
Set-Alias -Name terraform -Value $tfCmd.Source -Scope Script
# Windows terraform.exe can't resolve WSL /mnt/ paths — translate if needed.
$script:IsWslWindowsTf = $tfCmd.Source -match '\.exe$' -and $tfCmd.Source -like '/mnt/*'
function ConvertTo-TfPath([string]$p) {
    if ($script:IsWslWindowsTf -and $p -match '^/mnt/([a-z])/(.*)$') {
        return "$($Matches[1].ToUpper()):\$($Matches[2] -replace '/', '\')"
    }
    return $p
}
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw 'Setup-Benchmark-Aws.ps1: aws CLI not found on PATH. Install/configure AWS CLI first.'
}

$tfvarsPath = Join-Path $tfDir $Tfvars
if (-not (Test-Path -LiteralPath $tfvarsPath)) {
    throw "Setup-Benchmark-Aws.ps1: tfvars file not found: $tfvarsPath"
}

Write-Host "==> Setup-Benchmark-Aws.ps1"
Write-Host "    terraform module: $tfDir"
Write-Host "    tfvars:           $Tfvars"
Write-Host "    region:           $Region"

$tfDirNative = ConvertTo-TfPath $tfDir

Write-Host '==> terraform init'
terraform -chdir="$tfDirNative" init -input=false -upgrade=false | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'terraform init failed' }

Write-Host '==> terraform apply'
terraform -chdir="$tfDirNative" apply -var-file="$Tfvars" -var='operator_cidr_blocks=["0.0.0.0/0"]' -auto-approve
if ($LASTEXITCODE -ne 0) { throw 'terraform apply failed' }

terraform -chdir="$tfDirNative" output -json benchmark_state > $stateOutTf
if ($LASTEXITCODE -ne 0) { throw 'terraform output benchmark_state failed' }
Copy-Item -LiteralPath $stateOutTf -Destination $stateOutRoot -Force
Write-Host "    state JSON written:"
Write-Host "      $stateOutTf"
Write-Host "      $stateOutRoot"

$state = Get-Content -LiteralPath $stateOutRoot -Raw -Encoding utf8 | ConvertFrom-Json
$instanceIds = @(
    $state.ManagerInstanceId,
    $state.RedisInstanceId,
    $state.SpacetimeInstanceId
) + @($state.ClusterInstanceIds) + @($state.BenchmarkInstanceIds) |
    Where-Object { $_ } |
    Select-Object -Unique

$expected = $instanceIds.Count
if ($expected -lt 1) { throw 'No instances found in benchmark_state output' }

Write-Host "==> waiting for SSM agents to come online on $expected instances"
$deadline = (Get-Date).AddSeconds($SsmWaitDeadlineSecs)
while ((Get-Date) -lt $deadline) {
    $joined = $instanceIds -join ','
    $online = aws ssm describe-instance-information `
        --region $Region `
        --filters "Key=InstanceIds,Values=$joined" `
        --query 'length(InstanceInformationList)' `
        --output text 2>$null
    if (-not $online) { $online = 0 }
    Write-Host "    ($online/$expected Online)"
    if ([int]$online -eq $expected) {
        Write-Host "==> READY: $expected instances Online. You can now run the benchmark."
        exit 0
    }
    Start-Sleep -Seconds 10
}

throw "SSM did not reach $expected Online within ${SsmWaitDeadlineSecs}s."
