# force local ignition provider binary
# provider "ignition" {
#   version = "0.0.0"
# }

locals {
  mirror_repo_ip      = [var.airgapped["mirror_ip"]]
  mirror_repo_fqdn    = [var.airgapped["mirror_fqdn"]]
  app_name            = "${var.cluster_id}-${var.base_domain}"
  vcd_net_name        = var.initialization_info["network_name"]
  cluster_domain      = "${var.cluster_id}.${var.base_domain}"
  bootstrap_fqdns     = ["bootstrap-00.${local.cluster_domain}"]
  lb_fqdns            = ["lb-00.${local.cluster_domain}"]
  api_lb_fqdns        = formatlist("%s.%s", ["api-int", "api", "*.apps"], local.cluster_domain)
  rev_api_lb_fqdns       = formatlist("%s.%s", ["api-int", "api"], local.cluster_domain)
  control_plane_fqdns = [for idx in range(var.control_plane_count) : "control-plane-0${idx}.${local.cluster_domain}"]
  compute_fqdns       = [for idx in range(var.compute_count) : "compute-0${idx}.${local.cluster_domain}"]
  storage_fqdns       = [for idx in range(var.storage_count) : "storage-0${idx}.${local.cluster_domain}"]
  no_ignition         = ""
  repo_fqdn = var.airgapped["enabled"] ? local.mirror_repo_fqdn : []
  repo_ip = var.airgapped["enabled"] ? local.mirror_repo_ip : []
  openshift_console_url = "https://console-openshift-console.apps.${var.cluster_id}.${var.base_domain}"
  export_kubeconfig     = "export KUBECONFIG=${path.cwd}/installer/${var.cluster_id}/auth/kubeconfig"
  vcd_host            = replace(replace(var.vcd_url,"https://", ""),"/api","")
  l_api_backend_addresses = flatten([
      var.bootstrap_ip_address,
      var.control_plane_ip_addresses
    ])

  }

provider "vcd" {
  user                 = var.vcd_user
  password             = var.vcd_password
  org                  = var.vcd_org
  url                  = var.vcd_url
  max_retry_timeout    = 30
  allow_unverified_ssl = true
  logging              = true
}

data "vcd_resource_list" "list_of_vdc_edges" {
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  name          = "list_of_vdc_edges"
  resource_type = "vcd_nsxt_edgegateway" # find gateway name
  list_mode     = "name"
}
data "vcd_nsxt_edgegateway" "edge" {
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  name          = data.vcd_resource_list.list_of_vdc_edges.list[0]
}

  
resource "vcd_vapp_org_network" "vappOrgNet" {
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  vapp_name         = local.app_name
  org_network_name  = var.initialization_info["network_name"]
  depends_on = [vcd_vapp.app_name]
}


resource "vcd_vapp" "app_name" {
  org          = var.vcd_org
  vdc          = var.vcd_vdc
  name = local.app_name

}
data "vcd_catalog" "my-catalog" {
  name = var.vcd_catalog
}

data "vcd_catalog_vapp_template" "vm_rhcos_template" {
  catalog_id = data.vcd_catalog.my-catalog.id
  name       = var.rhcos_template
}



resource "tls_private_key" "installkey" {
  algorithm = "RSA"
  rsa_bits  = 4096

  depends_on = [vcd_vapp_org_network.vappOrgNet]
}

resource "local_file" "write_private_key" {
  content         = tls_private_key.installkey.private_key_pem
  filename        = "${path.cwd}/installer/${var.cluster_id}/openshift_rsa"
  file_permission = 0600
}

resource "local_file" "write_public_key" {
  content         = tls_private_key.installkey.public_key_openssh
  filename        = "${path.cwd}/installer/${var.cluster_id}/openshift_rsa.pub"
  file_permission = 0600
}

