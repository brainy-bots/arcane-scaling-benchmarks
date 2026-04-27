# Arcane-per-host topology with 4 clusters and 4 swarm driver instances.
# Pair with `configs/arcane_plus_spacetimedb.clusters_4.drivers_4.tick30_lat50.json`.
#
# Use:
#   terraform apply -var-file=arcaneperhost.clusters_4.drivers_4.tfvars
#
# Why 4 drivers: previously published numbers (4,750 @ 100 ms) were
# driver-limited — a single c7i.4xlarge swarm pegged at ~800-900% CPU well
# before cluster CPU bound. Multi-driver fans the player budget across N
# independent swarm hosts. The harness aggregates per-driver FINAL lines
# into a strict-MAX gate (any driver fails → tier fails; headline =
# MAX(driver_lat_avg_ms)). Each driver paces its joins via the swarm's
# --inter-spawn-delay-ms flag so the manager sees single-driver join load
# regardless of N. See docs/BENCHMARK_JOURNAL.md and tasks #79–#86.
#
# Why c5n.large Redis: same reason as clusters_8 — at 4 drivers the cluster
# fleet sees real load, so inter-cluster pub/sub headroom matters. NIC-optimized
# Redis removes one variable from the next set of measurements.

aws_region               = "us-east-1"
topology                 = "AwsArcanePerHost"
arcane_cluster_count     = 4
arph_driver_count        = 4
instance_type            = "c7i.2xlarge"
data_instance_type       = "t3.large"
redis_instance_type      = "c5n.large"
root_volume_gib          = 100
artifact_prefix          = "benchmark-aws"
remote_provision_profile = "Full"
s3_bucket_force_destroy  = true
