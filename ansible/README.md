# Ansible LAMP Deployment para PixelHardware Lab

Esta estructura de Ansible despliega un stack LAMP (Linux, Apache, PHP, MySQL Client) en tus servidores web.

## Estructura de Directorios

```
ansible/
├── ansible.cfg              # Configuración de Ansible
├── inventory/
│   └── hosts.ini           # Inventario con IPs de los web servers
├── playbooks/
│   └── lamp.yml            # Playbook principal
├── roles/
│   ├── apache/             # Rol para instalar Apache
│   │   ├── tasks/main.yml
│   │   └── handlers/main.yml
│   ├── php/                # Rol para instalar PHP
│   │   └── tasks/main.yml
│   └── mysql/              # Rol para instalar MySQL Client
│       └── tasks/main.yml
└── README.md               # Este archivo
```

## Prerequisitos

1. **Ansible instalado** en tu máquina local:
   ```bash
   pip install ansible
   ```

2. **Clave SSH** configurada (`vockey.pem`):
   - Coloca tu clave en el directorio home: `~\vockey.pem` (Windows) o `~/.ssh/vockey.pem` (Linux/Mac)
   - Asegúrate de que los permisos sean correctos (solo lectura para el propietario)

3. **Infraestructura Terraform desplegada**:
   - VPC, subredes, NAT Gateway
   - EC2 web servers (www1 y www2)
   - RDS Aurora MySQL

## Arquitectura de Acceso (Bastion Host)

⚠️ **Importante:** Los web servers están en **subredes privadas** sin acceso directo a Internet.
Solo se puede acceder a ellos **a través del proxy** (bastion host).

```
Tu Máquina
    ↓
    ├─→ Proxy (IP Pública) ← SSH directo ✓
    │
    └─→ Web Servers (IPs Privadas)
        └─→ Acceso via Proxy ← SSH a través de bastion ✓
```

Ansible automatiza esto con `ansible_bastion_host`.

## Pasos para Desplegar LAMP

### 1. Genera el inventario automáticamente

Desde la carpeta `ansible/`, ejecuta el script que obtiene automáticamente las IPs de Terraform:

```powershell
# En Windows:
.\generate_inventory.ps1

# En Linux/Mac:
bash generate_inventory.sh
```

Este script:
- Obtiene la **IP pública del proxy** desde Terraform
- Obtiene las **IPs privadas de los web servers**
- Configura el **bastion host automáticamente**
- Actualiza `inventory/hosts.ini`

### 2. Verifica la conectividad

Antes de ejecutar Ansible, verifica que todo está conectado:

```bash
# Verifica conectividad a todos los hosts
ansible all -i inventory/hosts.ini -m ping

# Verifica específicamente el proxy
ansible proxy -i inventory/hosts.ini -m ping

# Verifica los web servers (via proxy)
ansible webservers -i inventory/hosts.ini -m ping
```

### 3. Ejecuta el Playbook LAMP

```bash
# Desde la carpeta ansible/
ansible-playbook playbooks/lamp.yml

# Con verbosidad para debug:
ansible-playbook -v playbooks/lamp.yml

# Solo en un host específico:
ansible-playbook playbooks/lamp.yml -l web1
```

### 4. Verifica la instalación manualmente

```powershell
# Conecta al proxy (conexión directa)
ssh -i vockey.pem ubuntu@<PROXY_PUBLIC_IP>

# Desde el proxy, salta a un web server privado
ssh ubuntu@10.0.1.50

# En el web server, verifica:
php --version
apache2 -v
mysql --version
sudo systemctl status apache2
curl http://localhost/info.php
```



## Qué hace cada rol

### Apache
- Instala Apache2
- Habilita módulos necesarios (rewrite, deflate, expires, headers)
- Crear documento root `/var/www/html`
- Crea un archivo `info.php` para testing

### PHP
- Instala PHP 8.1 y extensiones necesarias
- Configura módulo libapache2-mod-php
- Ajusta parámetros de memoria y uploads
- Configura timeouts de ejecución

### MySQL
- Instala cliente MySQL (sin servidor, ya que usas RDS)
- Instala herramientas MySQL para conexión remota
- Verifica la instalación

## Variables de Configuración

Puedes editar las variables en `ansible.cfg`:

```ini
[defaults]
remote_user = ubuntu              # Usuario SSH
private_key_file = ~/vockey.pem   # Ruta de la clave
become = True                     # Usar sudo
```

## Solución de Problemas

### Error: "Bastion/Jump host connection failed"
- Verifica que **la IP pública del proxy es correcta** en `inventory/hosts.ini`
- Comprueba que puedes conectarte manualmente: `ssh -i vockey.pem ubuntu@<PROXY_PUBLIC_IP>`
- Verifica que el security group del proxy permite SSH desde tu IP: `admin_ssh_cidr`
- Prueba con ping: `ansible proxy -i inventory/hosts.ini -m ping`

### Error: "Permission denied (publickey)"
- Verifica que la ruta de la clave SSH es correcta: `~/vockey.pem`
- Comprueba permisos: `chmod 600 ~/vockey.pem`
- Asegúrate de usar el usuario correcto (`ubuntu`)
- En Windows, asegúrate que la ruta está en formato Windows: `~\vockey.pem`

### Error: "unreachable: Failed to connect to the host via ssh"
- **Si es en webservers:** Verifica que el proxy está arriba (`ansible proxy -m ping`)
- Verifica que las IPs privadas en `hosts.ini` son correctas
- Comprueba que el NAT Gateway existe y está funcionando
- Verifica Security Groups: webservers deben permitir SSH desde el proxy

### Error: "WARNING: Accessing a non-existent handler"
- Esto es normal si los servicios no existen en la versión de Ubuntu
- Ansible ignorará handlers inexistentes automáticamente

### Los web servers no pueden acceder a Internet
- Verifica que el NAT Gateway existe
- Comprueba que la ruta privada apunta al NAT Gateway: `terraform show`
- Verifica Network ACLs (deben permitir tráfico hacia el NAT Gateway)
- Prueba manualmente: conecta al proxy → salta a web server → `curl google.com`

## Próximos pasos (opcional)

- Instalar WordPress en los web servers
- Configurar PHP-FPM para mejor rendimiento
- Establecer certificados SSL/TLS
- Configurar acceso a RDS Aurora desde PHP
- Configurar Apache como reverse proxy balanceador de carga

## Scripts útiles

### Ejecutar solo un rol específico
```bash
ansible-playbook playbooks/lamp.yml --tags "apache"
ansible-playbook playbooks/lamp.yml --tags "php"
ansible-playbook playbooks/lamp.yml --tags "mysql"
```

### Verificar conectividad completa
```bash
# Verifica proxy
ansible proxy -i inventory/hosts.ini -m ping

# Verifica web servers (via proxy)
ansible webservers -i inventory/hosts.ini -m ping

# Ejecuta un comando remoto
ansible webservers -i inventory/hosts.ini -m command -a "uname -a"
```

### Ejecutar en un solo host
```bash
ansible-playbook playbooks/lamp.yml -l web1
```

### Verificar conectividad
```bash
ansible all -i inventory/hosts.ini -m ping
```

---

**Autor:** Generado automáticamente por Terraform
**Fecha:** 2026-02-21
**Proyecto:** PixelHardware Lab
