# ============================================================
# CloudPulse — DR without custom ACM.
# ============================================================

data "aws_region" "nc_dr_primary" {}

data "aws_region" "nc_dr_secondary_region" {
  provider = aws.secondary
}


data "aws_availability_zones" "nc_dr_primary" {
  state = "available"
}


data "aws_availability_zones" "nc_dr_secondary_az" {
  provider = aws.secondary
  state    = "available"
}

data "aws_ami" "nc_dr_amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-20*-kernel-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "nc_dr_amazon_linux_secondary" {
  provider    = aws.secondary
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-20*-kernel-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}


data "aws_ec2_managed_prefix_list" "nc_cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

data "aws_ec2_managed_prefix_list" "nc_cloudfront_origin_secondary" {
  provider = aws.secondary
  name     = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "random_password" "nc_cloudfront_origin_secret" {
  length  = 48
  special = false
}

resource "aws_iam_service_linked_role" "autoscaling" {
  aws_service_name = "autoscaling.amazonaws.com"
}

locals {
  nc_dr_kms_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Enable IAM User Permissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "Allow EC2 and Auto Scaling use of the key"
        Effect    = "Allow"
        Principal = { Service = ["ec2.amazonaws.com"] }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
      },
      {
        Sid       = "Allow AWS Auto Scaling service-linked role use of the key"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid       = "Allow attachment of persistent resources"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" }
        Action    = "kms:CreateGrant"
        Resource  = "*"
        Condition = { Bool = { "kms:GrantIsForAWSResource" = true } }
      },
      {
        Sid       = "Allow S3"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey", "kms:ReEncrypt*", "kms:CreateGrant"
        ]
        Resource  = "*"
        Condition = { StringEquals = { "kms:CallerAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid       = "Allow DynamoDB"
        Effect    = "Allow"
        Principal = { Service = "dynamodb.amazonaws.com" }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey", "kms:ReEncrypt*", "kms:CreateGrant"
        ]
        Resource  = "*"
        Condition = { StringEquals = { "kms:CallerAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid       = "Allow SNS"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = "*"
        Condition = { StringEquals = { "kms:ViaService" = "sns.${data.aws_region.nc_dr_primary.name}.amazonaws.com" } }
      },
      {
        Sid       = "Allow CloudWatch alarm actions to encrypted SNS"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        # Omit kms:CallerAccount — CloudWatch alarm→encrypted SNS often fails evaluation with that condition.
        Action   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      },
      {
        Sid       = "Allow Lambda environment encryption"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey", "kms:CreateGrant", "kms:ReEncrypt*"
        ]
        Resource  = "*"
        Condition = { StringEquals = { "kms:ViaService" = "lambda.${data.aws_region.nc_dr_primary.name}.amazonaws.com" } }
      }
    ]
  })
}

resource "aws_kms_key" "nc_dr_kms_mrk" {
  description             = "CloudPulse MRK primary (shared DR data plane; do not destroy casually)"
  multi_region            = true
  policy                  = local.nc_dr_kms_policy
  deletion_window_in_days = 30
  tags                    = { Name = "${var.dr_stack_name}-kms" }

}

resource "aws_kms_replica_key" "nc_dr_kms_replica" {
  provider                = aws.secondary
  primary_key_arn         = aws_kms_key.nc_dr_kms_mrk.arn
  description             = "CloudPulse MRK replica for ${data.aws_region.nc_dr_secondary_region.name}"
  policy                  = local.nc_dr_kms_policy
  deletion_window_in_days = 30
  tags                    = { Name = "${var.dr_stack_name}-kms-secondary" }

}


resource "aws_vpc" "nc_dr_vpc_primary" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.dr_stack_name}-vpc" }
}

resource "aws_internet_gateway" "nc_dr_primary_igw" {
  vpc_id = aws_vpc.nc_dr_vpc_primary.id
  tags   = { Name = "${var.dr_stack_name}-igw" }
}

resource "aws_subnet" "nc_dr_primary_public" {
  vpc_id                  = aws_vpc.nc_dr_vpc_primary.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, 0)
  availability_zone       = data.aws_availability_zones.nc_dr_primary.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.dr_stack_name}-public-subnet" }
}

resource "aws_subnet" "nc_dr_primary_public2" {
  vpc_id                  = aws_vpc.nc_dr_vpc_primary.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, 1)
  availability_zone       = data.aws_availability_zones.nc_dr_primary.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.dr_stack_name}-public-subnet2" }
}

resource "aws_eip" "nc_dr_primary_nat_eip" {
  domain = "vpc"
  tags   = { Name = "${var.dr_stack_name}-nat-eip" }
}

resource "aws_nat_gateway" "nc_dr_primary_nat_gw" {
  allocation_id = aws_eip.nc_dr_primary_nat_eip.id
  subnet_id     = aws_subnet.nc_dr_primary_public.id
  tags          = { Name = "${var.dr_stack_name}-nat" }
}

