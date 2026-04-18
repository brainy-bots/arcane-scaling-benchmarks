variable "aws_region" {
  type        = string
  description = "AWS region for all resources."
  default     = "us-east-1"
}

variable "topology" {
  type        = string
  description = "AwsSpacetimeOnly (Spacetime + driver) or AwsArcanePerHost (Redis, Spacetime, manager, N clusters, driver)."
  default     = "AwsSpacetimeOnly"
  validation {
    condition     = contains(["AwsSpacetimeOnly", "AwsArcanePerHost"], var.topology)
    error_message = "topology must be AwsSpacetimeOnly or AwsArcanePerHost."
  }
}

variable "arcane_cluster_count" {
  type        = number
  description = "For AwsArcanePerHost only: number of arcane-cluster EC2 instances."
  default     = 2
  validation {
    condition     = var.topology != "AwsArcanePerHost" || (var.arcane_cluster_count >= 1 && var.arcane_cluster_count <= 32)
    error_message = "For AwsArcanePerHost, arcane_cluster_count must be between 1 and 32."
  }
}

variable "instance_type" {
  type        = string
  description = "EC2 type for the benchmark driver."
  default     = "c7i.2xlarge"
}

variable "data_instance_type" {
  type        = string
  description = "EC2 type for Spacetime / Redis / manager / cluster nodes."
  default     = "t3.large"
}

variable "root_volume_gib" {
  type        = number
  description = "Root gp3 volume size in GiB."
  default     = 100
}

variable "artifact_prefix" {
  type        = string
  description = "S3 key prefix for benchmark artifacts."
  default     = "benchmark-aws"
}

variable "remote_provision_profile" {
  type        = string
  description = "Remote provisioning profile consumed by Run-Benchmark-Aws.ps1. AwsArcanePerHost must be Full."
  default     = "Full"
  validation {
    condition     = contains(["Full", "SpacetimeOnly"], var.remote_provision_profile)
    error_message = "remote_provision_profile must be Full or SpacetimeOnly."
  }
  validation {
    condition     = var.topology != "AwsArcanePerHost" || var.remote_provision_profile == "Full"
    error_message = "AwsArcanePerHost requires remote_provision_profile = Full."
  }
}

variable "subnet_id" {
  type        = string
  description = "Leave empty to use the first subnet in the default VPC."
  default     = ""
}

variable "key_name" {
  type        = string
  description = "Optional EC2 key pair name for SSH."
  default     = ""
}

variable "s3_bucket_force_destroy" {
  type        = bool
  description = "When true, terraform destroy can delete a non-empty artifact bucket. Leave true so destroy always tears down cleanly for reproducibility."
  default     = true
}
