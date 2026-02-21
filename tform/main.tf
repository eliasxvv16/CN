terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  # Región donde se desplegarán todos los recursos de AWS
  region = "us-east-1"
}

# ------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------

# Nombre del proyecto
variable "project_name" {
  type    = string
  default = "PixelHardware"
}

# Rango CIDR de la VPC
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# IP permitida para SSH administrador
variable "admin_ssh_cidr" {
  type    = string
  default = "86.127.226.14/32"
}

# Nombre de la key pair para acceso SSH
variable "key_name" {
  type    = string
  default = "vockey"
}

# AMI que se usará para las instancias EC2
variable "ami_id" {
  type    = string
  default = "ami-0b6c6ebed2801a5cb"
}

# ------------------------------------------------------------------
# LOCALES
# ------------------------------------------------------------------

# Variable local con el nombre del proyecto en minúsculas
locals {
  project = lower(var.project_name)
}

# ------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------

# VPC principal
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.project}-vpc"
  }
}

# Internet Gateway para la VPC
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# ------------------------------------------------------------------
# SUBNETS
# ------------------------------------------------------------------

# Subnet pública (para instancias accesibles desde Internet)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}

# Subnet privada para servidores web internos
resource "aws_subnet" "private_web" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

# Subnet privada para base de datos
resource "aws_subnet" "private_db" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
}

# ------------------------------------------------------------------
# ROUTE TABLES
# ------------------------------------------------------------------

# Tabla de rutas pública
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}

# Ruta hacia Internet para subnets públicas
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# Asociación de tabla de rutas con subnet pública
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Tabla de rutas privadas
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
}

# Asociaciones de tabla de rutas privadas con subnets internas
resource "aws_route_table_association" "private_web_assoc" {
  subnet_id      = aws_subnet.private_web.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db_assoc" {
  subnet_id      = aws_subnet.private_db.id
  route_table_id = aws_route_table.private.id
}

# ------------------------------------------------------------------
# NAT GATEWAY
# ------------------------------------------------------------------

# Elastic IP para el NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

# NAT Gateway en subnet pública para que subnets privadas accedan a Internet
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.igw]
}

# Ruta por defecto de subnets privadas hacia NAT
resource "aws_route" "private_nat_route" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

# ------------------------------------------------------------------
# SECURITY GROUPS
# ------------------------------------------------------------------

# Security Group del proxy público
resource "aws_security_group" "sg_proxy" {
  name   = "${local.project}-sg-proxy"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group para servidores web privados
resource "aws_security_group" "sg_web" {
  name   = "${local.project}-sg-web"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_proxy.id]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_proxy.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group para la base de datos
resource "aws_security_group" "sg_db" {
  name   = "${local.project}-sg-db"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------------------------------------------------
# EC2 INSTANCES
# ------------------------------------------------------------------

# Instancia proxy pública
resource "aws_instance" "proxy" {
  ami                    = var.ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.sg_proxy.id]
  key_name               = var.key_name

  tags = {
    Name = "${local.project}-proxy"
  }
}

# Elastic IP para la instancia proxy
resource "aws_eip" "proxy_eip" {
  instance = aws_instance.proxy.id
  domain   = "vpc"
}

# Instancias web privadas (2 instancias)
resource "aws_instance" "web" {
  count                  = 2
  ami                    = var.ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private_web.id
  vpc_security_group_ids = [aws_security_group.sg_web.id]
  key_name               = var.key_name

  tags = {
    Name = "${local.project}-www${count.index + 1}"
  }
}

# ------------------------------------------------------------------
# RDS
# ------------------------------------------------------------------

# Grupo de subnets para RDS
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "${local.project}-db-subnet-group"
  subnet_ids = [
    aws_subnet.private_web.id,
    aws_subnet.private_db.id
  ]
}

# Instancia RDS MariaDB
resource "aws_db_instance" "rds_mysql" {
  identifier              = "wordpress-db"
  engine                  = "mariadb"
  engine_version          = "10.6"
  instance_class          = "db.t3.small"
  allocated_storage       = 20
  db_name                 = "wordpress_db"
  username                = "adminwp"
  password                = "PasswordSeguro123!"
  db_subnet_group_name    = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids  = [aws_security_group.sg_db.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
}

# ------------------------------------------------------------------
# OUTPUTS
# ------------------------------------------------------------------

# IP pública del proxy
output "proxy_public_ip" {
  value = aws_eip.proxy_eip.public_ip
}

# IP privadas de las instancias web
output "web_private_ips" {
  value = aws_instance.web[*].private_ip
}

# Endpoint de la base de datos
output "rds_endpoint" {
  value = aws_db_instance.rds_mysql.endpoint
}