resource "aws_subnet" "nc_dr_primary_private" {
  vpc_id            = aws_vpc.nc_dr_vpc_primary.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 2)
  availability_zone = data.aws_availability_zones.nc_dr_primary.names[0]
  tags              = { Name = "${var.dr_stack_name}-private-subnet" }
}

resource "aws_subnet" "nc_dr_primary_private2" {
  vpc_id            = aws_vpc.nc_dr_vpc_primary.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 3)
  availability_zone = data.aws_availability_zones.nc_dr_primary.names[1]
  tags              = { Name = "${var.dr_stack_name}-private-subnet2" }
}

resource "aws_route_table" "nc_dr_primary_private_rt" {
  vpc_id = aws_vpc.nc_dr_vpc_primary.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nc_dr_primary_nat_gw.id
  }
  tags = { Name = "${var.dr_stack_name}-private-rt" }
}

resource "aws_route_table_association" "nc_dr_primary_rta_priv1" {
  subnet_id      = aws_subnet.nc_dr_primary_private.id
  route_table_id = aws_route_table.nc_dr_primary_private_rt.id
}

resource "aws_route_table_association" "nc_dr_primary_rta_priv2" {
  subnet_id      = aws_subnet.nc_dr_primary_private2.id
  route_table_id = aws_route_table.nc_dr_primary_private_rt.id
}

resource "aws_route_table" "nc_dr_primary_public_rt" {
  vpc_id = aws_vpc.nc_dr_vpc_primary.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.nc_dr_primary_igw.id
  }
  tags = { Name = "${var.dr_stack_name}-public-rt" }
}

resource "aws_route_table_association" "nc_dr_primary_rta_pub1" {
  subnet_id      = aws_subnet.nc_dr_primary_public.id
  route_table_id = aws_route_table.nc_dr_primary_public_rt.id
}

resource "aws_route_table_association" "nc_dr_primary_rta_pub2" {
  subnet_id      = aws_subnet.nc_dr_primary_public2.id
  route_table_id = aws_route_table.nc_dr_primary_public_rt.id
}


resource "aws_vpc" "nc_dr_vpc_secondary" {
  provider             = aws.secondary
  cidr_block           = var.dr_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.dr_stack_name}-vpc-dr" }
}

resource "aws_internet_gateway" "nc_dr_igw_secondary" {
  provider = aws.secondary
  vpc_id   = aws_vpc.nc_dr_vpc_secondary.id
  tags     = { Name = "${var.dr_stack_name}-igw-dr" }
}

resource "aws_subnet" "nc_dr_public" {
  provider                = aws.secondary
  vpc_id                  = aws_vpc.nc_dr_vpc_secondary.id
  cidr_block              = cidrsubnet(var.dr_vpc_cidr, 2, 0)
  availability_zone       = data.aws_availability_zones.nc_dr_secondary_az.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.dr_stack_name}-public-dr-a" }
}

resource "aws_subnet" "nc_dr_public2" {
  provider                = aws.secondary
  vpc_id                  = aws_vpc.nc_dr_vpc_secondary.id
  cidr_block              = cidrsubnet(var.dr_vpc_cidr, 2, 1)
  availability_zone       = data.aws_availability_zones.nc_dr_secondary_az.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.dr_stack_name}-public-dr-b" }
}

resource "aws_eip" "nc_dr_secondary_nat_eip" {
  provider = aws.secondary
  domain   = "vpc"
  tags     = { Name = "${var.dr_stack_name}-nat-eip-dr" }
}

resource "aws_nat_gateway" "nc_dr_nat_secondary" {
  provider      = aws.secondary
  allocation_id = aws_eip.nc_dr_secondary_nat_eip.id
  subnet_id     = aws_subnet.nc_dr_public.id
  tags          = { Name = "${var.dr_stack_name}-nat-dr" }
}

resource "aws_subnet" "nc_dr_private" {
  provider          = aws.secondary
  vpc_id            = aws_vpc.nc_dr_vpc_secondary.id
  cidr_block        = cidrsubnet(var.dr_vpc_cidr, 2, 2)
  availability_zone = data.aws_availability_zones.nc_dr_secondary_az.names[0]
  tags              = { Name = "${var.dr_stack_name}-private-dr-a" }
}

resource "aws_subnet" "nc_dr_private2" {
  provider          = aws.secondary
  vpc_id            = aws_vpc.nc_dr_vpc_secondary.id
  cidr_block        = cidrsubnet(var.dr_vpc_cidr, 2, 3)
  availability_zone = data.aws_availability_zones.nc_dr_secondary_az.names[1]
  tags              = { Name = "${var.dr_stack_name}-private-dr-b" }
}