module "network" {
  source        = "./network"
  cluster_ip_addresses = flatten ([
      var.bootstrap_ip_address,
      var.control_plane_ip_addresses,
      var.compute_ip_addresses,
      var.storage_ip_addresses
      ])
  airgapped     = var.airgapped
  additionalTrustBundle = var.additionalTrustBundle
  network_lb_ip_address = var.lb_ip_address
  vcd_password  = var.vcd_password
  vcd_org       = var.vcd_org
  vcd_vdc       = var.vcd_vdc
  cluster_id    = var.cluster_id
  base_domain   = var.base_domain
  initialization_info = var.initialization_info
  vcd_url       = var.vcd_url
  cluster_public_ip = var.cluster_public_ip

  depends_on = [
     local_file.write_public_key
  ]
}
module "lb" {
  count = var.create_loadbalancer_vm ? 1 : 0
  source        = "./lb"
  lb_ip_address = var.lb_ip_address
  rhcos_template_id = data.vcd_catalog_vapp_template.vm_rhcos_template.id
  initialization_info = var.initialization_info

//  api_backend_addresses = flatten([
//    var.bootstrap_ip_address,
//    var.control_plane_ip_addresses
//  ])

api_backend_addresses = local.l_api_backend_addresses
ingress_backend_addresses = var.compute_count == "0" ? local.l_api_backend_addresses : concat(var.compute_ip_addresses, var.storage_ip_addresses)
  ssh_public_key            = chomp(tls_private_key.installkey.public_key_openssh)

  cluster_domain = local.cluster_domain

  bootstrap_ip      = var.bootstrap_ip_address
  control_plane_ips = var.control_plane_ip_addresses

  dns_addresses = var.airgapped["enabled"] ? concat([var.lb_ip_address],local.mirror_repo_ip,var.vm_dns_addresses) : var.vm_dns_addresses


  dns_ip_addresses = zipmap(
    concat(
      local.repo_fqdn,
      local.bootstrap_fqdns,
      local.api_lb_fqdns,
      local.control_plane_fqdns,
      local.compute_fqdns,
      local.storage_fqdns
    ),
    concat(
      local.repo_ip,
      tolist([var.bootstrap_ip_address]),
      [for idx in range(length(local.api_lb_fqdns)) : var.lb_ip_address],
      var.control_plane_ip_addresses,
      var.compute_ip_addresses,
      var.storage_ip_addresses
    )
 )

  rev_dns_ip_addresses = zipmap(
    concat(
      local.repo_fqdn,
      local.bootstrap_fqdns,
      local.rev_api_lb_fqdns,
      local.control_plane_fqdns,
      local.compute_fqdns,
      local.storage_fqdns
    ),
    concat(
      local.repo_ip,
      tolist([var.bootstrap_ip_address]),
      [for idx in range(length(local.rev_api_lb_fqdns)) : var.lb_ip_address],
      var.control_plane_ip_addresses,
      var.compute_ip_addresses,
      var.storage_ip_addresses
    )
 )
  dhcp_ip_addresses = zipmap(
    concat(
      local.bootstrap_fqdns,
      local.control_plane_fqdns,
      local.compute_fqdns,
      local.storage_fqdns
    ),
    concat(
      tolist([var.bootstrap_ip_address]),
      var.control_plane_ip_addresses,
      var.compute_ip_addresses,
      var.storage_ip_addresses
    )
 )

  mac_prefix = var.mac_prefix
  cluster_id  = var.cluster_id

  loadbalancer_ip   = var.lb_ip_address
  loadbalancer_cidr = var.initialization_info["machine_cidr"]

  hostnames_ip_addresses  = zipmap(local.lb_fqdns, [var.lb_ip_address])
  machine_cidr            = var.initialization_info["machine_cidr"]
  network_id              = var.initialization_info["network_name"]
  loadbalancer_network_id = var.initialization_info["network_name"]

   num_cpus                = 2
   vcd_vdc                 = var.vcd_vdc
   vcd_org                 = var.vcd_org
   app_name                = local.app_name

