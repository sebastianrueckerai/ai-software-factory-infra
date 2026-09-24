output "api_endpoint_ip" {
  description = "Reserved public IPv4 of node 0, the Kubernetes API endpoint"
  value       = hcloud_primary_ip.node[0].ip_address
}

output "node_public_ips" {
  description = "Public IPv4 addresses of the three nodes"
  value       = hcloud_server.node[*].ipv4_address
}

output "node_private_ips" {
  description = "Private network addresses of the three nodes"
  value       = hcloud_server_network.node[*].ip
}
