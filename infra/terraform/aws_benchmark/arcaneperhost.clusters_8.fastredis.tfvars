# Arcane-per-host topology with 8 clusters and a NIC-optimized Redis instance.
# Pair with `configs/arcane_plus_spacetimedb.clusters_8.tick30_realistic.json`.
#
# Use:
#   terraform apply -var-file=arcaneperhost.clusters_8.fastredis.tfvars
#
# Why 8 clusters: tests whether per-cluster broadcast pipeline relief lifts
# the 4,750 realistic ceiling (Run F at clusters_4). Per-cluster outbound
# scales as P²/N, so doubling N halves per-cluster outbound at the same P.
#
# Why c5n.large for Redis: at 8 clusters under realistic-payload broadcasts,
# inter-cluster Redis pub/sub fan-out is N(N-1)=56 deliveries per publish,
# 4.7× more cross-traffic than at 4 clusters. The math suggests t3.large is
# still fine (~10 MB/s aggregate vs ~200 MB/s sustained), but c5n.large gives
# 25 Gbps headroom and removes Redis NIC from any analysis at this size.
# Cost delta: ~$0.025/hr extra (c5n.large $0.108 vs t3.large $0.083).

aws_region               = "us-east-1"
topology                 = "AwsArcanePerHost"
arcane_cluster_count     = 8
instance_type            = "c7i.2xlarge"
data_instance_type       = "t3.large"
redis_instance_type      = "c5n.large"
root_volume_gib          = 100
artifact_prefix          = "benchmark-aws"
remote_provision_profile = "Full"
s3_bucket_force_destroy  = true
