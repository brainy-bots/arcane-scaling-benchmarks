# SpacetimeDB-only topology — one SpacetimeDB node + one driver node, no
# Redis / manager / clusters. Pair with `configs/spacetimedb_only*.json` on
# the benchmark run command.
#
# Use:
#   terraform apply -var-file=spacetimeonly.tfvars
#
# This file is intentionally committed and never edited per run — the whole
# point is that the topology is selected by the command's -var-file, not by
# mutating a shared terraform.tfvars in place. Add a sibling file per
# additional environment rather than changing values here.

aws_region               = "us-east-1"
topology                 = "AwsSpacetimeOnly"
arcane_cluster_count     = 0
instance_type            = "c7i.2xlarge"
data_instance_type       = "t3.large"
root_volume_gib          = 100
artifact_prefix          = "benchmark-aws"
remote_provision_profile = "Full"
s3_bucket_force_destroy  = true
