data "template_file" "init_script_sh" {
  template = <<EOF
#!/bin/bash
echo "${chomp(tls_private_key.bastion-key.public_key_openssh)}" >> /root/.ssh/authorized_keys
chmod 644 /root/.ssh/authorized_keys
EOF
}

resource "local_file" "init_script" {
  content  = data.template_file.init_script_sh.rendered
  filename = "${path.cwd}/installer/${var.cluster_id}/init_script.sh"
  depends_on = [
    local_file.write_public_key,
  ]
}