   depends_on = [
      module.network
  ]
}
module "ignition" {
  source              = "./ignition"
  ssh_public_key      = chomp(tls_private_key.installkey.public_key_openssh)
  base_domain         = var.base_domain
  cluster_id          = var.cluster_id
  cluster_cidr        = var.openshift_cluster_cidr
  cluster_hostprefix  = var.openshift_host_prefix
  cluster_servicecidr = var.openshift_service_cidr
  machine_cidr        = var.initialization_info["machine_cidr"]
  pull_secret         = var.openshift_pull_secret
  openshift_version   = var.openshift_version
  total_node_count    = var.compute_count + var.storage_count
  storage_fqdns       = local.storage_fqdns
  storage_count       = var.storage_count
  airgapped           = var.airgapped
  initialization_info = var.initialization_info
  additionalTrustBundle = var.additionalTrustBundle
  fips                = var.fips
  compute_count       = var.compute_count
  depends_on = [
     local_file.write_public_key,
     module.network
  ]
 }

module "bootstrap" {
  source = "./vm"
  mac_prefix = var.mac_prefix
  count = var.create_vms_only ? 0 : 1

  ignition = module.ignition.append-bootstrap
  hostnames_ip_addresses = zipmap(
    local.bootstrap_fqdns,
    [var.bootstrap_ip_address]
  )

  create_vms_only = var.create_vms_only
  cluster_domain = local.cluster_domain
  machine_cidr            = var.initialization_info["machine_cidr"]
  network_id              = var.initialization_info["network_name"]
  vcd_vdc                 = var.vcd_vdc
  vcd_org                 = var.vcd_org
  app_name                = local.app_name
  rhcos_template_id = data.vcd_catalog_vapp_template.vm_rhcos_template.id
  num_cpus      = 2
  memory        = 8192
  disk_size    = var.bootstrap_disk
  initialization_info = var.initialization_info
  dns_addresses = var.create_loadbalancer_vm ? [var.lb_ip_address] : var.vm_dns_addresses
  depends_on = [
   module.network
  ]
}
module "bootstrap_vms_only" {
  source = "./vm"
  mac_prefix = var.mac_prefix
  count = var.create_vms_only ? 1 : 0
  ignition = local.no_ignition
  hostnames_ip_addresses = zipmap(
    local.bootstrap_fqdns,
    [var.bootstrap_ip_address]
  )

  create_vms_only = var.create_vms_only
  cluster_domain = local.cluster_domain
  machine_cidr            = var.initialization_info["machine_cidr"]
  network_id              = var.initialization_info["network_name"]
  app_name                = local.app_name
  vcd_vdc                 = var.vcd_vdc
  vcd_org                 = var.vcd_org
  rhcos_template_id = data.vcd_catalog_vapp_template.vm_rhcos_template.id
  num_cpus      = 2
  memory        = 8192
  disk_size    = var.bootstrap_disk
  initialization_info = var.initialization_info
  dns_addresses = var.create_loadbalancer_vm ? [var.lb_ip_address] : var.vm_dns_addresses
  depends_on = [
   module.ignition
  ]
}


module "control_plane_vm" {
  source = "./vm"
  mac_prefix = var.mac_prefix
  hostnames_ip_addresses = zipmap(
    local.control_plane_fqdns,
    var.control_plane_ip_addresses
  )

  create_vms_only = var.create_vms_only
  count = var.create_vms_only ? 0 : 1
  ignition = module.ignition.master_ignition
  network_id              = var.initialization_info["network_name"]
  vcd_vdc                 = var.vcd_vdc
  vcd_org                 = var.vcd_org
  app_name                = local.app_name
  rhcos_template_id = data.vcd_catalog_vapp_template.vm_rhcos_template.id

  cluster_domain = local.cluster_domain
  machine_cidr   = var.initialization_info["machine_cidr"]

  num_cpus      = var.control_plane_num_cpus
  memory        = var.control_plane_memory
  disk_size    = var.control_disk
  initialization_info = var.initialization_info