resource "aws_route_table" "nc_dr_private" {
  provider = aws.secondary
  vpc_id   = aws_vpc.nc_dr_vpc_secondary.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nc_dr_nat_secondary.id
  }
  tags = { Name = "${var.dr_stack_name}-private-rt-dr" }
}

resource "aws_route_table_association" "nc_dr_private" {
  provider       = aws.secondary
  subnet_id      = aws_subnet.nc_dr_private.id
  route_table_id = aws_route_table.nc_dr_private.id
}

resource "aws_route_table_association" "nc_dr_private2" {
  provider       = aws.secondary
  subnet_id      = aws_subnet.nc_dr_private2.id
  route_table_id = aws_route_table.nc_dr_private.id
}

resource "aws_route_table" "nc_dr_public" {
  provider = aws.secondary
  vpc_id   = aws_vpc.nc_dr_vpc_secondary.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.nc_dr_igw_secondary.id
  }
  tags = { Name = "${var.dr_stack_name}-public-rt-dr" }
}

resource "aws_route_table_association" "nc_dr_public" {
  provider       = aws.secondary
  subnet_id      = aws_subnet.nc_dr_public.id
  route_table_id = aws_route_table.nc_dr_public.id
}

resource "aws_route_table_association" "nc_dr_public2" {
  provider       = aws.secondary
  subnet_id      = aws_subnet.nc_dr_public2.id
  route_table_id = aws_route_table.nc_dr_public.id
}


resource "aws_security_group" "nc_alb_sg" {
  name        = "${var.dr_stack_name}-alb-sg"
  description = "Internal ALB - HTTP from CloudFront (prefix list, VPC Origin)"
  vpc_id      = aws_vpc.nc_dr_vpc_primary.id

  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.nc_cloudfront_origin.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.dr_stack_name}-alb-sg" }
}

resource "aws_security_group" "nc_dr_primary_app_sg" {
  name        = "${var.dr_stack_name}-sg"
  description = "Primary app - from ALB, SSH"
  vpc_id      = aws_vpc.nc_dr_vpc_primary.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }
  ingress {
    description     = "App from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nc_alb_sg.id]
  }
  ingress {
    description = "Grafana / Apps (lab)"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Internal cluster ports"
    from_port   = 3000
    to_port     = 9999
    protocol    = "tcp"
    self        = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.dr_stack_name}-sg" }
}

resource "aws_security_group" "nc_alb_sg_dr" {
  provider    = aws.secondary
  name        = "${var.dr_stack_name}-alb-sg-dr"
  description = "Internal DR ALB - HTTP from CloudFront (prefix list, VPC Origin)"
  vpc_id      = aws_vpc.nc_dr_vpc_secondary.id

  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.nc_cloudfront_origin_secondary.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.dr_stack_name}-alb-sg-dr" }
}

resource "aws_security_group" "nc_dr_app_sg_secondary" {
  provider    = aws.secondary
  name        = "${var.dr_stack_name}-sg-dr"
  description = "DR app - from ALB, SSH"
  vpc_id      = aws_vpc.nc_dr_vpc_secondary.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }
  ingress {
    description     = "App from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nc_alb_sg_dr.id]
  }
  ingress {
    description = "Internal cluster ports"
    from_port   = 3000
    to_port     = 9999
    protocol    = "tcp"
    self        = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.dr_stack_name}-sg-dr" }
}

resource "aws_iam_role" "nc_s3_replication" {
  name = "${var.dr_stack_name}-s3-replication-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Principal = { Service = "s3.amazonaws.com" }
      Effect    = "Allow"
    }]
  })
}

