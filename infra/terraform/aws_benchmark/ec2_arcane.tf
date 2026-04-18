resource "random_uuid" "cluster" {
  count = local.is_arph ? var.arcane_cluster_count : 0
}

resource "aws_instance" "arph_redis" {
  count = local.is_arph ? 1 : 0

  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type               = var.data_instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.bench.id]
  iam_instance_profile        = local.iam_instance_profile_name
  user_data                   = file("${path.module}/user_data/docker_only.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_gib
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  key_name = var.key_name != "" ? var.key_name : null

  tags = {
    Name                       = "arcane-bench-arph-redis-${local.setup_run_id}"
    ArcaneBenchmarkEnvironment = var.topology
    ArcaneBenchmarkRole        = "redis"
    Project                    = "arcane-benchmark"
    ManagedBy                  = "terraform"
  }
}

resource "aws_instance" "arph_spacetime" {
  count = local.is_arph ? 1 : 0

  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type               = var.data_instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.bench.id]
  iam_instance_profile        = local.iam_instance_profile_name
  user_data                   = file("${path.module}/user_data/docker_only.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_gib
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  key_name = var.key_name != "" ? var.key_name : null

  tags = {
    Name                       = "arcane-bench-arph-spacetime-${local.setup_run_id}"
    ArcaneBenchmarkEnvironment = var.topology
    ArcaneBenchmarkRole        = "spacetime"
    Project                    = "arcane-benchmark"
    ManagedBy                  = "terraform"
  }
}

resource "aws_instance" "arph_manager" {
  count = local.is_arph ? 1 : 0

  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type               = var.data_instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.bench.id]
  iam_instance_profile        = local.iam_instance_profile_name
  user_data                   = file("${path.module}/user_data/minimal_aws.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_gib
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  key_name = var.key_name != "" ? var.key_name : null

  tags = {
    Name                       = "arcane-bench-arph-manager-${local.setup_run_id}"
    ArcaneBenchmarkEnvironment = var.topology
    ArcaneBenchmarkRole        = "manager"
    Project                    = "arcane-benchmark"
    ManagedBy                  = "terraform"
  }
}

resource "aws_instance" "arph_cluster" {
  count = local.is_arph ? var.arcane_cluster_count : 0

  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type               = var.data_instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.bench.id]
  iam_instance_profile        = local.iam_instance_profile_name
  user_data                   = file("${path.module}/user_data/minimal_aws.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_gib
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  key_name = var.key_name != "" ? var.key_name : null

  tags = {
    Name                       = "arcane-bench-arph-cl${count.index}-${local.setup_run_id}"
    ArcaneBenchmarkEnvironment = var.topology
    ArcaneBenchmarkRole        = "cluster"
    Project                    = "arcane-benchmark"
    ManagedBy                  = "terraform"
  }
}

resource "aws_instance" "arph_driver" {
  count = local.is_arph ? 1 : 0

  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.bench.id]
  iam_instance_profile        = local.iam_instance_profile_name
  user_data                   = file("${path.module}/user_data/benchmark_driver.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_gib
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  key_name = var.key_name != "" ? var.key_name : null

  tags = {
    Name                       = "arcane-bench-arph-driver-${local.setup_run_id}"
    ArcaneBenchmarkEnvironment = var.topology
    ArcaneBenchmarkRole        = "driver"
    Project                    = "arcane-benchmark"
    ManagedBy                  = "terraform"
  }
}
