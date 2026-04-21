# Arcane-per-host topology with 4 clusters — Redis + SpacetimeDB + manager +
# 4 cluster nodes + driver. Pair with
# `configs/arcane_plus_spacetimedb.clusters_8.json` on the benchmark run
# command.
#
# Use:
#   terraform apply -var-file=arcaneperhost.clusters_8.tfvars
#
# This file is intentionally committed and never edited per run — the topology
# is selected by the command's -var-file, not by mutating a shared
# terraform.tfvars in place. Add a sibling file per additional cluster count
# rather than changing values here.

aws_region               = "us-east-1"
topology                 = "AwsArcanePerHost"
arcane_cluster_count     = 8
instance_type            = "c7i.2xlarge"
data_instance_type       = "t3.large"
root_volume_gib          = 100
artifact_prefix          = "benchmark-aws"
remote_provision_profile = "Full"
s3_bucket_force_destroy  = true
