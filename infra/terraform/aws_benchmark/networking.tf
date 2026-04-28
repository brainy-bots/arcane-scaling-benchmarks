data "aws_availability_zones" "available" {
  count = var.subnet_id == "" ? 1 : 0
  state = "available"
}

resource "aws_vpc" "bench" {
  count                = var.subnet_id == "" ? 1 : 0
  cidr_block           = "10.0.0.0/24"
  enable_dns_support   = true  # Preserve default VPC behavior (required for DNS resolution)
  enable_dns_hostnames = true  # Preserve default VPC behavior (enables EC2 public DNS hostnames)

  tags = {
    Name      = "arcane-bench-tf"
    Project   = "arcane-benchmark"
    ManagedBy = "terraform"
  }
}

resource "aws_subnet" "bench" {
  count                   = var.subnet_id == "" ? 1 : 0
  vpc_id                  = aws_vpc.bench[0].id
  cidr_block              = "10.0.0.0/25"
  availability_zone       = data.aws_availability_zones.available[0].names[0]
  map_public_ip_on_launch = true

  tags = {
    Name      = "arcane-bench-tf"
    Project   = "arcane-benchmark"
    ManagedBy = "terraform"
  }
}

resource "aws_internet_gateway" "bench" {
  count  = var.subnet_id == "" ? 1 : 0
  vpc_id = aws_vpc.bench[0].id

  tags = {
    Name      = "arcane-bench-tf"
    Project   = "arcane-benchmark"
    ManagedBy = "terraform"
  }
}

resource "aws_route_table" "bench" {
  count  = var.subnet_id == "" ? 1 : 0
  vpc_id = aws_vpc.bench[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench[0].id
  }

  tags = {
    Name      = "arcane-bench-tf"
    Project   = "arcane-benchmark"
    ManagedBy = "terraform"
  }
}

resource "aws_route_table_association" "bench" {
  count          = var.subnet_id == "" ? 1 : 0
  subnet_id      = aws_subnet.bench[0].id
  route_table_id = aws_route_table.bench[0].id
}
