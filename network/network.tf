# force local ignition provider binary
# provider "ignition" {
#   version = "0.0.0"
# }
data "vcd_resource_list" "list_of_vdc_edges" {
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  name          = "list_of_vdc_edges"
  resource_type = "vcd_nsxt_edgegateway" # find gateway name
  list_mode     = "name"
}
data "vcd_nsxt_edgegateway" "edge" {
  org          = var.vcd_org
//  vdc          = var.vcd_vdc
  owner_id = data.vcd_org_vdc.my-org-vdc.id

  name          = data.vcd_resource_list.list_of_vdc_edges.list[0]
}

data "vcd_org_vdc" "my-org-vdc" {
  name = var.vcd_vdc
}


locals {
    source_networks = [var.initialization_info["network_name"]]
    ansible_directory = "/tmp"
    edge_gateway_name = data.vcd_nsxt_edgegateway.edge.name
    edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id
    edge_gateway_primary_ip = data.vcd_nsxt_edgegateway.edge.primary_ip
    installerdir = "${path.cwd}/installer/${var.cluster_id}"
    
//    edge_gateway_prefix_length = tolist(data.vcd_nsxt_edgegateway.edge.subnet)[0].prefix_length
//    edge_gateway_gateway = tolist(data.vcd_nsxt_edgegateway.edge.subnet)[0].gateway
//    edge_gateway_allocated_ips_start_address = tolist(tolist(data.vcd_nsxt_edgegateway.edge.subnet)[0].allocated_ips)[0].start_address
//   edge_gateway_allocated_ips_end_address = tolist(tolist(data.vcd_nsxt_edgegateway.edge.subnet)[0].allocated_ips)[0].end_address
  

    rule_id = ""
  }

//provider "vcd" {
//  user                 = var.vcd_user
//  password             = var.vcd_password
//  org                  = var.vcd_org
//  url                  = var.vcd_url
//  max_retry_timeout    = 30
//  allow_unverified_ssl = true
//  logging              = true
//}


# Shows the list of all networks with the corresponding import command


//need to add ip_sets for VMWaaS

resource "vcd_nsxt_ip_set" "console-ipset" {

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  name        = "${var.cluster_id}_console-ipset"
  description = "${var.cluster_id} IP Set console"

  ip_addresses = [var.cluster_public_ip]

 
}
resource "vcd_nsxt_ip_set" "lb-ip1" {

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  name        = "${var.cluster_id}_lb-ip1"
  description = "${var.cluster_id} IP Set Load Balancer"

  ip_addresses = [var.network_lb_ip_address]

 
}

resource "vcd_nsxt_ip_set" "mirror-ipset" {

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  name        = "${var.cluster_id}_mirror-ipset"
  description = "${var.cluster_id} IP Set mirror"

  ip_addresses = [var.airgapped["mirror_ip"]]

 
}

resource "vcd_nsxt_ip_set" "cluster-ipset" {

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  name        = "${var.cluster_id}_cluster-ipset"
  description = "${var.cluster_id} IP Set cluster"

  ip_addresses = flatten([var.network_lb_ip_address,var.cluster_ip_addresses])

 }
 data "vcd_nsxt_ip_set" "private-ip1" {
 
   edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id
 
   name        = "private-ip1"

 }
 
 data "vcd_nsxt_ip_set" "public-ip1" {
 
   edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id
 
   name        = "public-ip1"

}

resource "vcd_nsxt_app_port_profile" "mirror-profile-inbound" {
 //count = var.airgapped["enabled"] ? 1 : 0 

 context_id = data.vcd_org_vdc.my-org-vdc.id

  name        = "${var.cluster_id}_mirror-inbound"
  description = "${var.cluster_id} Application port profile for mirror Inbound"

  scope = "TENANT"

  app_port {
    protocol = "TCP"
    port     = [var.airgapped["mirror_port"]]
  }
  

}

data "vcd_nsxt_app_port_profile" "app-profile" {
  context_id = data.vcd_org_vdc.my-org-vdc.id
  name       = "bastion-profile-inbound"
  scope      = "TENANT"
}

resource "vcd_nsxt_firewall" "lb" {
//  count = var.airgapped["enabled"] ? 1 : 0 

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  # Rule #1 - Allows in IPv4 traffic from security group `vcd_nsxt_security_group.group1.id`
  rule {
    action      = "ALLOW"
    name        = "${var.cluster_id}_lb_outbound_allow"
    direction   = "OUT"
    ip_protocol = "IPV4"
    source_ids = [vcd_nsxt_ip_set.lb-ip1.id]
  }
    # Rule #2 - Allows in IPv4 traffic from security group `vcd_nsxt_security_group.group1.id`
    rule {

      action      = "ALLOW"
      name        = "${var.cluster_id}_mirror_allow_rule"
      direction   = "IN"
      ip_protocol = "IPV4"
      destination_ids = [vcd_nsxt_ip_set.mirror-ipset.id]
      app_port_profile_ids = [vcd_nsxt_app_port_profile.mirror-profile-inbound.id]
    }
       # Rule #3 - allows in bound traffic`
      rule {
        action      = "ALLOW"
        name        = "bastion_inbound_allow"
        direction   = "IN"
        ip_protocol = "IPV4"
        destination_ids = [data.vcd_nsxt_ip_set.public-ip1.id]
        app_port_profile_ids = [data.vcd_nsxt_app_port_profile.app-profile.id]
        
      }
    
      # Rule #4 - allows putbound traffic`
      rule {
        action          = "ALLOW"
        name            = "bastion_outbound_allow"
        direction       = "OUT"
        ip_protocol     = "IPV4"
        source_ids = [data.vcd_nsxt_ip_set.private-ip1.id]
  }
  
    rule {
      action      = "ALLOW"
      name        = "${var.cluster_id}_cluster_allow_rule"
      direction   = "OUT"
      ip_protocol = "IPV4"
      source_ids = [vcd_nsxt_ip_set.cluster-ipset.id]
  }
    rule {
      action      = "ALLOW"
      name        = "${var.cluster_id}_console_allow_rule"
      direction   = "IN"
      ip_protocol = "IPV4"
      destination_ids = [vcd_nsxt_ip_set.console-ipset.id]
  
  }
          depends_on = [
            vcd_nsxt_ip_set.mirror-ipset,
            vcd_nsxt_ip_set.lb-ip1,
            vcd_nsxt_app_port_profile.mirror-profile-inbound,
            data.vcd_nsxt_app_port_profile.app-profile,
            
  ]
}



