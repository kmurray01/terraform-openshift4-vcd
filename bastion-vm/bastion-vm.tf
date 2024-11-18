
provider "vcd" {
  user                 = var.vcd_user
  password             = var.vcd_password
  org                  = var.vcd_org
  vdc                  = var.vcd_vdc
  url                  = var.vcd_url
  max_retry_timeout    = 30
  allow_unverified_ssl = true
  logging              = true
}
#retrieve edge gateway name
data "vcd_resource_list" "list_of_vdc_edges" {
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  name          = "list_of_vdc_edges"
  resource_type = "vcd_nsxt_edgegateway" # find gateway name
  list_mode     = "name"
}

data "vcd_org_vdc" "my-org-vdc" {
  name = var.vcd_vdc
}
data "vcd_nsxt_edgegateway" "edge" {
  org          = var.vcd_org
  owner_id = data.vcd_org_vdc.my-org-vdc.id
  name          = data.vcd_resource_list.list_of_vdc_edges.list[0]
}



 locals {
    ansible_directory = "/tmp"
    key_directory = pathexpand("~/.ssh")
    additional_trust_bundle_dest = dirname(var.additionalTrustBundle)
    pull_secret_dest = dirname(var.openshift_pull_secret)
    nginx_repo        = "${path.cwd}/bastion-vm/ansible"
    login_to_bastion          =  "Next Step login to Bastion via: ssh -i ~/.ssh/id_bastion root@${var.initialization_info["public_bastion_ip"]}" 
    
    edge_gateway_name = data.vcd_nsxt_edgegateway.edge.name
    edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id
    edge_gateway_primary_ip = data.vcd_nsxt_edgegateway.edge.primary_ip
 //   edge_gateway_prefix_length = tolist(data.vcd_nsxt_edgegateway.edge.subnet)[0].prefix_length
 //   edge_gateway_gateway = tolist(data.vcd_nsxt_edgegateway.edge.subnet)[0].gateway
  //  edge_gateway_allocated_ips_start_address = tolist(tolist(data.vcd_nsxt_edgegateway.edge.subnet)[0].allocated_ips)[0].start_address
 // edge_gateway_allocated_ips_end_address = tolist(tolist(data.vcd_nsxt_edgegateway.edge.subnet)[0].allocated_ips)[0].end_address
//  edge_gateway_allocated_ips_start_address = "150.240.24.50"
 edge_gateway_allocated_ips_end_address = var.initialization_info["public_bastion_ip"]

    cidr = split("/",var.initialization_info["machine_cidr"])
    cidr_length = length(local.cidr)
    cidr_prefix    = local.cidr[local.cidr_length - 1]
 }
 resource "tls_private_key" "bastion-key" {
   algorithm = "ED25519"
   ecdsa_curve ="P521"

 }
 
 resource "local_file" "write_private_key" {
   content         = tls_private_key.bastion-key.private_key_openssh
   filename        = "/root/.ssh/id_bastion"
   file_permission = 0600
 }
 
 resource "local_file" "write_public_key" {
   content         = tls_private_key.bastion-key.public_key_openssh
   filename        = "/root/.ssh/id_bastion.pub"
   file_permission = 0600
}

resource "null_resource" "generate_init_script" {
  triggers = {
    init_script = data.template_file.init_script_sh.rendered
  }
}

 resource "vcd_network_routed_v2" "net" {
   name         = var.initialization_info["network_name"]
   interface_type = "internal"
   edge_gateway_id = local.edge_gateway_id
   gateway      = cidrhost(var.initialization_info["machine_cidr"], 1)
   prefix_length = local.cidr_prefix
   dns1 = "161.26.0.10"

// dns2 = "161.26.0.11"
 
   static_ip_pool {
     start_address = var.initialization_info["static_start_address"]
     end_address   = var.initialization_info["static_end_address"]
   }
   
}

resource "vcd_nsxt_ip_set" "private-ip1" {

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  name        = "private-ip1"
  description = "IP Set Private Bastion"

  ip_addresses = [var.initialization_info["internal_bastion_ip"]]
  
        depends_on = [
          vcd_network_routed_v2.net,
  ]
}

resource "vcd_nsxt_ip_set" "public-ip1" {

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  name        = "public-ip1"
  description = "IP Set Public Bastion"

  ip_addresses = [var.initialization_info["public_bastion_ip"]]
  
          depends_on = [
            vcd_network_routed_v2.net,
  ]
}

