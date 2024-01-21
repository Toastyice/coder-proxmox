terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.13.0"
    }
    proxmox = {
      source = "bpg/proxmox"
      version = "0.44.0"
    }
  }
}

# https://registry.terraform.io/providers/bpg/proxmox/latest/docs
provider "proxmox" {
  endpoint = "https://192.168.178.11:8006/"
  username = "user@pam"
  password = "<password>"
  insecure = true

  ssh {
    username = "user"
    password = "<password>"
    node {
      name = "pve01"
      address = "192.168.178.10"
    }
    node {
      name = "pve02"
      address = "192.168.178.11"
    }
    node {
      name = "pve03"
      address = "192.168.178.12"
    }
  }
}

# code-server
resource "coder_app" "code-server" {
  agent_id      = coder_agent.dev.id
  display_name  = "code-server"
  slug          = "code-server"
  icon          = "/icon/code.svg"
  url           = "http://localhost:13337"
  subdomain     = false
}

data "coder_workspace" "me" {
}

resource "coder_agent" "dev" {
  arch           = "amd64"
  auth           = "token"
  dir            = "/home/${lower(data.coder_workspace.me.owner)}"
  os             = "linux"
  startup_script = <<EOT
#!/bin/sh
curl -fsSL https://code-server.dev/install.sh | sh
code-server --auth none --port 13337 > /dev/null 2>&1 &
exit 0
  EOT

  metadata {
    display_name = "CPU Usage"
    key = "cpu"
    script = <<EOT
    echo "$[100-$(vmstat 1 2|tail -1|awk '{print $15}')]"%
    EOT
    interval = 15
    timeout = 5
  }

  metadata {
    display_name = "Memory Usage"
    key = "RAM"
    script = <<EOT
    free | awk '/^Mem/ { printf("%.0f%%", $2/$4 ) }'
    EOT
    interval = 1
    timeout = 1
  }

  metadata {
    display_name = "Load Average"
    key = "load"
    script = <<EOT
    awk '{print $1}' /proc/loadavg
    EOT
    interval = 15
    timeout = 1
  }

  metadata {
    display_name = "Disk Usage /"
    key = "disk-root"
    script = <<EOT
    df -h | grep '/dev/vda2' | awk '{ print $5 }'
    EOT
    interval = 15
    timeout = 1
  }

  metadata {
    display_name = "Disk Usage home"
    key = "disk-home"
    script = <<EOT
    df -h | grep '/dev/vdb' | awk '{ print $5 }'
    EOT
    interval = 15
    timeout = 1
  }

  metadata {
    display_name = "Process Count"
    key = "process_count"
    script = <<EOT
    ps aux | wc -l
    EOT
    interval = 10
    timeout = 1
  }

  metadata {
    display_name = "Container Count"
    key = "container_count"
    script = <<EOT
    [ -x "$(command -v docker)" ] && sudo docker ps | tail -n +2 | wc -l && exit 0
    [ -x "$(command -v podman)" ] && sudo podman ps | tail -n +2 | wc -l && exit 0
    echo 0
    EOT
    interval = 15
    timeout = 1
  }
}

data "coder_parameter" "vm_cloudinit_ipconfig0" {
  name        = "IP config"
  description = <<EOF
  ipconfig0 for VM  
  e.g `ip=dhcp` or `ip=10.0.2.99/16,gw=10.0.2.2`
  EOF

  type        = "string"
  mutable     = true
  default     = "ip=dhcp"
}

# Cloud-init data for VM to auto-start Coder
locals {
  vm_name   = replace("${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}", " ", "_")
  # change to your template bios type default seabios
  vm_bios = {
    alma9  = "seabios"
    rocky9 = "seabios"
    fedora38   = "ovmf"
    fedora39   = "ovmf"
    ubuntu2204 = "seabios"
    ubuntu2304 = "seabios"
  }
  # change to your templates!
  # templatenname = templateid
  vm_id = {
    alma9  = 800
    rocky9 = 801
    fedora38   = 807
    fedora39   = 808
    ubuntu2204 = 804
    ubuntu2304 = 805
  }
  # if you're not using virtio change vdb to the applicable 
  user_data = <<EOT
Content-Type: multipart/mixed; boundary="//"
MIME-Version: 1.0

--//
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="cloud-config.txt"

#cloud-config
hostname: ${lower(data.coder_workspace.me.name)}
users:
- name: ${lower(data.coder_workspace.me.owner)}
  sudo: ALL=(ALL) NOPASSWD:ALL
  shell: /bin/bash
cloud_final_modules:
- [scripts-user, always]

--//
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="userdata.txt"

#!/bin/bash
# Check if the disk is already formatted
if sudo blkid /dev/vdb | grep -q 'TYPE'; then
    echo "Disk is already formatted."
else
    echo "Disk is not formatted. Formatting now..."
    sudo mkfs.ext4 /dev/vdb
fi
# Create the mount point if it doesn't exist
if [ ! -d "/home/${lower(data.coder_workspace.me.owner)}" ]; then
    sudo mkdir /home/${lower(data.coder_workspace.me.owner)}
fi
# Mount the disk
sudo mount /dev/vdb /home/${lower(data.coder_workspace.me.owner)}
# Expand the filesystem to use all available space
sudo resize2fs /dev/vdb
# Change ownership to ${lower(data.coder_workspace.me.owner)}
sudo chown -R ${lower(data.coder_workspace.me.owner)}:${lower(data.coder_workspace.me.owner)} /home/${lower(data.coder_workspace.me.owner)}
# Add the mount to /etc/fstab for automatic mounting at boot
# not needed
if ! grep -q '/dev/vdb' /etc/fstab; then
    echo '/dev/vdb /home/${lower(data.coder_workspace.me.owner)} ext4 defaults 0 0' | sudo tee -a /etc/fstab
fi
export CODER_AGENT_TOKEN=${coder_agent.dev.token}
sudo --preserve-env=CODER_AGENT_TOKEN -u ${lower(data.coder_workspace.me.owner)} /bin/bash -c '${coder_agent.dev.init_script}'
--//--
EOT
}

