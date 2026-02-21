ansible all -m ping -i inventory/hosts.ini
ansible-playbook -i inventory/hosts.ini playbooks/lamp.yml -l webservers