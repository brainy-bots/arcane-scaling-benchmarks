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

variable "arph_driver_count" {
  type        = number
  description = "For AwsArcanePerHost only: number of swarm driver instances. >1 enables multi-driver runs that fan out the player budget across N drivers; the harness aggregates per-driver FINAL lines into a strict-MAX gate. Each driver paces its joins so the manager sees single-driver join load regardless of N. Default 1 = historical single-driver behavior."
  default     = 1
  validation {
    condition     = var.topology != "AwsArcanePerHost" || (var.arph_driver_count >= 1 && var.arph_driver_count <= 16)
    error_message = "For AwsArcanePerHost, arph_driver_count must be between 1 and 16."
  }
}

variable "arph_driver_instance_type" {
  type        = string
  description = "EC2 type for the swarm driver(s). Defaults to instance_type (the cluster type) so single-driver back-compat holds. Override to a NIC-optimized class (c6in.*, c5n.*) when running multi-driver — the swarm is broadcast-inbound-heavy and benefits from PPS + NIC headroom even when CPU isn't the bottleneck."
  default     = ""
}

variable "instance_type" {
  type        = string
  description = "EC2 type for the benchmark driver."
  default     = "c7i.2xlarge"
}

variable "data_instance_type" {
  type        = string
  description = "EC2 type for Spacetime / manager nodes (and Redis, unless overridden by redis_instance_type)."
  default     = "t3.large"
}

variable "redis_instance_type" {
  type        = string
  description = "EC2 type for Redis. Defaults to data_instance_type. Override to a NIC-optimized class (c5n.*, c6in.*, c7gn.*) when inter-cluster pub/sub bandwidth becomes the wall — see BENCHMARK_JOURNAL.md 2026-04-27 entry for the math."
  default     = ""
}

locals {
  # Effective Redis instance type — falls back to data_instance_type when the
  # operator hasn't explicitly chosen a NIC-optimized one. Keeps existing
  # tfvars files working unchanged.
  redis_instance_type_effective = var.redis_instance_type != "" ? var.redis_instance_type : var.data_instance_type

  # Effective driver instance type — falls back to instance_type (shared with
  # the cluster fleet) so single-driver tfvars don't need updating. Multi-driver
  # tfvars override to NIC-optimized (c6in.*, c5n.*) without changing cluster
  # type. The swarm is broadcast-inbound-heavy and benefits from PPS + NIC
  # headroom even when CPU isn't the bottleneck.
  arph_driver_instance_type_effective = var.arph_driver_instance_type != "" ? var.arph_driver_instance_type : var.instance_type
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
  description = "Leave empty to use the stack-created VPC and subnet. Set to a specific subnet ID to place instances in an existing subnet instead."
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

variable "operator_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the orchestrator's HTTP API (port 8090) on the manager EC2. The benchmark controller runs from the operator's laptop and connects over the public internet to this endpoint. Empty list = no external access (orchestrator is internal-only). Set to your laptop's public IP /32 for a controller run."
  default     = []
}