data "coder_parameter" "vm_target_node" {
  name        = "Node"
  description = "Which node would you like to use?"
  icon        = "/emojis/1f30f.png"
  type        = "string"
  mutable     = true
  default     = "pve02"

  option {
    name = "pve01"
    value = "pve01"
  }

  option {
    name = "pve02"
    value = "pve02"
  }

  option {
    name = "pve03"
    value = "pve03"
  }
}

data "coder_parameter" "clone_template" {
  name        = "Template"
  description = "Which Template would you like to use?"
  icon        = "/emojis/1f30f.png"
  type        = "string"
  default     = "alma9"
  mutable     = true

  option {
    name  = "Alma Linux 9"
    value = "alma9"
    icon  = "/icon/almalinux.svg"
  }

  option {
    name  = "Rocky Linux 9"
    value = "rocky9"
    icon  = "/icon/rockylinux.svg"
  }

  option {
    name  = "Fedora 38"
    value = "fedora38"
    icon  = "/icon/fedora.svg"
  }

  option {
    name  = "Fedora 39"
    value = "fedora39"
    icon  = "/icon/fedora.svg"
  }

  option {
    name  = "Ubuntu 22.04 LTS"
    value = "ubuntu2204"
    icon  = "/icon/ubuntu.svg"
  }

  option {
    name  = "Ubuntu 23.04"
    value = "ubuntu2304"
    icon  = "/icon/ubuntu.svg"
  }
}

data "coder_parameter" "disk_size" {
  name        = "Disk size"
  type        = "number"
  description = "VM disk size in GB"
  mutable     = true
  default     = 20
  validation {
    min       = 1
    max       = 250
    monotonic = "increasing"
  }
}

data "coder_parameter" "cpu_cores" {
  name        = "CPU cores"
  type        = "number"
  description = "Number of CPU cores"
  mutable     = true
  default     = 4
  validation {
    min       = 1
    max       = 16
  }
}

data "coder_parameter" "sockets" {
  name        = "Sockets"
  type        = "number"
  description = "Amount of CPU sockets"
  mutable     = true
  default     = 1
  validation {
    min       = 1
    max       = 2
  }
}

data "coder_parameter" "memory" {
  name        = "RAM"
  type        = "number"
  description = "Amount Memory allocated to the workspace"
  mutable     = true
  default     = 4096
  validation {
    min       = 1024
    max       = 16384
  }
}

resource "proxmox_virtual_environment_file" "cloud_config" {
  content_type = "snippets"
  datastore_id = "local-zfs"
  node_name    = data.coder_parameter.vm_target_node.value

  source_raw {
    data = local.user_data
    file_name = "user_data_vm-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}.yml"
  }
}

# Provision the proxmox VM
resource "proxmox_virtual_environment_vm" "data_vm" {
  name = "${local.vm_name}-data"
  description = "Coder Workspace Data VM \nTemplate: ${data.coder_parameter.clone_template.value}  \nUrl: https://coder.example.com/@${data.coder_workspace.me.owner}/${data.coder_workspace.me.name}"
  tags = ["coder-data"]
  node_name = data.coder_parameter.vm_target_node.value
  started = false
  on_boot = false
  migrate = true

  disk {
    datastore_id = "local-zfs"
    file_format  = "raw"
    interface    = "virtio0"
    size         = parseint(data.coder_parameter.disk_size.value, 10)
  }
}

resource "proxmox_virtual_environment_vm" "data_user_vm" {
  name = local.vm_name
  description = "Coder Workspace  \nTemplate: ${data.coder_parameter.clone_template.value}  \nUrl: https://coder.example.com/@${data.coder_workspace.me.owner}/${data.coder_workspace.me.name}"
  tags = ["coder"]

  node_name = data.coder_parameter.vm_target_node.value
  migrate = true

  cpu {
    cores = parseint(data.coder_parameter.cpu_cores.value, 10)
    type = "host"
  }

  memory {
    dedicated = parseint(data.coder_parameter.memory.value, 10)
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  bios = lookup(local.vm_bios, data.coder_parameter.clone_template.value, "seabios")

  clone {
    # change to your proxmox node name where the templates are
    node_name = "pve02"
    vm_id = lookup(local.vm_id, data.coder_parameter.clone_template.value, "800")
    retries = 3
    full = true
  }


  scsi_hardware = "virtio-scsi-single"
  disk {
    datastore_id = "local-zfs"
    interface    = "virtio0"
    discard = "on"
    size = 10 #needs to be atleast template size!
  }

  # attached disks from data_vm
  dynamic "disk" {
    for_each = { for idx, val in proxmox_virtual_environment_vm.data_vm.disk : idx => val }
    iterator = data_disk
    content {
      datastore_id      = data_disk.value["datastore_id"]
      path_in_datastore = data_disk.value["path_in_datastore"]
      file_format       = data_disk.value["file_format"]
      # Workaround using data_disk.value["size"] and increasing the datadisk size after inital create causes a provider error.
      # This will not work if you want to use more than one datadisk!
      size              = parseint(data.coder_parameter.disk_size.value, 10) #data_disk.value["size"]
      # assign from virtio1 and up
      interface         = "virtio${data_disk.key + 1}"
    }
  }

  network_device { #defaults
    model = "virtio"
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = "local-zfs"
    user_data_file_id = proxmox_virtual_environment_file.cloud_config.id
  }

  depends_on = [
    proxmox_virtual_environment_file.cloud_config
  ]
}
