# Arcane-per-host topology with 4 clusters — same fleet shape as
# `arcaneperhost.clusters_4.tfvars` (Redis + SpacetimeDB + manager +
# 4 cluster nodes all on t3.large), but with the swarm driver
# upgraded from c7i.2xlarge (8 vCPU) to c7i.4xlarge (16 vCPU).
#
# Purpose: isolate whether the 4-cluster ceiling / latency-climb /
# broadcast-lag behavior is driver-limited. In the 2026-04-22
# bounded-rayon runs the driver showed sustained 700-800% CPU
# across the 8 vCPU box — a plausible bottleneck whose effect
# propagates via TCP backpressure into the cluster's broadcast
# channel. Doubling driver cores tests that hypothesis without
# changing cluster hardware.
#
# Pair with `configs/arcane_plus_spacetimedb.clusters_4.json`.
#
# Use:
#   terraform apply -var-file=arcaneperhost.clusters_4.big_driver.tfvars
#
# Commit rule: one file per scenario, never edited in place. If you
# need a different driver size or cluster count, add a new sibling
# rather than mutating this one.

aws_region               = "us-east-1"
topology                 = "AwsArcanePerHost"
arcane_cluster_count     = 4
instance_type            = "c7i.4xlarge"
data_instance_type       = "t3.large"
root_volume_gib          = 100
artifact_prefix          = "benchmark-aws"
remote_provision_profile = "Full"
s3_bucket_force_destroy  = true
