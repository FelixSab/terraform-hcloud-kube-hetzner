locals {
  cluster_prefix = var.use_cluster_name_in_node_name ? "${var.cluster_name}-" : ""
  first_nodepool_snapshot_id = length(var.autoscaler_nodepools) == 0 ? "" : (
    substr(var.autoscaler_nodepools[0].server_type, 0, 3) == "cax" ? data.hcloud_image.microos_arm_snapshot.id : data.hcloud_image.microos_x86_snapshot.id
  )
  autoscaler_yaml = length(var.autoscaler_nodepools) == 0 ? "" : templatefile(
    "${path.module}/templates/autoscaler.yaml.tpl",
    {
      cloudinit_config              = base64encode(data.cloudinit_config.autoscaler-config[0].rendered)
      ca_image                      = var.cluster_autoscaler_image
      ca_version                    = var.cluster_autoscaler_version
      cluster_autoscaler_extra_args = var.cluster_autoscaler_extra_args
      ssh_key                       = local.hcloud_ssh_key_id
      ipv4_subnet_id                = hcloud_network.k3s.id
      snapshot_id                   = local.first_nodepool_snapshot_id
      firewall_id                   = hcloud_firewall.k3s.id
      cluster_name                  = local.cluster_prefix
      node_pools                    = var.autoscaler_nodepools
  })
  # A concatenated list of all autoscaled nodes
  autoscaled_nodes = length(var.autoscaler_nodepools) == 0 ? {} : {
    for v in concat([
      for k, v in data.
      hcloud_servers.autoscaled_nodes : [for v in v.servers : v]
    ]...) : v.name => v
  }
}

resource "null_resource" "configure_autoscaler" {
  count = length(var.autoscaler_nodepools) > 0 ? 1 : 0

  triggers = {
    template = local.autoscaler_yaml
  }
  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[keys(module.control_planes)[0]].ipv4_address
    port           = var.ssh_port
  }

  # Upload the autoscaler resource defintion
  provisioner "file" {
    content     = local.autoscaler_yaml
    destination = "/tmp/autoscaler.yaml"
  }

  # Create/Apply the definition
  provisioner "remote-exec" {
    inline = [
      "set -ex",
      "kubectl apply -f /tmp/autoscaler.yaml",
    ]
  }

  depends_on = [
    null_resource.kustomization,
    data.hcloud_image.microos_x86_snapshot
  ]
}

data "cloudinit_config" "autoscaler-config" {
  count = length(var.autoscaler_nodepools) > 0 ? 1 : 0

  gzip          = true
  base64_encode = true

  # Main cloud-config configuration file.
  part {
    filename     = "init.cfg"
    content_type = "text/cloud-config"
    content = templatefile(
      "${path.module}/templates/autoscaler-cloudinit.yaml.tpl",
      {
        hostname          = "autoscaler"
        sshAuthorizedKeys = concat([var.ssh_public_key], var.ssh_additional_public_keys)
        k3s_config = yamlencode({
          server        = "https://${var.use_control_plane_lb ? hcloud_load_balancer_network.control_plane.*.ip[0] : module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}:6443"
          token         = random_password.k3s_token.result
          kubelet-arg   = local.kubelet_arg
          flannel-iface = local.flannel_iface
          node-label    = concat(local.default_agent_labels, var.autoscaler_labels)
          node-taint    = concat(local.default_agent_taints, var.autoscaler_taints)
          selinux       = true
        })
        install_k3s_agent_script     = join("\n", concat(local.install_k3s_agent, ["systemctl start k3s-agent"]))
        cloudinit_write_files_common = local.cloudinit_write_files_common
        cloudinit_runcmd_common      = local.cloudinit_runcmd_common
      }
    )
  }
}

data "hcloud_servers" "autoscaled_nodes" {
  for_each      = toset(var.autoscaler_nodepools[*].name)
  with_selector = "hcloud/node-group=${local.cluster_prefix}${each.value}"
}

resource "null_resource" "autoscaled_nodes_registries" {
  for_each = local.autoscaled_nodes
  triggers = {
    registries = var.k3s_registries
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = each.value.ipv4_address
    port           = var.ssh_port
  }

  provisioner "file" {
    content     = var.k3s_registries
    destination = "/tmp/registries.yaml"
  }

  provisioner "remote-exec" {
    inline = [local.k3s_registries_update_script]
  }
}
