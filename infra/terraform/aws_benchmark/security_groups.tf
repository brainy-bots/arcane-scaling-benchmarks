locals {
  arph_ingress = [
    { from = 6379, to = 6379 },
    { from = 3000, to = 3000 },
    { from = 8081, to = 8081 },
    { from = 8090, to = 8110 },
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
