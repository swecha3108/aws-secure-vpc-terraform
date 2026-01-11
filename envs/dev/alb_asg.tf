############################
# PHASE 2: ALB + ASG
############################

# 1) Security Group for ALB (public)
resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP inbound to ALB"
  vpc_id      = module.vpc.vpc_id

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

  tags = merge(var.tags, { Name = "${var.project_name}-alb-sg" })
}

# 2) Security Group for EC2 instances in private subnets
resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "Allow HTTP from ALB only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTP from ALB SG"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "All outbound (via NAT)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-app-sg" })
}

# 3) Find latest Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# 4) User data: install nginx + simple page
locals {
  user_data = <<-EOT
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y nginx
    systemctl enable nginx
    echo "<h1>${var.project_name} - Phase 2 (ALB + ASG)</h1><p>Deployed via Terraform</p>" > /usr/share/nginx/html/index.html
    systemctl start nginx
  EOT
}

# 5) Launch Template for EC2 instances
resource "aws_launch_template" "app_lt" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.micro"

  user_data = base64encode(local.user_data)

  vpc_security_group_ids = [aws_security_group.app_sg.id]

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.project_name}-app"
    })
  }

  tags = merge(var.tags, { Name = "${var.project_name}-lt" })
}

# 6) Target Group for ALB -> instances
resource "aws_lb_target_group" "app_tg" {
  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, { Name = "${var.project_name}-tg" })
}

# 7) Application Load Balancer in PUBLIC subnets
resource "aws_lb" "app_alb" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb_sg.id]
  subnets         = module.vpc.public_subnet_ids

  tags = merge(var.tags, { Name = "${var.project_name}-alb" })
}

# 8) Listener on port 80 forwarding to target group
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# 9) Auto Scaling Group in PRIVATE subnets
resource "aws_autoscaling_group" "app_asg" {
  name                = "${var.project_name}-asg"
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
  vpc_zone_identifier = module.vpc.private_subnet_ids

  target_group_arns = [aws_lb_target_group.app_tg.arn]
  health_check_type = "ELB"

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-asg-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 10) Output: ALB DNS
output "alb_dns_name" {
  value = aws_lb.app_alb.dns_name
}
