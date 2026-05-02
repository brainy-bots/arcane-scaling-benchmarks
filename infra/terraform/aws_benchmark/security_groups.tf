locals {
  arph_ingress = [
    { from = 6379, to = 6379 },
    { from = 3000, to = 3000 },
    { from = 8081, to = 8081 },
    { from = 8088, to = 8088 }, # orchestrator driver-WS
    { from = 8090, to = 8110 }, # cluster WS + orchestrator HTTP API
  ]
}

resource "aws_security_group" "bench" {
  name_prefix = "arcane-bench-tf-"
  description = "Arcane benchmark (Terraform)"
  vpc_id      = local.vpc_id

  dynamic "ingress" {
    for_each = local.is_stonly ? [1] : []
    content {
      description = "SpacetimeDB (AwsSpacetimeOnly)"
      from_port   = 3000
      to_port     = 3000
      protocol    = "tcp"
      self        = true
    }
  }

  dynamic "ingress" {
    for_each = local.is_arph ? local.arph_ingress : []
    content {
      description = "Redis / Spacetime / manager / cluster WS (AwsArcanePerHost)"
      from_port   = ingress.value.from
      to_port     = ingress.value.to
      protocol    = "tcp"
      self        = true
    }
  }

  # Orchestrator HTTP API (controller submission + telemetry SSE) reachable
  # from the operator's CIDR. The orchestrator process binds 0.0.0.0:8090
  # on the manager EC2; the security group is the actual access control.
  dynamic "ingress" {
    for_each = local.is_arph && length(var.operator_cidr_blocks) > 0 ? [1] : []
    content {
      description = "Orchestrator HTTP API for controller (AwsArcanePerHost)"
      from_port   = 8090
      to_port     = 8090
      protocol    = "tcp"
      cidr_blocks = var.operator_cidr_blocks
    }
  }

  # Orchestrator driver-WS port — internal-only (drivers reach it via the
  # manager's private IP). Already covered by the 8090-8110 self-rule above
  # at port 8088, so nothing extra here.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "arcane-bench-tf"
    Project   = "arcane-benchmark"
    ManagedBy = "terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}