  dns_addresses = var.create_loadbalancer_vm ? [var.lb_ip_address] : var.vm_dns_addresses
   depends_on = [
     module.bootstrap
   ]
}
module "control_plane_vm_vms_only" {
  source = "./vm"
  mac_prefix = var.mac_prefix
  hostnames_ip_addresses = zipmap(
    local.control_plane_fqdns,
    var.control_plane_ip_addresses
  )
  count = var.create_vms_only ? 1 : 0
  create_vms_only = var.create_vms_only
  ignition = local.no_ignition
  network_id              = var.initialization_info["network_name"]
  vcd_vdc                 = var.vcd_vdc
  vcd_org                 = var.vcd_org
  app_name                = local.app_name
  rhcos_template_id = data.vcd_catalog_vapp_template.vm_rhcos_template.id


  cluster_domain = local.cluster_domain
  machine_cidr   = var.initialization_info["machine_cidr"]

  num_cpus      = var.control_plane_num_cpus
  memory        = var.control_plane_memory
  disk_size    = var.control_disk
  initialization_info = var.initialization_info

  dns_addresses = var.create_loadbalancer_vm ? [var.lb_ip_address] : var.vm_dns_addresses
  depends_on = [
    module.bootstrap
  ]
}

module "compute_vm" {
  source = "./vm"
  mac_prefix = var.mac_prefix
  hostnames_ip_addresses = zipmap(
    local.compute_fqdns,
    var.compute_ip_addresses
  )
  create_vms_only = var.create_vms_only
  count = var.create_vms_only ? 0 : 1
  ignition = module.ignition.worker_ignition

  cluster_domain = local.cluster_domain
  machine_cidr            = var.initialization_info["machine_cidr"]
  network_id              = var.initialization_info["network_name"]
  vcd_vdc                 = var.vcd_vdc
  vcd_org                 = var.vcd_org
  app_name                = local.app_name
  rhcos_template_id = data.vcd_catalog_vapp_template.vm_rhcos_template.id

  num_cpus      = var.compute_num_cpus
  memory        = var.compute_memory
  disk_size    = var.compute_disk
  initialization_info = var.initialization_info

  dns_addresses = var.create_loadbalancer_vm ? [var.lb_ip_address] : var.vm_dns_addresses
     depends_on = [
       module.bootstrap
   ]
}
module "compute_vm_vms_only" {
  source = "./vm"
  mac_prefix = var.mac_prefix
  hostnames_ip_addresses = zipmap(
    local.compute_fqdns,
    var.compute_ip_addresses
  )
  create_vms_only = var.create_vms_only
  count = var.create_vms_only ? 1 : 0
  ignition = local.no_ignition

  cluster_domain = local.cluster_domain
  machine_cidr            = var.initialization_info["machine_cidr"]
  network_id              = var.initialization_info["network_name"]
  vcd_vdc                 = var.vcd_vdc
  vcd_org                 = var.vcd_org
  app_name                = local.app_name
  rhcos_template_id = data.vcd_catalog_vapp_template.vm_rhcos_template.id

  num_cpus      = var.compute_num_cpus
  memory        = var.compute_memory
  disk_size    = var.compute_disk
  initialization_info = var.initialization_info

  dns_addresses = var.create_loadbalancer_vm ? [var.lb_ip_address] : var.vm_dns_addresses
    depends_on = [
      module.control_plane_vm
  ]
}

module "storage_vm" {
  source = "./storage"
  mac_prefix = var.mac_prefix
  hostnames_ip_addresses = zipmap(
    local.storage_fqdns,
    var.storage_ip_addresses
  )
  create_vms_only = var.create_vms_only
  count = var.create_vms_only ? 0 : 1
  ignition =  module.ignition.worker_ignition
  network_id              = var.initialization_info["network_name"]
  vcd_vdc                 = var.vcd_vdc
  vcd_org                 = var.vcd_org
  app_name                = local.app_name
  rhcos_template_id = data.vcd_catalog_vapp_template.vm_rhcos_template.id

  cluster_domain = local.cluster_domain
  machine_cidr   = var.initialization_info["machine_cidr"]

  num_cpus      = var.storage_num_cpus
  memory        = var.storage_memory
  disk_size     = var.compute_disk
  initialization_info = var.initialization_info

