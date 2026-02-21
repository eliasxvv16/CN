# Ansible LAMP - PixelHardware Lab

## 3 Pasos

### 1. Deploy Terraform

```powershell
cd ..\tform
terraform apply "planfile"
terraform output
```

Copia las IPs que ves.

### 2. Edita inventory/hosts.ini

Reemplaza `PROXY_PUBLIC_IP` con tu IP pública, y las IPs privadas con las que obtuviste:

```ini
[proxy]
proxy_host ansible_host=54.123.45.67

[webservers]
web1 ansible_host=10.0.1.50 ansible_bastion_host=54.123.45.67
web2 ansible_host=10.0.2.45 ansible_bastion_host=54.123.45.67
```

### 3. Ejecuta Ansible

```bash
ansible-playbook playbooks/lamp.yml
```

---

## Eso es todo

Instala:
- ✅ Apache
- ✅ PHP 8.1 + extensiones
- ✅ Cliente MySQL

Los servers privados se acceden vía el proxy (bastion host).

## Requisitos

- Ansible instalado: `pip install ansible`
- Clave SSH en `~\vockey.pem`
- Security group del proxy abierto SSH desde tu IP
