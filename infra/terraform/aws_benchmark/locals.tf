locals {
  is_stonly = var.topology == "AwsSpacetimeOnly"
  is_arph   = var.topology == "AwsArcanePerHost"

  # Stable pick: AWS returns subnet ids in arbitrary order; sort avoids churn if the API order changes.
  subnet_id = var.subnet_id != "" ? var.subnet_id : sort(data.aws_subnets.default[0].ids)[0]
  vpc_id    = var.subnet_id != "" ? data.aws_subnet.selected[0].vpc_id : data.aws_vpc.default[0].id

  account_id = data.aws_caller_identity.current.account_id
  region_lc  = lower(var.aws_region)

  bucket_name = "arcane-benchmark-artifacts-${local.account_id}-${local.region_lc}"

  artifact_bucket           = aws_s3_bucket.artifacts.bucket
  iam_instance_profile_name = aws_iam_instance_profile.ec2.name

  # Apply-time stamp (stable for stack lifetime). Used in instance Name tags and state RunId.
  setup_run_id = formatdate("YYYYMMDD_hhmmss", time_static.provision.rfc3339)

  remote_root = "/opt/arcane-scaling-benchmarks"
}