  extra_disk_size    = var.storage_disk
  dns_addresses = var.create_loadbalancer_vm ? [var.lb_ip_address] : var.vm_dns_addresses
  depends_on = [
      module.bootstrap
  ]
}
module "storage_vm_vms_only" {
  source = "./storage"
  mac_prefix = var.mac_prefix
  hostnames_ip_addresses = zipmap(
    local.storage_fqdns,
    var.storage_ip_addresses
  )
  create_vms_only = var.create_vms_only
  count = var.create_vms_only ? 1 : 0
  ignition = local.no_ignition
  network_id              = var.initialization_info["network_name"]
  vcd_vdc                 = var.vcd_vdc
  vcd_org                 = var.vcd_org
  app_name                = local.app_name
  rhcos_template_id = data.vcd_catalog_vapp_template.vm_rhcos_template.id

  cluster_domain = local.cluster_domain
  machine_cidr   = var.initialization_info["machine_cidr"]

  num_cpus      = var.storage_num_cpus
  memory        = var.storage_memory
  disk_size     = var.compute_disk
  initialization_info = var.initialization_info

  extra_disk_size    = var.storage_disk
  dns_addresses = var.create_loadbalancer_vm ? [var.lb_ip_address] : var.vm_dns_addresses
  depends_on = [
      module.control_plane_vm
   ]
}
  data "local_file" "kubeadmin_password" {
  filename = "${path.cwd}/installer/${var.cluster_id}/auth/kubeadmin-password"
  depends_on = [
    module.ignition
  ]
}


data "template_file" "write_final_args" {
  template = <<EOF
**********************************************************************************************************************
This information stored in: /root/${var.cluster_id}info.txt on the Bastion and the Home Directory of the Host Machine.
**********************************************************************************************************************

Kubeadmin                      : User: kubeadmin password: ${data.local_file.kubeadmin_password.content}
Bastion Public IP              : ${var.initialization_info["public_bastion_ip"]}   ssh -i ~/.ssh/id_bastion root@${var.initialization_info["public_bastion_ip"]}
Bastion Privat IP              : ${var.initialization_info["internal_bastion_ip"]}
Login to Bootstrap from Bastion: ssh -i ${path.cwd}/installer/${var.cluster_id}/openshift_rsa core@${var.bootstrap_ip_address}
Cluster Public IP              : ${var.cluster_public_ip}
OpenShift Console              : ${local.openshift_console_url}
Export KUBECONFIG              : ${local.export_kubeconfig}

Host File Entries:

${var.cluster_public_ip}  console-openshift-console.apps.${var.cluster_id}.${var.base_domain}
${var.cluster_public_ip}  oauth-openshift.apps.${var.cluster_id}.${var.base_domain}
${var.cluster_public_ip}  api.${var.cluster_id}.${var.base_domain}
EOF
}
resource "local_file" "write_final_args" {
  content  = data.template_file.write_final_args.rendered
  filename = "/root/${var.cluster_id}info.txt"
  depends_on = [
    module.ignition,
  ]
}
data "template_file" "startup_vms_script" {
  template = <<EOF
# **********************************************************************************************************************
# This script starts the vms in the cluster after all machines have been provisioned.
# **********************************************************************************************************************

vcd login ${local.vcd_host} ${var.vcd_org} ${var.vcd_user} -p ${var.vcd_password} -v ${var.vcd_vdc}
vcd vapp power-on ${local.app_name}
vcd logout
${path.cwd}/installer/${var.cluster_id}/openshift-install --dir=${path.cwd}/installer/${var.cluster_id} wait-for bootstrap-complete --log-level=info
EOF
}
resource "local_file" "startup_vms_script" {
  content  = data.template_file.startup_vms_script.rendered
  filename = "/root/${var.cluster_id}-start-vms.sh"
  depends_on = [
    module.ignition,
  ]
}


resource "null_resource" "start_vapp" {
    triggers = {
      always_run = "$timestamp()"
  }
       depends_on = [
         module.compute_vm,
         module.control_plane_vm,
         module.storage_vm,
     ]

  provisioner "local-exec"{
     command  = "/root/${var.cluster_id}-start-vms.sh"
  }
}
