data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

data "aws_subnet" "selected" {
  count = var.subnet_id != "" ? 1 : 0
  id    = var.subnet_id
}
