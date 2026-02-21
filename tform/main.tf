terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------
variable "project_name" {
  description = "Nombre del proyecto para etiquetado"
  type        = string
  default     = "PixelHardware"
}

variable "vpc_cidr" {
  description = "CIDR block para la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "admin_ssh_cidr" {
  description = "Tu IP pública para acceso SSH (Seguridad). CAMBIAR POR TU IP REAL (e.g. 203.0.113.5/32)"
  type        = string
  default     = "86.127.226.14/32" 
}

variable "key_name" {
  description = "Nombre del par de claves existente en AWS (ej. vockey)"
  type        = string
  default     = "vockey"
}

# ------------------------------------------------------------------
# LOCALS
# ------------------------------------------------------------------

locals {
  # for naming resources AWS only accepts lowercase characters
  project = lower(var.project_name)
}

# ------------------------------------------------------------------
# DATA SOURCES (AMI UBUNTU)
# ------------------------------------------------------------------
variable "ami_id" {
  description = "AMI id to use for EC2 instances. Provide a valid Ubuntu Jammy AMI for your region"
  type        = string
  default     = "ami-0b6c6ebed2801a5cb" # REPLACE with a real AMI id for us-east-1
}

# ------------------------------------------------------------------
# RED (VPC, SUBNETS, IGW, ROUTES)
# ------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.project}-VPC"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project}-IGW"
  }
}

# Subred Pública (Proxy)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.project}-subnet-public"
  }
}

# Subred Privada 1 (Web Servers)
resource "aws_subnet" "private_web" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "${local.project}-subnet-private-web-a"
  }
}

# Subred Privada 1b (Web Servers segunda AZ)
/* removed: private_web_b - simplified to single private web subnet */

# Subred Privada 2 (Database)
resource "aws_subnet" "private_db" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "${local.project}-subnet-private-db-a"
  }
}

# Subred Privada 2b (Database segunda AZ)
/* removed: private_db_b - simplified to single DB subnet */

# Tabla de Rutas Pública
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${local.project}-rt-public"
  }
}

# Tabla de Rutas Privada (Salida a través del Proxy NAT)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project}-rt-private"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_web_assoc" {
  subnet_id      = aws_subnet.private_web.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db_assoc" {
  subnet_id      = aws_subnet.private_db.id
  route_table_id = aws_route_table.private.id
}
/* removed route table associations for deleted subnets */

# ------------------------------------------------------------------
# SEGURIDAD (SECURITY GROUPS)
# ------------------------------------------------------------------
# Network ACL para subred pública (Proxy)
resource "aws_network_acl" "public_nacl" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.public.id]

  # Inbound: permite HTTP, HTTPS, SSH desde Internet
  ingress {
    protocol   = "tcp"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 110
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 120
    action     = "allow"
    cidr_block = var.admin_ssh_cidr
    from_port  = 22
    to_port    = 22
  }

  # Inbound: permite retorno de subredes privadas (1024-65535)
  ingress {
    protocol   = "tcp"
    rule_no    = 130
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 1024
    to_port    = 65535
  }

  # Outbound: permite todo hacia Internet
  egress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name = "${local.project}-nacl-public"
  }
}

# Network ACL para subredes privadas (Web + DB)
resource "aws_network_acl" "private_nacl" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [
    aws_subnet.private_web.id,
    aws_subnet.private_db.id,
  ]

  # Inbound: permite tráfico desde el proxy (y entre privadas)
  ingress {
    protocol   = "tcp"
    rule_no    = 100
    action     = "allow"
    cidr_block = aws_subnet.public.cidr_block
    from_port  = 0
    to_port    = 65535
  }

  # Inbound: permite tráfico entre subredes privadas
  ingress {
    protocol   = "tcp"
    rule_no    = 110
    action     = "allow"
    cidr_block = "10.0.1.0/24"
    from_port  = 0
    to_port    = 65535
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 120
    action     = "allow"
    cidr_block = "10.0.3.0/24"
    from_port  = 0
    to_port    = 65535
  }

  # Inbound: permite respuestas de DNS y NTP
  ingress {
    protocol   = "udp"
    rule_no    = 150
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 53
    to_port    = 53
  }

  ingress {
    protocol   = "udp"
    rule_no    = 160
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 123
    to_port    = 123
  }

  # Outbound: permite todo hacia Internet y entre privadas
  egress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name = "${local.project}-nacl-private"
  }
}

# SG Proxy (Pública)
resource "aws_security_group" "sg_proxy" {
  name        = "${local.project}-sg-proxy"
  description = "Permite HTTP/HTTPS desde Internet y SSH desde Admin"
  vpc_id      = aws_vpc.main.id

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

  # Inbound desde subredes privadas hacia el proxy
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.project}-sg-proxy"
  }
}