resource "aws_iam_role_policy" "nc_s3_replication" {
  name = "${var.dr_stack_name}-s3-replication-policy"
  role = aws_iam_role.nc_s3_replication.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Effect   = "Allow"
        Resource = aws_s3_bucket.nc_dr_s3_primary.arn
      },
      {
        Action = [
          "s3:GetObjectVersion",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.nc_dr_s3_primary.arn}/*"
      },
      {
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.nc_dr_s3_secondary.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey", "kms:Encrypt", "kms:ReEncrypt*"
        ]
        Resource = aws_kms_key.nc_dr_kms_mrk.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey", "kms:ReEncrypt*"
        ]
        Resource = aws_kms_replica_key.nc_dr_kms_replica.arn
      }
    ]
  })
}

resource "aws_s3_bucket" "nc_dr_s3_primary" {
  bucket = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${data.aws_region.nc_dr_primary.name}"
  tags   = { Name = "${var.dr_stack_name}-assets" }
}

resource "aws_s3_bucket" "nc_dr_s3_secondary" {
  provider = aws.secondary
  bucket   = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${data.aws_region.nc_dr_secondary_region.name}"
  tags     = { Name = "${var.dr_stack_name}-assets-secondary" }
}

resource "aws_s3_bucket_versioning" "nc_dr_s3_ver_primary" {
  bucket = aws_s3_bucket.nc_dr_s3_primary.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "nc_dr_s3_ver_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.nc_dr_s3_secondary.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_replication_configuration" "nc_dr_s3_replication" {
  role   = aws_iam_role.nc_s3_replication.arn
  bucket = aws_s3_bucket.nc_dr_s3_primary.id
  rule {
    id     = "CRR"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Disabled" }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }

    destination {
      bucket        = aws_s3_bucket.nc_dr_s3_secondary.arn
      storage_class = "STANDARD"
      encryption_configuration {
        replica_kms_key_id = aws_kms_replica_key.nc_dr_kms_replica.arn
      }
    }
  }
  depends_on = [
    aws_s3_bucket_versioning.nc_dr_s3_ver_primary,
    aws_s3_bucket_versioning.nc_dr_s3_ver_secondary,
    aws_s3_bucket_server_side_encryption_configuration.nc_dr_s3_sse,
    aws_s3_bucket_server_side_encryption_configuration.nc_dr_s3_sse_secondary,
    aws_kms_replica_key.nc_dr_kms_replica,
  ]
}

resource "aws_s3_object" "nc_dr_s3_bg_primary" {
  bucket                 = aws_s3_bucket.nc_dr_s3_primary.id
  key                    = var.background_image_key
  source                 = var.background_image_path
  content_type           = "image/jpeg"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.nc_dr_kms_mrk.arn
  depends_on             = [aws_s3_bucket_replication_configuration.nc_dr_s3_replication]
}

resource "aws_s3_object" "nc_dr_s3_bg_secondary" {
  provider               = aws.secondary
  bucket                 = aws_s3_bucket.nc_dr_s3_secondary.id
  key                    = var.background_image_key
  source                 = var.background_image_path
  content_type           = "image/jpeg"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_replica_key.nc_dr_kms_replica.arn
  depends_on = [
    aws_s3_bucket_versioning.nc_dr_s3_ver_secondary,
    aws_kms_replica_key.nc_dr_kms_replica,
    aws_s3_object.nc_dr_s3_bg_primary,
  ]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "nc_dr_s3_sse" {
  bucket = aws_s3_bucket.nc_dr_s3_primary.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.nc_dr_kms_mrk.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_policy" "nc_dr_s3_policy_encrypt" {
  bucket = aws_s3_bucket.nc_dr_s3_primary.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyUnencryptedObjectUploads"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.nc_dr_s3_primary.arn}/*"
      Condition = {
        StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
      }
    }]
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "nc_dr_s3_sse_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.nc_dr_s3_secondary.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_replica_key.nc_dr_kms_replica.arn
    }
    bucket_key_enabled = true
  }
  depends_on = [aws_kms_replica_key.nc_dr_kms_replica]
}

resource "aws_s3_bucket_policy" "nc_dr_s3_policy_encrypt_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.nc_dr_s3_secondary.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyUnencryptedObjectUploads"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.nc_dr_s3_secondary.arn}/*"
      Condition = {
        StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
      }
    }]
  })
  depends_on = [aws_s3_bucket_server_side_encryption_configuration.nc_dr_s3_sse_secondary]
}

resource "aws_dynamodb_table" "nc_dr_dynamodb" {
  name             = var.dynamodb_table_name
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "id"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.nc_dr_kms_mrk.arn
  }

  tags = { Name = "${var.dr_stack_name}-counter" }
}

# Replica as its own resource + aws.secondary avoids invalid-token errors from inline replica {} on some runners/OIDC.
resource "aws_dynamodb_table_replica" "nc_dr_dynamodb_secondary" {
  provider = aws.secondary

  global_table_arn = aws_dynamodb_table.nc_dr_dynamodb.arn
  kms_key_arn      = aws_kms_replica_key.nc_dr_kms_replica.arn

  depends_on = [aws_kms_replica_key.nc_dr_kms_replica]
}

resource "aws_dynamodb_table_item" "nc_dr_ddb_visits" {
  table_name = aws_dynamodb_table.nc_dr_dynamodb.name
  hash_key   = aws_dynamodb_table.nc_dr_dynamodb.hash_key
  item       = <<ITEM
{
  "id": {"S": "visits"},
  "count": {"N": "0"}
}
ITEM
  lifecycle {
    ignore_changes = [item]
  }
}

resource "aws_iam_role" "nc_dr_iam_ec2" {
  name = "${var.dr_stack_name}-instance-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "nc_dr_iam_ec2_policy" {
  name = "${var.dr_stack_name}-access-policy"
  role = aws_iam_role.nc_dr_iam_ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.nc_dr_s3_primary.arn,
          "${aws_s3_bucket.nc_dr_s3_primary.arn}/*",
          aws_s3_bucket.nc_dr_s3_secondary.arn,
          "${aws_s3_bucket.nc_dr_s3_secondary.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:PutItem"]
        Resource = [
          aws_dynamodb_table.nc_dr_dynamodb.arn,
          "arn:aws:dynamodb:${data.aws_region.nc_dr_secondary_region.name}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_name}",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext", "kms:CreateGrant", "kms:ReEncrypt*"
        ]
        Resource = [
          aws_kms_key.nc_dr_kms_mrk.arn,
          aws_kms_replica_key.nc_dr_kms_replica.arn
        ]
      },
      {
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:us-east-1::foundation-model/${var.bedrock_model_id}"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "nc_dr_iam_profile" {
  name = "${var.dr_stack_name}-instance-profile"
  role = aws_iam_role.nc_dr_iam_ec2.name
}

resource "aws_launch_template" "nc_dr_lt_primary" {
  name_prefix   = "${var.dr_stack_name}-lt-"
  image_id      = data.aws_ami.nc_dr_amazon_linux.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.nc_dr_primary_app_sg.id]
  iam_instance_profile { name = aws_iam_instance_profile.nc_dr_iam_profile.name }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted   = true
      kms_key_id  = aws_kms_key.nc_dr_kms_mrk.arn
      volume_type = "gp3"
      volume_size = 8
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    yum update -y
    yum install -y python3-pip unzip
    pip3 install 'flask<3' 'werkzeug<3' gunicorn requests boto3 pytz prometheus-flask-exporter
    mkdir -p /home/ec2-user/app
    cat << 'PY_EOF' > /home/ec2-user/app/app.py
    ${templatefile("${path.module}/app.py.tftpl", {
    bucket_name      = aws_s3_bucket.nc_dr_s3_primary.bucket,
    table_name       = var.dynamodb_table_name,
    aws_region       = data.aws_region.nc_dr_primary.name,
    image_key        = var.background_image_key,
    bedrock_model_id = var.bedrock_model_id,
    bedrock_region   = "us-east-1"
})}
    PY_EOF
    cat <<SVC_EOF > /etc/systemd/system/cloudpulse.service
    [Unit]
    Description=CloudPulse Flask App
    After=network.target cloud-final.target
    [Service]
    User=root
    WorkingDirectory=/home/ec2-user/app
    ExecStart=/usr/local/bin/gunicorn --workers 2 --threads 4 --bind 0.0.0.0:80 --timeout 30 app:app
    StandardOutput=append:/home/ec2-user/app/app.log
    StandardError=append:/home/ec2-user/app/app.log
    Restart=always
    [Install]
    WantedBy=multi-user.target
    SVC_EOF
    systemctl daemon-reload
    systemctl enable cloudpulse
    systemctl start cloudpulse
    wget -q https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
    tar xfz node_exporter-1.7.0.linux-amd64.tar.gz
    cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
    cat <<NODE_EOF > /etc/systemd/system/node_exporter.service
    [Unit]
    Description=Node Exporter
    After=network.target
    [Service]
    User=ec2-user
    ExecStart=/usr/local/bin/node_exporter
    [Install]
    WantedBy=multi-user.target
    NODE_EOF
    systemctl enable node_exporter
    systemctl start node_exporter
  EOF
)

tag_specifications {
  resource_type = "instance"
  tags          = { Name = "${var.dr_stack_name}-server" }
}
}

resource "aws_launch_template" "nc_dr_lt_secondary" {
  provider      = aws.secondary
  name_prefix   = "${var.dr_stack_name}-lt-dr-"
  image_id      = data.aws_ami.nc_dr_amazon_linux_secondary.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.nc_dr_app_sg_secondary.id]
  iam_instance_profile { name = aws_iam_instance_profile.nc_dr_iam_profile.name }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted   = true
      kms_key_id  = aws_kms_replica_key.nc_dr_kms_replica.arn
      volume_type = "gp3"
      volume_size = 8
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    yum update -y
    yum install -y python3-pip unzip
    pip3 install 'flask<3' 'werkzeug<3' gunicorn requests boto3 pytz prometheus-flask-exporter
    mkdir -p /home/ec2-user/app
    cat << 'PY_EOF' > /home/ec2-user/app/app.py
    ${templatefile("${path.module}/app.py.tftpl", {
    bucket_name      = aws_s3_bucket.nc_dr_s3_secondary.bucket,
    table_name       = var.dynamodb_table_name,
    aws_region       = data.aws_region.nc_dr_secondary_region.name,
    image_key        = var.background_image_key,
    bedrock_model_id = var.bedrock_model_id,
    bedrock_region   = "us-east-1"
})}
    PY_EOF
    cat <<SVC_EOF > /etc/systemd/system/cloudpulse.service
    [Unit]
    Description=CloudPulse Flask App
    After=network.target cloud-final.target
    [Service]
    User=root
    WorkingDirectory=/home/ec2-user/app
    ExecStart=/usr/local/bin/gunicorn --workers 2 --threads 4 --bind 0.0.0.0:80 --timeout 30 app:app
    StandardOutput=append:/home/ec2-user/app/app.log
    StandardError=append:/home/ec2-user/app/app.log
    Restart=always
    [Install]
    WantedBy=multi-user.target
    SVC_EOF
    systemctl daemon-reload
    systemctl enable cloudpulse
    systemctl start cloudpulse
    wget -q https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
    tar xfz node_exporter-1.7.0.linux-amd64.tar.gz
    cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
    cat <<NODE_EOF > /etc/systemd/system/node_exporter.service
    [Unit]
    Description=Node Exporter
    After=network.target
    [Service]
    User=ec2-user
    ExecStart=/usr/local/bin/node_exporter
    [Install]
    WantedBy=multi-user.target
    NODE_EOF
    systemctl enable node_exporter
    systemctl start node_exporter
  EOF
)

tag_specifications {
  resource_type = "instance"
  tags          = { Name = "${var.dr_stack_name}-server-dr" }
}
}

resource "aws_lb_target_group" "nc_dr_tg_primary" {
  name_prefix = "drp-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.nc_dr_vpc_primary.id
  lifecycle { create_before_destroy = true }
  health_check {
    path                = "/"
    interval            = 5
    timeout             = 4
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = { Name = "${var.dr_stack_name}-tg" }
}

resource "aws_lb_target_group" "nc_dr_tg_secondary" {
  provider    = aws.secondary
  name_prefix = "drs-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.nc_dr_vpc_secondary.id
  lifecycle { create_before_destroy = true }
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = { Name = "${var.dr_stack_name}-tg-dr" }
}

resource "aws_lb" "nc_dr_alb_primary" {
  name               = "${var.dr_stack_name}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.nc_alb_sg.id]
  subnets            = [aws_subnet.nc_dr_primary_private.id, aws_subnet.nc_dr_primary_private2.id]
  tags               = { Name = "${var.dr_stack_name}-alb" }
}

resource "aws_lb" "nc_dr_alb_secondary" {
  provider           = aws.secondary
  name               = "${var.dr_stack_name}-alb-dr"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.nc_alb_sg_dr.id]
  subnets            = [aws_subnet.nc_dr_private.id, aws_subnet.nc_dr_private2.id]
  tags               = { Name = "${var.dr_stack_name}-alb-dr" }
}

resource "aws_lb_listener" "nc_dr_listener_primary" {
  load_balancer_arn = aws_lb.nc_dr_alb_primary.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "nc_dr_listener_rule_cf" {
  listener_arn = aws_lb_listener.nc_dr_listener_primary.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nc_dr_tg_primary.arn
  }
  condition {
    http_header {
      http_header_name = "X-CloudPulse-Origin-Verify"
      values           = [random_password.nc_cloudfront_origin_secret.result]
    }
  }
}

resource "aws_lb_listener" "nc_dr_listener_secondary" {
  provider          = aws.secondary
  load_balancer_arn = aws_lb.nc_dr_alb_secondary.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "nc_dr_listener_rule_cf_sec" {
  provider     = aws.secondary
  listener_arn = aws_lb_listener.nc_dr_listener_secondary.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nc_dr_tg_secondary.arn
  }
  condition {
    http_header {
      http_header_name = "X-CloudPulse-Origin-Verify"
      values           = [random_password.nc_cloudfront_origin_secret.result]
    }
  }
}

resource "aws_autoscaling_group" "nc_dr_asg_primary" {
  name = "${var.dr_stack_name}-asg"
  launch_template {
    id      = aws_launch_template.nc_dr_lt_primary.id
    version = "$Latest"
  }
  enabled_metrics     = ["GroupInServiceInstances"]
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
  vpc_zone_identifier = [aws_subnet.nc_dr_primary_private.id, aws_subnet.nc_dr_primary_private2.id]
  target_group_arns   = [aws_lb_target_group.nc_dr_tg_primary.arn]
  tag {
    key                 = "Name"
    value               = "${var.dr_stack_name}-server"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "nc_dr_asg_secondary" {
  provider = aws.secondary
  name     = "${var.dr_stack_name}-asg-dr"
  launch_template {
    id      = aws_launch_template.nc_dr_lt_secondary.id
    version = "$Latest"
  }
  min_size            = var.dr_standby_desired_capacity > 0 ? var.dr_standby_desired_capacity : 0
  max_size            = 4
  desired_capacity    = var.dr_standby_desired_capacity
  vpc_zone_identifier = [aws_subnet.nc_dr_private.id, aws_subnet.nc_dr_private2.id]
  target_group_arns   = [aws_lb_target_group.nc_dr_tg_secondary.arn]
  tag {
    key                 = "Name"
    value               = "${var.dr_stack_name}-server-dr"
    propagate_at_launch = true
  }
}

resource "aws_sns_topic" "nc_dr_failover" {
  name              = "${var.dr_stack_name}-dr-failover"
  kms_master_key_id = aws_kms_key.nc_dr_kms_mrk.id
}

data "aws_iam_policy_document" "nc_dr_failover_sns" {
  statement {
    sid    = "TopicOwnerAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "SNS:Publish",
      "SNS:RemovePermission",
      "SNS:SetTopicAttributes",
      "SNS:DeleteTopic",
      "SNS:ListSubscriptionsByTopic",
      "SNS:GetTopicAttributes",
      "SNS:AddPermission",
      "SNS:Subscribe",
      "SNS:Receive",
    ]
    resources = [aws_sns_topic.nc_dr_failover.arn]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AllowCloudWatchAlarmPublish"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.nc_dr_failover.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "nc_dr_failover" {
  arn    = aws_sns_topic.nc_dr_failover.arn
  policy = data.aws_iam_policy_document.nc_dr_failover_sns.json
}

resource "aws_cloudwatch_metric_alarm" "nc_primary_health" {
  alarm_name          = "${var.dr_stack_name}-primary-asg-zero-in-service"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "GroupInServiceInstances"
  namespace           = "AWS/AutoScaling"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Primary ASG has zero InService instances (GroupInServiceInstances < 1 for 1 minute); SNS can invoke DR scale-up Lambda. OK when at least one instance is InService."
  alarm_actions       = [aws_sns_topic.nc_dr_failover.arn]
  treat_missing_data  = "missing"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.nc_dr_asg_primary.name
  }
}

data "archive_file" "nc_dr_scale_up" {
  type        = "zip"
  output_path = "${path.module}/dr_lambda_bundle.zip"
  source {
    content  = file("${path.module}/dr_lambda/index.py")
    filename = "index.py"
  }
}

resource "aws_iam_role" "nc_lambda_dr" {
  name = "${var.dr_stack_name}-lambda-dr"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "nc_lambda_dr" {
  name = "${var.dr_stack_name}-lambda-dr-policy"
  role = aws_iam_role.nc_lambda_dr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["autoscaling:UpdateAutoScalingGroup"]
        Resource = aws_autoscaling_group.nc_dr_asg_secondary.arn
      },
      {
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeAutoScalingGroups"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.nc_dr_primary.name}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext"
        ]
        Resource = aws_kms_key.nc_dr_kms_mrk.arn
      }
    ]
  })
}

resource "aws_lambda_function" "nc_dr_scale_up" {
  function_name    = "${var.dr_stack_name}-dr-scale-up"
  runtime          = "python3.11"
  handler          = "index.lambda_handler"
  role             = aws_iam_role.nc_lambda_dr.arn
  kms_key_arn      = aws_kms_key.nc_dr_kms_mrk.arn
  filename         = data.archive_file.nc_dr_scale_up.output_path
  source_code_hash = data.archive_file.nc_dr_scale_up.output_base64sha256
  environment {
    variables = {
      ASG_REGION       = data.aws_region.nc_dr_secondary_region.name
      ASG_NAME         = aws_autoscaling_group.nc_dr_asg_secondary.name
      DESIRED_CAPACITY = tostring(var.dr_lambda_scale_desired_capacity)
      MIN_SIZE         = tostring(var.dr_lambda_scale_min_size)
    }
  }
  tags = { Name = "${var.dr_stack_name}-dr-scale-up" }
}

resource "aws_sns_topic_subscription" "nc_dr_lambda" {
  count      = var.dr_route53_automatic_failover ? 1 : 0
  topic_arn  = aws_sns_topic.nc_dr_failover.arn
  protocol   = "lambda"
  endpoint   = aws_lambda_function.nc_dr_scale_up.arn
  depends_on = [aws_lambda_permission.nc_dr_sns[0]]
}

resource "aws_lambda_permission" "nc_dr_sns" {
  count         = var.dr_route53_automatic_failover ? 1 : 0
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nc_dr_scale_up.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.nc_dr_failover.arn
}

resource "aws_wafv2_web_acl" "nc_dr_waf" {
  provider    = aws.us-east-1
  name        = "${var.dr_stack_name}-waf-dr"
  description = "WAF for CloudPulse DR lab"
  scope       = "CLOUDFRONT"
  default_action {
    allow {}
  }
  rule {
    name     = "SQLInjection"
    priority = 1
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    override_action {
      none {}
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiDR"
      sampled_requests_enabled   = true
    }
  }
  rule {
    name     = "RateLimit"
    priority = 2
    statement {
      rate_based_statement {
        limit = 1000
      }
    }
    action {
      block {}
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateDR"
      sampled_requests_enabled   = true
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "CloudPulseDRWAF"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudfront_vpc_origin" "nc_dr_cf_vpc_pri" {
  vpc_origin_endpoint_config {
    name                   = "${var.dr_stack_name}-alb-vpc-origin"
    arn                    = aws_lb.nc_dr_alb_primary.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

resource "aws_cloudfront_vpc_origin" "nc_dr_cf_vpc_sec" {
  vpc_origin_endpoint_config {
    name                   = "${var.dr_stack_name}-alb-dr-vpc-origin"
    arn                    = aws_lb.nc_dr_alb_secondary.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

resource "aws_cloudfront_distribution" "nc_dr_cf_dist" {
  origin {
    domain_name = aws_lb.nc_dr_alb_primary.dns_name
    origin_id   = "primary-alb"
    custom_header {
      name  = "X-CloudPulse-Origin-Verify"
      value = random_password.nc_cloudfront_origin_secret.result
    }
    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.nc_dr_cf_vpc_pri.id
    }
  }
  origin {
    domain_name = aws_lb.nc_dr_alb_secondary.dns_name
    origin_id   = "dr-alb"
    custom_header {
      name  = "X-CloudPulse-Origin-Verify"
      value = random_password.nc_cloudfront_origin_secret.result
    }
    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.nc_dr_cf_vpc_sec.id
    }
  }

  origin_group {
    origin_id = "app-failover"
    failover_criteria {
      status_codes = [403, 404, 500, 502, 503, 504]
    }
    member { origin_id = "primary-alb" }
    member { origin_id = "dr-alb" }
  }

  depends_on = [
    aws_cloudfront_vpc_origin.nc_dr_cf_vpc_pri,
    aws_cloudfront_vpc_origin.nc_dr_cf_vpc_sec
  ]

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = ""
  aliases             = []

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "app-failover"
    forwarded_values {
      query_string = true
      cookies { forward = "all" }
    }
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  ordered_cache_behavior {
    path_pattern     = "/background-image*"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "app-failover"
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  web_acl_id = aws_wafv2_web_acl.nc_dr_waf.arn
  tags       = { Name = "${var.dr_stack_name}-cf-dr" }
}

output "nc_dr_cloudfront_domain_name" {
  description = "HTTPS URL host (append https://). Uses origin failover: primary ALB then DR ALB."
  value       = aws_cloudfront_distribution.nc_dr_cf_dist.domain_name
}

output "nc_dr_primary_alb_dns" {
  description = "Primary internal ALB DNS (reachable only via CloudFront VPC Origin / private network)."
  value       = aws_lb.nc_dr_alb_primary.dns_name
}

output "nc_dr_secondary_alb_dns" {
  description = "DR internal ALB DNS in aws.secondary (not internet-routable)."
  value       = aws_lb.nc_dr_alb_secondary.dns_name
}

output "nc_dr_primary_failover_alarm_name" {
  description = "CloudWatch alarm on primary ASG GroupInServiceInstances (ALARM when 0, OK when >= 1); publishes to SNS in var.aws_region."
  value       = aws_cloudwatch_metric_alarm.nc_primary_health.alarm_name
}

output "nc_dr_sns_topic_arn" {
  description = "SNS topic in var.aws_region; publishing invokes the DR Lambda when subscription is enabled."
  value       = aws_sns_topic.nc_dr_failover.arn
}

output "nc_dr_manual_failover_aws_cli" {
  description = "Manual capacity failover: publish to SNS (same path as automatic alarm)."
  value       = "aws sns publish --region ${data.aws_region.nc_dr_primary.name} --topic-arn ${aws_sns_topic.nc_dr_failover.arn} --message '{\"default\":\"manual-dr-failover\"}'"
}

output "nc_dr_manual_lambda_invoke_cli" {
  description = "Manual failover: invoke the DR Lambda directly (scales the DR Auto Scaling group)."
  value       = "aws lambda invoke --region ${data.aws_region.nc_dr_primary.name} --function-name ${aws_lambda_function.nc_dr_scale_up.function_name} --payload '{}' dr_response.json"
}

output "nc_dr_automatic_failover_note" {
  description = "How automatic failover is wired (for lab write-ups)."
  value       = "Primary ASG AWS/AutoScaling GroupInServiceInstances alarm in ${data.aws_region.nc_dr_primary.name} (ALARM when 0 InService) → SNS (same region) → Lambda in ${data.aws_region.nc_dr_primary.name} calls Auto Scaling in ${data.aws_region.nc_dr_secondary_region.name} to scale DR ASG. CloudFront uses HA-style VPC origins + origin header, and origin group fails over on configured HTTP errors when DR has healthy targets. Toggle subscription with var.dr_route53_automatic_failover."
}
