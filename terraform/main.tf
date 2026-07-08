terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {}
}

variable "project_name" {}
variable "aws_region" {}
variable "public_key" {}
variable "db_password" {}

variable "instance_type" {
  default = "t3.micro"
}

variable "db_name" {
  default = "rb1d1"
}

variable "db_username" {
  default = "appuser"
}

locals {
  app_prefix = "udap-app"
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
    }
  }
}

#  Data 
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-*-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

#  VPC 
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${local.app_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.app_prefix}-igw" }
}

#  Public subnets (ALB) 
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags = { Name = "${local.app_prefix}-public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags = { Name = "${local.app_prefix}-public-b" }
}

#  Private subnets (EC2, RDS) 
resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.11.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags = { Name = "${local.app_prefix}-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.12.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false
  tags = { Name = "${local.app_prefix}-private-b" }
}

#  NAT Gateways 
resource "aws_eip" "nat_a" {
  domain = "vpc"
  tags   = { Name = "${local.app_prefix}-nat-eip-a" }
}

resource "aws_eip" "nat_b" {
  domain = "vpc"
  tags   = { Name = "${local.app_prefix}-nat-eip-b" }
}

resource "aws_nat_gateway" "nat_a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "${local.app_prefix}-nat-a" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat_b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_b.id
  tags          = { Name = "${local.app_prefix}-nat-b" }
  depends_on    = [aws_internet_gateway.main]
}

#  Route tables 
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.app_prefix}-public-rt" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_a.id
  }
  tags = { Name = "${local.app_prefix}-private-rt-a" }
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_b.id
  }
  tags = { Name = "${local.app_prefix}-private-rt-b" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}

#  Security groups 
# ALB security group - all ingress/egress inline to avoid separate-rule conflicts
resource "aws_security_group" "alb" {
  name        = "${local.app_prefix}-alb-sg"
  description = "Allow HTTP from internet to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.app_prefix}-alb-sg" }
}

# App instance security group - all ingress/egress inline
resource "aws_security_group" "app" {
  name        = "${local.app_prefix}-app-sg"
  description = "Allow traffic from ALB to app instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App port from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "HTTPS for SSM"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.app_prefix}-app-sg" }
}

# RDS security group - standalone rule to break the cycle between app SG and RDS SG
resource "aws_security_group" "rds" {
  name        = "${local.app_prefix}-rds-sg"
  description = "Allow MySQL from app instances"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.app_prefix}-rds-sg" }
}

# Standalone ingress rule on RDS SG referencing app SG - avoids dependency cycle
resource "aws_security_group_rule" "rds_from_app" {
  type                     = "ingress"
  description              = "MySQL from app instances"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.app.id
}

#  Key pair 
resource "aws_key_pair" "app" {
  key_name   = "${local.app_prefix}-keypair"
  public_key = var.public_key
  tags       = { Name = "${local.app_prefix}-keypair" }
}

#  IAM role for SSM 
resource "aws_iam_role" "app" {
  name = "${local.app_prefix}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.app_prefix}-role" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.app_prefix}-instance-profile"
  role = aws_iam_role.app.name
}

#  VPC endpoints for SSM (private instances need them) 
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids  = [aws_security_group.app.id]
  private_dns_enabled = true
  tags                = { Name = "${local.app_prefix}-ssm-endpoint" }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids  = [aws_security_group.app.id]
  private_dns_enabled = true
  tags                = { Name = "${local.app_prefix}-ssmmessages-endpoint" }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids  = [aws_security_group.app.id]
  private_dns_enabled = true
  tags                = { Name = "${local.app_prefix}-ec2messages-endpoint" }
}

#  RDS subnet group 
resource "aws_db_subnet_group" "main" {
  name       = "${local.app_prefix}-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  tags       = { Name = "${local.app_prefix}-db-subnet-group" }
}

#  RDS MySQL Multi-AZ 
resource "aws_db_instance" "main" {
  identifier             = "${local.app_prefix}-mysql"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_encrypted      = true
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = { Name = "${local.app_prefix}-mysql" }
}

#  ALB 
resource "aws_lb" "main" {
  name               = "${local.app_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = { Name = "${local.app_prefix}-alb" }
}

resource "aws_lb_target_group" "app" {
  name        = "${local.app_prefix}-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = { Name = "${local.app_prefix}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

#  Launch template 
resource "aws_launch_template" "app" {
  name_prefix   = "${local.app_prefix}-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.app.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y python3.11 python3.11-venv python3-pip
    snap install amazon-ssm-agent --classic
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = "${local.app_prefix}-instance"
      Project   = var.project_name
      ManagedBy = "udap"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
    }
  }

  tags = { Name = "${local.app_prefix}-lt" }
}

#  Auto Scaling Group 
resource "aws_autoscaling_group" "app" {
  name                      = "${local.app_prefix}-asg"
  desired_capacity          = 2
  min_size                  = 2
  max_size                  = 4
  vpc_zone_identifier       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 600

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.app_prefix}-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "udap"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

#  Outputs 
output "alb_dns_name" {
  value       = aws_lb.main.dns_name
  description = "Public DNS name of the Application Load Balancer"
}

output "app_url" {
  value       = "http://${aws_lb.main.dns_name}"
  description = "Application URL"
}

output "rds_endpoint" {
  value       = aws_db_instance.main.endpoint
  description = "RDS MySQL endpoint"
}

output "asg_name" {
  value       = aws_autoscaling_group.app.name
  description = "Auto Scaling Group name (non-secret identifier)"
}