# SG Web (Privada)
resource "aws_security_group" "sg_web" {
  name        = "${local.project}-sg-privada"
  description = "Allow traffic from proxy servers"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_proxy.id]
  }

  ingress {
    from_port       = 443
    to_port         = 443
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

  tags = {
    Name = "${local.project}-sg-web"
  }
}

# SG Base de Datos (Privada)
resource "aws_security_group" "sg_db" {
  name        = "${local.project}-basedatos"
  description = "Permite MySQL/Aurora solo desde servidores web"
  vpc_id      = aws_vpc.main.id

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

  tags = {
    Name = "${local.project}-sg-db"
  }
}

# ------------------------------------------------------------------
# INSTANCIAS EC2 (UBUNTU + APT)
# ------------------------------------------------------------------



# Instancia Proxy (NAT + Balanceador)
resource "aws_instance" "proxy" {
  ami                    = var.ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.sg_proxy.id]
  key_name               = var.key_name
  
  # Necesario para que actúe como NAT
  source_dest_check      = false 

  user_data = <<-EOF
              #!/bin/bash
              apt update
              apt upgrade -y
              apt install -y apache2
              # Habilitar módulos para balanceo de carga
              a2enmod proxy
              a2enmod proxy_http
              a2enmod proxy_balancer
              a2enmod lbmethod_byrequests
              systemctl start apache2
              systemctl enable apache2
              # Habilitar IP Forwarding para NAT
              echo 1 > /proc/sys/net/ipv4/ip_forward
              sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
              sysctl -p
              EOF

  tags = {
    Name = "${local.project}-proxy"
    Role = "Proxy/NAT"
  }
}

# Elastic IP para el Proxy
resource "aws_eip" "proxy_eip" {
  domain   = "vpc"
  instance = aws_instance.proxy.id

  tags = {
    Name = "${local.project}-proxy-eip"
  }
}

# Elastic IP para la NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"

  tags = {
    Name = "${local.project}-nat-eip"
  }

  depends_on = [aws_internet_gateway.igw]
}

# NAT Gateway en la subred pública
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${local.project}-nat-gateway"
  }

  depends_on = [aws_internet_gateway.igw, aws_eip.nat_eip]
}

# Ruta de salida a Internet para privadas apuntando a NAT Gateway
resource "aws_route" "private_nat_route" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
  
  depends_on = [aws_nat_gateway.nat]
}

# Instancias Web (www1, www2)
resource "aws_instance" "web" {
  count                  = 2
  ami                    = var.ami_id
  instance_type          = "t3.small"
  # both web instances placed in the single private web subnet
  subnet_id              = aws_subnet.private_web.id
  vpc_security_group_ids = [aws_security_group.sg_web.id]
  key_name               = var.key_name

  tags = {
    Name = "${local.project}-www${count.index + 1}"
    Role = "WebServer"
  }
}

# ------------------------------------------------------------------
# BASE DE DATOS (AURORA)
# ------------------------------------------------------------------
# Grupo de Subnetes para RDS
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "${local.project}-db-subnet-group"
  subnet_ids = [
    aws_subnet.private_db.id,
    aws_subnet.private_web.id,
  ]

  tags = {
    Name = "${local.project}-db-subnet-group"
  }
}

# Single MySQL RDS Instance (single AZ)
resource "aws_db_instance" "rds_mysql" {
  identifier           = "wordpress-db"
  engine               = "mariadb"
  engine_version       = "10.6"
  instance_class       = "db.t3.small"
  allocated_storage    = 20
  storage_type         = "gp2"
  storage_encrypted    = true

  db_name              = "wordpress_db"
  username             = "adminwp"
  password             = "PasswordSeguro123!" # CAMBIAR EN PRODUCCIÓN

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.sg_db.id]

  publicly_accessible  = false
  skip_final_snapshot  = true
  backup_retention_period = 7
  multi_az             = false

  tags = {
    Name = "${local.project}-mysql-instance"
  }
}

# ------------------------------------------------------------------
# OUTPUTS
# ------------------------------------------------------------------
output "vpc_id" {
  value = aws_vpc.main.id
}

output "proxy_public_ip" {
  value = aws_eip.proxy_eip.public_ip
}

output "web_instances_private_ips" {
  value = aws_instance.web[*].private_ip
}

output "rds_endpoint" {
  value = aws_db_instance.rds_mysql.endpoint
}

output "ssh_command_proxy" {
  value = "ssh -i tu_clave.pem ubuntu@${aws_eip.proxy_eip.public_ip}"
}
