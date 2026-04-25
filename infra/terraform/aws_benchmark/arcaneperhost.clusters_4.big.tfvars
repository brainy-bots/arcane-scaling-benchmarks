# Arcane-per-host topology with 4 clusters — same fleet shape as
# `arcaneperhost.clusters_4.tfvars` but every server-side node
# (Redis + SpacetimeDB + manager + 4 cluster nodes) upgraded from
# t3.large (2 vCPU burstable, 8 GiB) to c7i.2xlarge (8 vCPU
# sustained, 16 GiB). Driver stays at c7i.2xlarge.
#
# Purpose: test whether the bounded-rayon parallel pre-encoding
# (arcane#40/#41) actually wins when cluster nodes have cores to
# spare. On t3.large the rayon pool fights tokio for the same 2
# vCPUs and the bounded run ceilinged at 5750 — *below* the serial
# baseline of 6000. With 8 sustained vCPUs per cluster node, rayon
# has room to spread without starving the WS server tasks.
#
# Decision rule: if ceiling lifts meaningfully past 6000, keep
# bounded-rayon and run the full sweep (clusters_2/4/6) to publish
# new numbers. If not, revert arcane#40/#41.
#
# Pair with `configs/arcane_plus_spacetimedb.clusters_4.big.json`
# (sweep starts at 5750 — the tier just before the bounded-rayon
# t3.large run failed at 6000).
#
# Use:
#   terraform apply -var-file=arcaneperhost.clusters_4.big.tfvars
#
# Commit rule: one file per scenario, never edited in place. If you
# need a different cluster size or count, add a new sibling rather
# than mutating this one.

aws_region               = "us-east-1"
topology                 = "AwsArcanePerHost"
arcane_cluster_count     = 4
instance_type            = "c7i.2xlarge"
data_instance_type       = "c7i.2xlarge"
root_volume_gib          = 100
artifact_prefix          = "benchmark-aws"
remote_provision_profile = "Full"
s3_bucket_force_destroy  = true
