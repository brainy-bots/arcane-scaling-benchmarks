# Arcane-per-host topology with 4 clusters and 8 swarm driver instances.
# Pair with `configs/arcane_plus_spacetimedb.clusters_4.drivers_8.tick30_lat50_realistic.json`.
#
# Use:
#   terraform apply -var-file=arcaneperhost.clusters_4.drivers_8.tfvars
#
# Why 8 drivers: Run J at 4 drivers + cap=2000 hit the per-driver cap with
# the engine showing ZERO distress (lat ~16ms across all 16 tiers, 32% of
# 50ms gate budget). Engine ceiling at 8K aggregate CCU is unconfirmed but
# clearly above 8K. Run K (this config) doubles drivers, reduces per-driver
# cap to 1414 (= 4000 / sqrt(8)), targets aggregate 11,314 CCU.
#
# Cluster fleet stays at 4 × c7i.2xlarge — Run J cluster CPU was healthy at
# 8K, so we're testing whether engine handles 11K under the same fleet.
#
# Cost delta vs Run J: +4 drivers × $0.907/hr = +$3.63/hr while running.
# Total run cost ~$3.75 (25 min wall-clock).

aws_region                = "us-east-1"
topology                  = "AwsArcanePerHost"
arcane_cluster_count      = 4
arph_driver_count         = 8
instance_type             = "c7i.2xlarge"
arph_driver_instance_type = "c6in.4xlarge"
data_instance_type        = "t3.large"
redis_instance_type       = "c5n.large"
root_volume_gib           = 100
artifact_prefix           = "benchmark-aws"
remote_provision_profile  = "Full"
s3_bucket_force_destroy   = true

# Why c6in.4xlarge for drivers (vs c7i.4xlarge in single-driver runs):
#   - 16 vCPU (same as c7i.4xlarge — same cap derivation)
#   - 75 Gbps NIC burst (vs c7i.4xlarge's ~12.5 Gbps)
#   - Higher PPS ceiling — relevant for the swarm's drain-task storm where
#     each player has its own ws connection (~2,000 connections per driver
#     at the cap)
#   - $0.907/hr vs c7i.4xlarge's $0.857/hr — ~$0.05/hr extra
# The bottleneck on the older c7i.4xlarge driver was tokio scheduler at
# ~50% vCPU utilization, NOT raw CPU. NIC-optimized doesn't directly fix
# that, but it removes one possible co-bottleneck and makes the per-driver
# cap derivation cleaner.
