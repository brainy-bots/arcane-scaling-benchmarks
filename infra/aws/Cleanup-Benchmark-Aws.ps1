[CmdletBinding()]
param(
    [string]$Tfvars = 'arcaneperhost.clusters_4.drivers_12.tfvars',
    [string]$Region = 'us-east-1',
    [string]$ProjectTag = 'arcane-benchmark',
    [int]$MaxDestroyRetries = 2
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$tfDir = Join-Path $repoRoot 'infra/terraform/aws_benchmark'

$tfCmd = (Get-Command terraform -ErrorAction SilentlyContinue) ?? (Get-Command terraform.exe -ErrorAction SilentlyContinue)
if (-not $tfCmd) {
    throw 'Cleanup-Benchmark-Aws.ps1: terraform not found on PATH.'
}
Set-Alias -Name terraform -Value $tfCmd.Source -Scope Script
$script:IsWslWindowsTf = $tfCmd.Source -match '\.exe$' -and $tfCmd.Source -like '/mnt/*'
function ConvertTo-TfPath([string]$p) {
    if ($script:IsWslWindowsTf -and $p -match '^/mnt/([a-z])/(.*)$') {
        return "$($Matches[1].ToUpper()):\$($Matches[2] -replace '/', '\')"
    }
    return $p
}
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw 'Cleanup-Benchmark-Aws.ps1: aws CLI not found on PATH.'
}

$tfvarsPath = Join-Path $tfDir $Tfvars
if (-not (Test-Path -LiteralPath $tfvarsPath)) {
    throw "Cleanup-Benchmark-Aws.ps1: tfvars file not found: $tfvarsPath"
}

Write-Host "==> Cleanup-Benchmark-Aws.ps1"
Write-Host "    terraform module: $tfDir"
Write-Host "    tfvars:           $Tfvars"
Write-Host "    region:           $Region"
Write-Host "    project tag:      Project=$ProjectTag"

$tfDirNative = ConvertTo-TfPath $tfDir

$attempt = 1
while ($attempt -le ($MaxDestroyRetries + 1)) {
    Write-Host "==> terraform destroy (attempt $attempt/$($MaxDestroyRetries + 1))"
    terraform -chdir="$tfDirNative" destroy -var-file="$Tfvars" -var='operator_cidr_blocks=["0.0.0.0/0"]' -auto-approve
    if ($LASTEXITCODE -eq 0) {
        Write-Host '    terraform destroy succeeded'
        break
    }
    if ($attempt -gt $MaxDestroyRetries) {
        throw "terraform destroy failed after $attempt attempts"
    }
    Write-Host '    retry in 10s (transient AWS API or state-lock issue)...'
    Start-Sleep -Seconds 10
    $attempt++
}

Write-Host "==> AWS-side audit (Project=$ProjectTag, region=$Region)"
$leaks = @()

$ec2 = aws ec2 describe-instances `
    --region $Region `
    --filters "Name=tag:Project,Values=$ProjectTag" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" `
    --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`]|[0].Value]' `
    --output text 2>$null
if ($ec2) { $leaks += "EC2`n$ec2" }

$sg = aws ec2 describe-security-groups `
    --region $Region `
    --filters "Name=tag:Project,Values=$ProjectTag" `
    --query 'SecurityGroups[].[GroupId,GroupName]' `
    --output text 2>$null
if ($sg) { $leaks += "SecurityGroups`n$sg" }

$vpc = aws ec2 describe-vpcs `
    --region $Region `
    --filters "Name=tag:Project,Values=$ProjectTag" `
    --query 'Vpcs[].[VpcId,CidrBlock]' `
    --output text 2>$null
if ($vpc) { $leaks += "VPCs`n$vpc" }

$iam = aws iam list-roles `
    --query 'Roles[?starts_with(RoleName, `ArcaneBenchmark`)].[RoleName]' `
    --output text 2>$null
if ($iam) { $leaks += "IAMRoles`n$iam" }

$s3 = aws s3api list-buckets `
    --query 'Buckets[?starts_with(Name, `arcane-benchmark-artifacts-`)].[Name]' `
    --output text 2>$null
if ($s3) { $leaks += "S3Buckets`n$s3" }

if ($leaks.Count -eq 0) {
    Write-Host "==> CLEAN: terraform destroy succeeded AND no Project=$ProjectTag resources remain in $Region."
    exit 0
}

Write-Host "==> LEAK: resources still exist after destroy:" -ForegroundColor Red
$leaks | ForEach-Object { Write-Host $_ }
exit 1
