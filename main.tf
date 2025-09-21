provider "aws" {
  region = "us-east-2"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "vpc-practical-test"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-2a", "us-east-2b"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]


  enable_nat_gateway = true
  single_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform = "true"
  }
}


resource "aws_security_group" "instances" {
  name        = "ec2-private-sg"
  description = "SG for private instances"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [module.alb.security_group_id]
  }

  # Egress abierto para salir a internet via NAT
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]

  }
  tags = {
    Terraform = "true"
  }
}

module "ec2_instance" {
  source = "terraform-aws-modules/ec2-instance/aws"
  count  = 2

  name                  = "instance-${count.index}"
  instance_type         = "t3.micro"
  ami                   = data.aws_ami.ubuntu.id
  create_security_group = false

  # Reparte instancias entre subredes privadas
  subnet_id                   = module.vpc.private_subnets[count.index]
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.instances.id]

  #(Opcional) Página que muestra el instance-id/hostname
  user_data = <<EOF
#!/bin/bash
apt-get update -y
apt-get install -y nginx curl
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
HOSTNAME=$(hostname)
cat >/var/www/html/index.nginx-debian.html <<HTML
<html>
  <head><title>EC2 behind ALB</title></head>
  <body style="font-family:Arial; text-align:center; margin-top:60px">
    <h1>Hello from EC2</h1>
    <h2>Instance ID: $${INSTANCE_ID}</h2>
    <h3>Hostname: $${HOSTNAME}</h3>
    <p>Time: $(date)</p>
  </body>
</html>
HTML
systemctl enable nginx
systemctl restart nginx
EOF


  tags = {
    Terraform = "true"
  }
}

module "alb" {
  source = "terraform-aws-modules/alb/aws"

  name    = "alb"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  # Security Group del ALB
  security_group_ingress_rules = {
    http_80 = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
      description = "HTTP web traffic"
    }
    https_443 = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
      description = "HTTPS web traffic"
    }
  }

  # Egress abierto: el filtrado real se hace en el SG de las EC2 (ingress solo desde ALB)
  security_group_egress_rules = {
    all_out = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = "tg_app"
      }
    }
  }


  # Opcional: redirigir HTTP a HTTPS
  /* http_redirect = {
      port     = 80
      protocol = "HTTP"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/REEMPLAZA-POR-TU-CERT"

      forward = {
        target_group_key = "tg_app"
      }
    }
  } */

  target_groups = {
    tg_app = {
      name_prefix = "app"
      protocol    = "HTTP"
      port        = 80
      target_type = "instance"
      health_check = {
        path                = "/"
        matcher             = "200-399"
        healthy_threshold   = 2
        unhealthy_threshold = 2
        interval            = 30
        timeout             = 5
      }
      create_attachment = false
    }
  }

  tags = {
    Terraform = "true"
  }
}

resource "aws_lb_target_group_attachment" "ec2_targets" {
  count            = 2
  target_group_arn = module.alb.target_groups["tg_app"].arn
  target_id        = module.ec2_instance[count.index].id
  port             = 80
}

output "alb_dns_name" {
  description = "DNS name of the load balancer"
  value       = module.alb.dns_name
}

output "instance_ids" {
  description = "IDs of EC2 instances"
  value       = [for inst in module.ec2_instance : inst.id]
}