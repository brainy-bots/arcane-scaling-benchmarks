aws_region           = "us-east-1"
topology             = "AwsArcanePerHost"
arcane_cluster_count = 8
arph_driver_count    = 20

# Bigger NIC for clusters: 50 Gbps (up from 40 Gbps on c6in.2xlarge).
# Outbound is the binding constraint with 1 KB user_data — O(N²) per cluster.
instance_type = "c6in.4xlarge"

# Driver stays the same class — inbound scales O(N/D × frame_size).
arph_driver_instance_type = "c6in.4xlarge"

# Data-plane sidecars unchanged.
data_instance_type  = "t3.large"
redis_instance_type = "c5n.large"

root_volume_gib          = 100
artifact_prefix          = "benchmark-aws"
remote_provision_profile = "Full"
s3_bucket_force_destroy  = true