resource "vcd_nsxt_app_port_profile" "bastion-profile-inbound" {
  context_id = data.vcd_org_vdc.my-org-vdc.id

  name        = "bastion-profile-inbound"
  description = "Application port profile for Bastion Inbound"

  scope = "TENANT"

  app_port {
    protocol = "TCP"
    port     = ["22","5000-5010"]
  }
  
          depends_on = [
            vcd_network_routed_v2.net,
  ]
}

data "vcd_nsxt_app_port_profile" "app-profile" {
  context_id = data.vcd_org_vdc.my-org-vdc.id
  name       = "bastion-profile-inbound"
  scope      = "TENANT"
      depends_on = [
        vcd_nsxt_app_port_profile.bastion-profile-inbound,
  ]
}

resource "vcd_nsxt_nat_rule" "dnat" {

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  name        = "Bastion DNAT"
  rule_type   = "DNAT"
  description = "Bastion DNAT"
//  app_port_profile_id = data.vcd_nsxt_app_port_profile.app-profile.id
 # Using primary_ip from edge gateway
  external_address = var.initialization_info["public_bastion_ip"]
  internal_address = "${var.initialization_info["internal_bastion_ip"]}/32"
  firewall_match = "MATCH_EXTERNAL_ADDRESS"
  logging          = false
        depends_on = [
          vcd_nsxt_app_port_profile.bastion-profile-inbound,
  ]
}

resource "vcd_nsxt_nat_rule" "snat" {

  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  name        = "Bastion-SNAT"
  rule_type   = "SNAT"
  description = "Bastion SNAT"
 # Using primary_ip from edge gateway
  external_address = local.edge_gateway_allocated_ips_end_address
 //   external_address = local.edge_gateway_allocated_ips_end_address

  internal_address = var.initialization_info["machine_cidr"]
        depends_on = [
          vcd_nsxt_app_port_profile.bastion-profile-inbound,
  ]
}


resource "vcd_nsxt_firewall" "bastion" {
  edge_gateway_id = data.vcd_nsxt_edgegateway.edge.id

  # Rule #1 - Allows in IPv4 traffic from security group `vcd_nsxt_security_group.group1.id`
  rule {
    action      = "ALLOW"
    name        = "bastion_inbound_allow"
    direction   = "IN"
    ip_protocol = "IPV4"
    destination_ids = [vcd_nsxt_ip_set.public-ip1.id]
    app_port_profile_ids = [data.vcd_nsxt_app_port_profile.app-profile.id]
  }

  # Rule #2 - allows putbound traffic`
  rule {
    action          = "ALLOW"
    name            = "bastion_outbound_allow"
    direction       = "OUT"
    ip_protocol     = "IPV4"
    source_ids = [vcd_nsxt_ip_set.private-ip1.id]
  }

        depends_on = [
          vcd_nsxt_app_port_profile.bastion-profile-inbound,
  ]
}






# Shows the list of all networks with the corresponding import command
//output "gateway_list" {
//  value = data.vcd_resource_list.edge_gateway_name.list
//}
# Create a Vapp (needed by the VM)
resource "vcd_vapp" "bastion" {
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  name = "bastion-${var.vcd_vdc}-${var.cluster_id}"
}
# Associate the route network with the Vapp
resource "vcd_vapp_org_network" "vappOrgNet" {
   org          = var.vcd_org
   vdc          = var.vcd_vdc
   vapp_name         = vcd_vapp.bastion.name
   reboot_vapp_on_removal = true

   org_network_name  = var.initialization_info["network_name"]
   depends_on = [vcd_network_routed_v2.net]
}

data "vcd_catalog" "my-catalog" {
  org  = var.vcd_org
  name = var.vcd_catalog
}

data "vcd_catalog_vapp_template" "vm_bastion_template" {
  catalog_id = data.vcd_catalog.my-catalog.id
  name       = var.initialization_info["bastion_template"]
}


data "local_file" "vm_init_script" {
  filename = "${path.cwd}/installer/${var.cluster_id}/init_script.sh"
  depends_on = [
    vcd_vapp_org_network.vappOrgNet,
    vcd_nsxt_nat_rule.snat,
    vcd_nsxt_nat_rule.dnat,
    vcd_nsxt_firewall.bastion,
    null_resource.generate_init_script,
    local_file.write_public_key
  ]
}

