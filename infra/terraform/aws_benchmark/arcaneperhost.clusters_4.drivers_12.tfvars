aws_region                = "us-east-1"
topology                  = "AwsArcanePerHost"
arcane_cluster_count      = 4
arph_driver_count         = 12

# Keep cluster nodes NIC-optimized for this A/B phase.
instance_type             = "c6in.2xlarge"

# Driver remains NIC-optimized and high-core.
arph_driver_instance_type = "c6in.4xlarge"

# Data-plane sidecars unchanged from prior successful runs.
data_instance_type        = "t3.large"
redis_instance_type       = "c5n.large"

root_volume_gib           = 100
artifact_prefix           = "benchmark-aws"
remote_provision_profile  = "Full"
s3_bucket_force_destroy   = true
