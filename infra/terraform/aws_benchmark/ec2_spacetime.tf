resource "aws_instance" "stonly_spacetime" {
  count = local.is_stonly ? 1 : 0

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
    Name                       = "arcane-bench-stonly-spacetime-${local.setup_run_id}"
    ArcaneBenchmarkEnvironment = var.topology
    ArcaneBenchmarkRole        = "spacetime"
    Project                    = "arcane-benchmark"
    ManagedBy                  = "terraform"
  }
}

resource "aws_instance" "stonly_driver" {
  count = local.is_stonly ? 1 : 0

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
    Name                       = "arcane-bench-stonly-driver-${local.setup_run_id}"
    ArcaneBenchmarkEnvironment = var.topology
    ArcaneBenchmarkRole        = "driver"
    Project                    = "arcane-benchmark"
    ManagedBy                  = "terraform"
  }
}
