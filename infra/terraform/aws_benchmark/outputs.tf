locals {
  bench_state_base = {
    Environment              = var.topology
    Region                   = var.aws_region
    SecurityGroupId          = aws_security_group.bench.id
    CreatedSecurityGroup     = true
    RemoteRoot               = local.remote_root
    SubnetId                 = local.subnet_id
    IamInstanceProfileName   = local.iam_instance_profile_name
    RunId                    = local.setup_run_id
    ArtifactBucket           = local.artifact_bucket
    ArtifactPrefix           = var.artifact_prefix
    RemoteProvisionProfile   = var.remote_provision_profile
  }

  bench_state_topology = local.is_stonly ? {
    SpacetimeInstanceId = aws_instance.stonly_spacetime[0].id
    BenchmarkInstanceId = aws_instance.stonly_driver[0].id
    } : {
    RedisInstanceId     = aws_instance.arph_redis[0].id
    SpacetimeInstanceId = aws_instance.arph_spacetime[0].id
    ManagerInstanceId   = aws_instance.arph_manager[0].id
    ClusterInstanceIds  = [for i in aws_instance.arph_cluster : i.id]
    ClusterIds          = [for u in random_uuid.cluster : u.result]
    MaxArcaneClusters   = var.arcane_cluster_count
    BenchmarkInstanceId = aws_instance.arph_driver[0].id
  }
}

output "benchmark_state" {
  description = "State JSON consumed by Run-Benchmark-Aws.ps1 via -StatePath (provision RunId, instance IDs, bucket, profile)."
  value       = merge(local.bench_state_base, local.bench_state_topology)
}

output "driver_instance_id" {
  description = "EC2 id of the benchmark driver (SSM target)."
  value       = local.is_stonly ? aws_instance.stonly_driver[0].id : aws_instance.arph_driver[0].id
}

output "security_group_id" {
  value = aws_security_group.bench.id
}

output "artifact_bucket" {
  value = local.artifact_bucket
}