resource "vcd_nsxt_nat_rule" "ocp_console_dnat" {

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  name        = "${var.cluster_id}_ocp_console_dnat"
  rule_type   = "DNAT"
  description = "${var.cluster_id} ocp console DNAT"
 # Using primary_ip from edge gateway
  external_address = var.cluster_public_ip
  internal_address = "${var.network_lb_ip_address}/32"
  firewall_match = "MATCH_EXTERNAL_ADDRESS"
  logging          = false
//        depends_on = [
//          vcd_nsxt_app_port_profile.mirror-profile-inbound,
//  ]
}


 data "template_file" "ansible_add_entries_bastion" {
  template = <<EOF
---
- hosts: all
  # connection: local
  gather_facts: False
  tasks:
    - name: update /etc/hosts
      blockinfile:
         path: /etc/hosts
         block: |
            ${var.network_lb_ip_address}  api.${var.cluster_id}.${var.base_domain}
            ${var.network_lb_ip_address}  api-int.${var.cluster_id}.${var.base_domain}
         %{if var.airgapped["enabled"]}
            ${var.airgapped["mirror_ip"]}  ${var.airgapped["mirror_fqdn"]} 
         %{endif}
            
         state: present
         marker_begin: "${var.cluster_id}"
         marker_end: "${var.cluster_id}"
         
    - name: update dnsmasq
      blockinfile: 
         path: /etc/dnsmasq.conf
         block: |
            address=/.apps.${var.cluster_id}.${var.base_domain}/${var.network_lb_ip_address}
         state: present
         marker_begin: "${var.cluster_id}"
         marker_end: "${var.cluster_id}" 
    - name: Creates directory
      ansible.builtin.file:
        path: /opt/terraform/installer/test1/
        state: directory
        mode: '0755'         
    - name: Copy file with owner and permissions
      ansible.builtin.copy:
        src: ${local.installerdir}/bootstrap.ign
        dest: /opt/terraform/installer/${var.cluster_id}/bootstrap.ign
        mode: '0644'         
         
 %{if var.airgapped["enabled"]}
    - name: Copy Mirror Cert for trust
      ansible.builtin.shell: "cp ${var.additionalTrustBundle} /etc/pki/ca-trust/source/anchors/."
#      args:
#        warn: no  
    - name: Update trust cert store for mirror ca
      ansible.builtin.shell: "update-ca-trust"
#      args:
#        warn: no          
 %{endif}       
EOF
}

resource "local_file" "ansible_add_entries_bastion" {
  content  = data.template_file.ansible_add_entries_bastion.rendered
  filename = "${local.ansible_directory}/add_entries.yaml"
}


 data "template_file" "ansible_net_inventory" {
  template = <<EOF
${var.initialization_info["public_bastion_ip"]} ansible_connection=ssh ansible_user=root ansible_python_interpreter="/usr/libexec/platform-python" 
EOF
}
 
resource "local_file" "ansible_net_inventory" {
  content  = data.template_file.ansible_net_inventory.rendered
  filename = "${local.ansible_directory}/inventory"
} 
 data "template_file" "ansible_remove_entries_bastion" {
  template = <<EOF
---
- hosts: localhost
  connection: local
  gather_facts: False
  vars:
     myvars: "{{ lookup('file', './ansible_vars.json') }}"
  tasks:
    - name: update hosts
      blockinfile:
         path: /etc/hosts
         block: |
            ${var.network_lb_ip_address}  api.${var.cluster_id}.${var.base_domain}
            ${var.network_lb_ip_address}  api-int.${var.cluster_id}.${var.base_domain}
         state: absent
         marker_begin: "${var.cluster_id}"
         marker_end: "${var.cluster_id}"        
    - name: update dnsmasq
      blockinfile: 
         path: /etc/dnsmasq.conf
         block: |
            address=/.apps.${var.cluster_id}.${var.base_domain}/${var.network_lb_ip_address}
         state: absent
         marker_begin: "${var.cluster_id}"
         marker_end: "${var.cluster_id}"   

EOF
}

resource "local_file" "ansible_remove_entries_bastion" {
  content  = data.template_file.ansible_remove_entries_bastion.rendered
  filename = "${local.ansible_directory}/remove_entries.yaml"
}


resource "null_resource" "update_bastion_files" {
   #launch ansible script. 
    provisioner "local-exec" {
      when = create
      command = " ansible-playbook -i ${local.ansible_directory}/inventory ${local.ansible_directory}/add_entries.yaml --private-key=~/.ssh/id_bastion"
  }
//    provisioner "local-exec" {
//      when = destroy
//      command = " ansible-playbook -i ${local.ansible_directory}/inventory ${local.ansible_directory}/remove_entries.yaml"
//  } 
  depends_on = [
      local_file.ansible_add_entries_bastion,
      local_file.ansible_remove_entries_bastion,
  ]
}


         
