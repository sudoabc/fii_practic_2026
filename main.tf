# ============================================================
# CloudPulse Infrastructure — Observability
# ============================================================

data "aws_region" "main" {
  provider = aws.main
}

data "aws_availability_zones" "main" {
  provider = aws.main
  state    = "available"
}

data "aws_ami" "amazon_linux" {
  provider    = aws.main
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


# ============================================================
# PHASE 1: Network — VPC + Subnet + Route table
# ============================================================


resource "aws_vpc" "cloudpulse" {
  provider             = aws.main
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.main_stack_name}-vpc" }
}

resource "aws_internet_gateway" "cloudpulse" {
  provider = aws.main
  vpc_id   = aws_vpc.cloudpulse.id
  tags     = { Name = "${var.main_stack_name}-igw" }
}

resource "aws_subnet" "public" {
  provider                = aws.main
  vpc_id                  = aws_vpc.cloudpulse.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.main.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.main_stack_name}-public-subnet" }
}

resource "aws_route_table" "public" {
  provider = aws.main
  vpc_id   = aws_vpc.cloudpulse.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cloudpulse.id
  }
  tags = { Name = "${var.main_stack_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  provider       = aws.main
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}


# ============================================================
# PHASE 2: Security Group (module) + S3
# ============================================================

resource "aws_security_group" "cloudpulse_sg" {
  provider    = aws.main
  name        = "${var.main_stack_name}-sg"
  description = "Allow SSH, HTTP, and App ports"
  vpc_id      = aws_vpc.cloudpulse.id
  # Standard SSH & HTTP
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 8089
    to_port     = 8089
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  ingress {
    description = "Grafana / Apps"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow all internal traffic between cluster nodes"
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

  tags = { Name = "${var.main_stack_name}-sg" }
}

# ============================================================
# PHASE 2b: Bedrock Runtime VPC Interface Endpoint (Session 5)
#
# Private connectivity from the EC2 instance to Bedrock. With
# private_dns_enabled = true, bedrock-runtime.<region>.amazonaws.com
# resolves to a private IP inside the VPC, so traffic never traverses
# the public internet — even though this instance has a public IP.
# ============================================================

resource "aws_security_group" "bedrock_endpoint_sg" {
  provider    = aws.main
  name        = "${var.main_stack_name}-bedrock-endpoint-sg"
  description = "Allow HTTPS from CloudPulse instances to the Bedrock VPC endpoint"
  vpc_id      = aws_vpc.cloudpulse.id

  ingress {
    description     = "HTTPS from CloudPulse instance SG"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.cloudpulse_sg.id]
  }

  tags = { Name = "${var.main_stack_name}-bedrock-endpoint-sg" }
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  provider            = aws.main
  vpc_id              = aws_vpc.cloudpulse.id
  service_name        = "com.amazonaws.${var.main_aws_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.public.id]
  security_group_ids  = [aws_security_group.bedrock_endpoint_sg.id]
  private_dns_enabled = true

  tags = { Name = "${var.main_stack_name}-bedrock-runtime-endpoint" }
}

resource "aws_s3_bucket" "cloudpulse" {
  provider = aws.main
  bucket   = "${var.main_s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${data.aws_region.main.name}"
  tags     = { Name = "${var.main_stack_name}-assets" }
}

resource "aws_s3_object" "background" {
  provider     = aws.main
  bucket       = aws_s3_bucket.cloudpulse.id
  key          = var.background_image_key
  source       = var.background_image_path
  content_type = "image/jpeg"
}



# ============================================================
# PHASE 3: DynamoDB
# ============================================================


resource "aws_dynamodb_table" "cloudpulse" {
  provider     = aws.main
  name         = var.main_dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = { Name = "${var.main_stack_name}-counter" }
}

resource "aws_dynamodb_table_item" "visits" {
  provider   = aws.main
  table_name = aws_dynamodb_table.cloudpulse.name
  hash_key   = aws_dynamodb_table.cloudpulse.hash_key

  item = <<ITEM
{
  "id": {"S": "visits"},
  "count": {"N": "0"}
}
ITEM

  lifecycle {
    ignore_changes = [item]
  }
}



