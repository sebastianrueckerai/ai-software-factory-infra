provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_network" "cluster" {
  name     = var.cluster_name
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

resource "hcloud_firewall" "cluster" {
  name = var.cluster_name
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.home_cidr]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "50000"
    source_ips = [var.home_cidr]
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

resource "hcloud_primary_ip" "node" {
  count         = var.node_count
  name          = "${var.cluster_name}-${count.index}"
  location      = var.location
  type          = "ipv4"
  assignee_type = "server"
  auto_delete   = false
}

resource "hcloud_server" "node" {
  count        = var.node_count
  name         = "${var.cluster_name}-${count.index}"
  server_type  = var.server_type
  location     = var.location
  image        = data.hcloud_image.talos.id
  user_data    = file("${path.module}/talos/controlplane-${count.index}.yaml")
  firewall_ids = [hcloud_firewall.cluster.id]

  public_net {
    ipv4 = hcloud_primary_ip.node[count.index].id
  }
}

resource "hcloud_server_network" "node" {
  count     = var.node_count
  server_id = hcloud_server.node[count.index].id
  subnet_id = hcloud_network_subnet.nodes.id
  ip        = cidrhost(hcloud_network_subnet.nodes.ip_range, 10 + count.index)
}

data "hcloud_image" "talos" {
  with_selector     = "os=talos,version=1.14.1,arch=arm64"
  with_architecture = "arm"
  most_recent       = true
}
