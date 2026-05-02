locals {
  bench_state_base = {
    Environment            = var.topology
    Region                 = var.aws_region
    SecurityGroupId        = aws_security_group.bench.id
    CreatedSecurityGroup   = true
    RemoteRoot             = local.remote_root
    SubnetId               = local.subnet_id
    IamInstanceProfileName = local.iam_instance_profile_name
    RunId                  = local.setup_run_id
    ArtifactBucket         = local.artifact_bucket
    ArtifactPrefix         = var.artifact_prefix
    RemoteProvisionProfile = var.remote_provision_profile
  }

  # Per-key dispatch. Keeping the object shape constant across topologies lets
  # Terraform unify types (each key becomes nullable-string / nullable-list).
  # The empty-tuple indexing is guarded by try() because the inactive side
  # references an empty aws_instance.* tuple whose [0] has no type.
  bench_state_topology = {
    SpacetimeInstanceId = local.is_stonly ? try(aws_instance.stonly_spacetime[0].id, null) : try(aws_instance.arph_spacetime[0].id, null)
    # BenchmarkInstanceId stays for back-compat — it returns the FIRST driver
    # so single-driver harness paths keep working unchanged. Multi-driver
    # callers use BenchmarkInstanceIds (plural list) and fan SSM commands
    # across all of them. ArphDriverCount is the authoritative count.
    BenchmarkInstanceId  = local.is_stonly ? try(aws_instance.stonly_driver[0].id, null) : try(aws_instance.arph_driver[0].id, null)
    BenchmarkInstanceIds = local.is_stonly ? (try(aws_instance.stonly_driver[0].id, null) != null ? [aws_instance.stonly_driver[0].id] : []) : [for i in aws_instance.arph_driver : i.id]
    ArphDriverCount      = local.is_arph ? var.arph_driver_count : 0
    RedisInstanceId      = local.is_arph ? try(aws_instance.arph_redis[0].id, null) : null
    ManagerInstanceId    = local.is_arph ? try(aws_instance.arph_manager[0].id, null) : null
    ManagerPublicDns     = local.is_arph ? try(aws_instance.arph_manager[0].public_dns, null) : null
    ManagerPublicIp      = local.is_arph ? try(aws_instance.arph_manager[0].public_ip, null) : null
    ManagerPrivateIp     = local.is_arph ? try(aws_instance.arph_manager[0].private_ip, null) : null
    ClusterInstanceIds   = local.is_arph ? [for i in aws_instance.arph_cluster : i.id] : []
    ClusterPrivateIps    = local.is_arph ? [for i in aws_instance.arph_cluster : i.private_ip] : []
    ClusterIds           = local.is_arph ? [for u in random_uuid.cluster : u.result] : []
    MaxArcaneClusters    = local.is_arph ? var.arcane_cluster_count : 0
    # Orchestrator endpoint — the benchmark-controller (operator's laptop)
    # connects here for command submission + telemetry SSE. The orchestrator
    # process runs on the manager EC2 alongside arcane-manager. Drivers reach
    # it via ManagerPrivateIp + OrchestratorDriverPort over the VPC.
    OrchestratorPublicDns  = local.is_arph ? try(aws_instance.arph_manager[0].public_dns, null) : null
    OrchestratorHttpPort   = 8090
    OrchestratorDriverPort = 8088
  }
}

output "benchmark_state" {
  description = "State JSON consumed by Run-Benchmark-Aws.ps1 via -StatePath (provision RunId, instance IDs, bucket, profile)."
  value       = merge(local.bench_state_base, local.bench_state_topology)
}

output "driver_instance_id" {
  description = "EC2 id of the benchmark driver (SSM target)."
  value       = local.is_stonly ? try(aws_instance.stonly_driver[0].id, null) : try(aws_instance.arph_driver[0].id, null)
}

output "security_group_id" {
  value = aws_security_group.bench.id
}

output "artifact_bucket" {
  value = local.artifact_bucket
}
