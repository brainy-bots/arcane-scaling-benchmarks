resource "aws_s3_bucket" "artifacts" {
  bucket = local.bucket_name

  force_destroy = var.s3_bucket_force_destroy

  tags = {
    Project   = "arcane-benchmark"
    ManagedBy = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "artifact_s3" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  statement {
    sid    = "ObjectRW"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role" "ec2" {
  name               = "ArcaneBenchmarkEc2Role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Project   = "arcane-benchmark"
    ManagedBy = "terraform"
  }
}

resource "aws_iam_role_policy" "artifact_s3" {
  name   = "ArcaneBenchmarkArtifactS3"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.artifact_s3.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "ArcaneBenchmarkEc2InstanceProfile"
  role = aws_iam_role.ec2.name

  tags = {
    Project   = "arcane-benchmark"
    ManagedBy = "terraform"
  }
}
