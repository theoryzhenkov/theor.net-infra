data "sops_file" "secrets" {
  source_file = "secrets.enc.yaml"
}

provider "hcloud" {
  token = data.sops_file.secrets.data["hcloud_token"]
}

resource "hcloud_ssh_key" "deploy" {
  name       = "hetzner-theor.net-web-ssh-1"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIELtIN+wG3GGLHruiy+Bl3NNJFcAU7uK4Q3rbVD3ad18"
}

resource "hcloud_firewall" "web" {
  name = "${var.server_name}-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_primary_ip" "web_ipv4" {
  name          = "${var.server_name}-ipv4"
  type          = "ipv4"
  location      = var.location
  auto_delete   = false
  assignee_type = "server"
}

resource "hcloud_server" "web" {
  name        = var.server_name
  server_type = var.server_type
  location    = var.location
  image       = "ubuntu-24.04"

  ssh_keys = [hcloud_ssh_key.deploy.id]

  firewall_ids = [hcloud_firewall.web.id]

  public_net {
    ipv4 = hcloud_primary_ip.web_ipv4.id
  }

  labels = {
    project = "theor-net"
    role    = "web"
  }
}