# Create the bastion VM
resource "vcd_vapp_vm" "bastion" { 
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  vapp_name     = vcd_vapp.bastion.name
  name          = "bastion-${var.vcd_vdc}-${var.cluster_id}"

  depends_on = [
    vcd_vapp_org_network.vappOrgNet,
    vcd_nsxt_nat_rule.snat,
    vcd_nsxt_nat_rule.dnat,
    vcd_nsxt_firewall.bastion,
    null_resource.generate_init_script,
    data.local_file.vm_init_script
  ]
   
  memory        = 8192
  cpus          = 2
  cpu_cores     = 1
  vapp_template_id = data.vcd_catalog_vapp_template.vm_bastion_template.id
  consolidate_disks_on_create = "true"

  override_template_disk {
    bus_type           = "paravirtual"
    size_in_mb         = var.bastion_disk
    bus_number         = 0
    unit_number        = 0
//    storage_profile    = "4 IOPS/GB"
}
  # Assign IP address on the routed network 
  network {
    type               = "org"
    name               = var.initialization_info["network_name"]
    ip_allocation_mode = "MANUAL"
    ip                 = var.initialization_info["internal_bastion_ip"]
    is_primary         = true
    connected          = true
  }
  # define Password for the vm. The the script could use it to do the ssh-copy-id to upload the ssh key
   customization {
    allow_local_admin_password = true 
    auto_generate_password = false
    admin_password = var.initialization_info["bastion_password"]
    initscript= data.local_file.vm_init_script.content
  }
  power_on = true
  # upload the ssh key on the VM. it will avoid password authentification for later interaction with the vm

}
 

 data "template_file" "ansible_inventory" {
  template = <<EOF
${var.initialization_info["public_bastion_ip"]} ansible_connection=ssh ansible_ssh_private_key_file=~/.ssh/id_bastion ansible_user=root ansible_python_interpreter="/usr/libexec/platform-python" 
EOF
}

 data "template_file" "ansible_main_yaml" {
       template = file ("${path.module}/ansible/main.yaml.tmpl")
       
       vars ={
         vcd                  = var.vcd_vdc
         public_bastion_ip    = var.initialization_info["public_bastion_ip"]
         rhel_key      = var.initialization_info["rhel_key"]
         cluster_id    = var.cluster_id
         base_domain   = var.base_domain
         lb_ip_address = var.lb_ip_address
         openshift_version = var.openshift_version
         terraform_ocp_repo = var.initialization_info["terraform_ocp_repo"]
         nginx_repo_dir = local.nginx_repo
         openshift_pull_secret = var.openshift_pull_secret
         pull_secret_dest   = local.pull_secret_dest
         terraform_root = path.cwd
         additional_trust_bundle   =  var.additionalTrustBundle
         additional_trust_bundle_dest   = local.additional_trust_bundle_dest 
         run_cluster_install       =  var.initialization_info["run_cluster_install"]
         key_directory = local.key_directory
         
       }
 }
 
resource "local_file" "ansible_inventory" {
  content  = data.template_file.ansible_inventory.rendered
  filename = "${local.ansible_directory}/inventory"
  depends_on = [
         null_resource.setup_ssh 
  ]
}

resource "local_file" "ansible_main_yaml" {
  content  = data.template_file.ansible_main_yaml.rendered
  filename = "${local.ansible_directory}/main.yaml"
  depends_on = [
         null_resource.setup_ssh 
  ]
}

resource "null_resource" "setup_bastion" {
   #launch ansible script. 

  
  provisioner "local-exec" {
      command = " ansible-playbook -i ${local.ansible_directory}/inventory ${local.ansible_directory}/main.yaml"
  }
  depends_on = [
      local_file.ansible_inventory,
      local_file.ansible_main_yaml,
  ]
}
resource "null_resource" "setup_ssh" {
 
  provisioner "local-exec" {
      command = templatefile("${path.module}/scripts/fix_ssh.sh.tmpl" , {
         bastion_password            = var.initialization_info["bastion_password"]
         public_bastion_ip           = var.initialization_info["public_bastion_ip"] 
    })
  }
    depends_on = [
        vcd_vapp_vm.bastion 
  ]
}

  data "local_file" "read_final_args" {
  filename = pathexpand("~/${var.cluster_id}info.txt")
  depends_on = [
    null_resource.setup_bastion
  ]
}

resource "local_file" "write_args" {
  content  = local.login_to_bastion
  filename = pathexpand("~/${var.cluster_id}info.txt")
  depends_on = [
         null_resource.setup_ssh 
  ]
}