# ============================================================
# PHASE 4: IAM + EC2
# ============================================================


resource "aws_iam_role" "cloudpulse_ec2" {
  provider = aws.main
  name     = "${var.main_stack_name}-instance-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole", Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cloudpulse_access" {
  provider = aws.main
  name     = "${var.main_stack_name}-access-policy"
  role     = aws_iam_role.cloudpulse_ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.cloudpulse.arn,
        "${aws_s3_bucket.cloudpulse.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:UpdateItem",
        "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.cloudpulse.arn
      },
      {
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:${var.main_aws_region}::foundation-model/${var.bedrock_model_id}"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudpulse_ec2_ssm_core" {
  provider   = aws.main
  role       = aws_iam_role.cloudpulse_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "cloudpulse" {
  provider   = aws.main
  name       = "${var.main_stack_name}-instance-profile"
  role       = aws_iam_role.cloudpulse_ec2.name
  depends_on = [aws_iam_role_policy_attachment.cloudpulse_ec2_ssm_core]
}

resource "aws_instance" "cloudpulse" {
  provider                    = aws.main
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.cloudpulse_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.cloudpulse.name
  associate_public_ip_address = true
  private_ip                  = "10.0.0.10"
  user_data_replace_on_change = true

  depends_on = [
    aws_iam_role_policy_attachment.cloudpulse_ec2_ssm_core,
    aws_vpc_endpoint.bedrock_runtime,
  ]

  user_data = <<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

    # SSM agent (credentials available after IAM profile attach at launch)
    systemctl enable amazon-ssm-agent
    systemctl restart amazon-ssm-agent

    # 1. Install App dependencies
    yum update -y
    yum install -y python3-pip unzip
    pip3 install 'flask<3' 'werkzeug<3' gunicorn requests 'boto3>=1.35.0' pytz prometheus-flask-exporter

    mkdir -p /home/ec2-user/app

    # 2. Inject the Flask app
    cat << 'PY_EOF' > /home/ec2-user/app/app.py
    ${templatefile("${path.module}/app.py.tftpl", {
  bucket_name      = aws_s3_bucket.cloudpulse.bucket,
  table_name       = var.main_dynamodb_table_name,
  aws_region       = var.main_aws_region,
  image_key        = var.background_image_key,
  bedrock_model_id = var.bedrock_model_id,
  bedrock_region   = "us-east-1"
})}
    PY_EOF

    # 3. Setup Flask Service (Redirecting logs to a file for Promtail)
    cat <<SVC_EOF > /etc/systemd/system/cloudpulse.service
    [Unit]
    Description=CloudPulse Flask App
    After=network.target cloud-final.target

    [Service]
    User=root
    WorkingDirectory=/home/ec2-user/app
    # Standard output/error redirected to app.log for Loki
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

    # 4. Install Node Exporter (Metrics for Port 9100)
    wget https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
    tar xvfz node_exporter-1.7.0.linux-amd64.tar.gz
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

    # 5. Install Promtail (Log shipping to Port 3100)
    curl -L https://github.com/grafana/loki/releases/download/v2.9.1/promtail-linux-amd64.zip -o promtail.zip
    unzip promtail.zip
    mv promtail-linux-amd64 /usr/local/bin/promtail

    cat <<PROM_EOF > /etc/promtail-config.yml
    server:
      http_listen_port: 9080
      grpc_listen_port: 0

    positions:
      filename: /tmp/positions.yaml

    clients:
      - url: http://10.0.0.20:3100/loki/api/v1/push

    scrape_configs:
    - job_name: flask-logs
      static_configs:
      - targets:
          - localhost
        labels:
          job: cloudpulse
          instance: ${var.main_stack_name}-server
          __path__: /home/ec2-user/app/app.log
    PROM_EOF

    docker run -d --restart unless-stopped --name=node-exporter -p 9100:9100 prom/node-exporter

    cat <<P_SVC_EOF > /etc/systemd/system/promtail.service
    [Unit]
    Description=Promtail service
    After=network.target

    [Service]
    Type=simple
    User=root
    ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail-config.yml

    [Install]
    WantedBy=multi-user.target
    P_SVC_EOF

    systemctl enable promtail
    systemctl start promtail
  EOF

tags = {
  Name = "${var.main_stack_name}-server"
}
}

# ============================================================
# PHASE 5: Observability (Security Group + Module)
# ============================================================


resource "aws_instance" "observability" {
  provider               = aws.main
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "c7i-flex.large"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.cloudpulse_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.cloudpulse.name
  private_ip             = "10.0.0.20"

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data_replace_on_change = true

  user_data = <<-EOF
#!/bin/bash
# Redirect all output to log file
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "--- Starting User Data Installation ---"

systemctl enable amazon-ssm-agent
systemctl restart amazon-ssm-agent

# 1. Install Docker & Compose Plugin
yum update -y
yum install -y docker
systemctl enable --now docker

# Install Docker Compose V2 Plugin manually
mkdir -p /usr/local/lib/docker/cli-plugins/
curl -SL https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# 2. Create Directory Structure
mkdir -p /home/ec2-user/monitoring/prometheus
mkdir -p /home/ec2-user/monitoring/loki
mkdir -p /home/ec2-user/monitoring/grafana/provisioning/datasources
mkdir -p /home/ec2-user/monitoring/grafana/provisioning/dashboards
mkdir -p /home/ec2-user/monitoring/locust

# 3. Write Config Files (Ensuring NO indentation for the markers)

cat <<'COMPOSE_EOF' > /home/ec2-user/monitoring/docker-compose.yml
${file("${path.module}/monitoring/docker-compose.yml")}
COMPOSE_EOF

cat <<PROM_EOF > /home/ec2-user/monitoring/prometheus/prometheus.yml
${templatefile("${path.module}/monitoring/prometheus/prometheus.yml", {
  app_private_ip = "10.0.0.10"
})}
PROM_EOF

cat <<'LOKI_EOF' > /home/ec2-user/monitoring/loki/loki-config.yaml
${file("${path.module}/monitoring/loki/loki-config.yaml")}
LOKI_EOF

cat <<'DS_EOF' > /home/ec2-user/monitoring/grafana/provisioning/datasources/ds.yml
${file("${path.module}/monitoring/grafana/provisioning/datasources/ds.yml")}
DS_EOF

cat <<'LOCUST_EOF' > /home/ec2-user/monitoring/locust/locustfile.py
${file("${path.module}/monitoring/locust/locustfile.py")}
LOCUST_EOF

cat <<'DASH_PROV_EOF' > /home/ec2-user/monitoring/grafana/provisioning/dashboards/provider.yml
apiVersion: 1
providers:
  - name: 'Standard Dashboards'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /etc/grafana/provisioning/dashboards
DASH_PROV_EOF

cat <<'APP_EOF' > /home/ec2-user/monitoring/grafana/provisioning/dashboards/app.json
${file("${path.module}/monitoring/grafana/provisioning/dashboards/app.json")}
APP_EOF

# 4. Fix permissions and Start
echo "--- Fixing permissions and starting Docker Compose ---"
chown -R ec2-user:ec2-user /home/ec2-user/monitoring
cd /home/ec2-user/monitoring
docker compose up -d

echo "--- User Data Script Complete ---"
EOF

tags = { Name = "${var.main_stack_name}-monitoring" }
}

# ============================================================
# Outputs
# ============================================================

output "app_url" {
  description = "Open this in your browser!"
  value       = "http://${aws_instance.cloudpulse.public_ip}"
}

output "monitoring_url" {
  description = "Open this in your browser!"
  value       = "http://${aws_instance.observability.public_ip}:3000"
}

output "locust_url" {
  description = "Open this in your browser!"
  value       = "http://${aws_instance.observability.public_ip}:8089"
}