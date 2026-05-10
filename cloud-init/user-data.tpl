#cloud-config
# vim: set ft=yaml :
# NoCloud user-data template for Cloudflare WARP Connector hosts.
# Render with scripts/render-userdata.sh — placeholders are {{VAR}}.

hostname: {{HOSTNAME}}
fqdn: {{HOSTNAME}}
manage_etc_hosts: true
preserve_hostname: false

package_update: true
package_upgrade: false
packages:
  - curl
  - gnupg
  - jq
  - ca-certificates
  - lsb-release
  - openssh-server
  - unattended-upgrades

users:
  - default
  - name: warp
    system: true
    shell: /usr/sbin/nologin
  - name: ansible
    gecos: Ansible automation user
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - {{ANSIBLE_SSH_PUBKEY}}

ssh_pwauth: false
disable_root: true

write_files:
  - path: /etc/systemd/system/warp-connector.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Cloudflare WARP Connector
      After=network.target

      [Service]
      Type=simple
      User=warp
      # Load the $WARP_TOKEN environment variable from a secure file 
      EnvironmentFile=/etc/warp/connector.env 
      # 1. Register the token (runs before the main process), configures WARP client into "Connector mode" acting as a site-to-site or subnet router rather than a standard user VPN
      ExecStartPre=/usr/local/bin/warp-cli --accept-tos connector new ${WARP_TOKEN}
      # 2. Connect to the WARP network (ExecStart), this will establish the tunnel and keep it alive
      ExecStart=/usr/local/bin/warp-cli --accept-tos connect
      Restart=on-failure
      RestartSec=10

      [Install]
      WantedBy=multi-user.target
  
  - path: /etc/ssh/sshd_config.d/10-cf-hardening.conf
    permissions: "0644"
    owner: root:root
    content: |
      # SSH Hardening: Enforce key-only authentication, block root, and disable tunneling
      PasswordAuthentication no
      PermitRootLogin no
      KbdInteractiveAuthentication no
      ChallengeResponseAuthentication no
      X11Forwarding no
      AllowTcpForwarding no
      MaxAuthTries 3

runcmd:
  # Restart SSH to apply hardening changes, ensuring the instance is secure before WARP connection is established
  - systemctl restart ssh
  
  # 1. Download cloudflare warp
  - curl -fsSL cloudflareclient.com | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  - echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] cloudflareclient.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
  - apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp

  # 2. Set up the secure configuration directory
  - mkdir -p /etc/warp
  - chown -R warp:warp /etc/warp
  - chmod 700 /etc/warp

  # 3. INTERPOLATE MAC INTERFACE LOGIC TO FETCH DYNAMIC TARGET SECRET
  # Identify the primary default network interface route and grab its hardware MAC identifier
  - export PRIMARY_INTERFACE=$(ip route show default | awk '{print $5}' | head -n1)
  - export NIC_MAC=$(cat /sys/class/net/${PRIMARY_INTERFACE}/address)
  
  # Ping the dynamic internal Seed Server app router path using the identified MAC address
  # The seed server verifies the request against its current inventory database and mints credentials
  - export SEED_SERVER_URL="internal.net{NIC_MAC}"
  - export FETCHED_TOKEN=$(curl -sS --fail "${SEED_SERVER_URL}" | jq -r '.warp_orchestration_token')

  # Parse payload directly into runtime service system paths 
  - echo "WARP_TOKEN=${FETCHED_TOKEN}" > /etc/warp/connector.env
  - chown warp:warp /etc/warp/connector.env
  - chmod 600 /etc/warp/connector.env

  # 4. Clear environment variables to clean up system footprint logs
  - unset PRIMARY_INTERFACE
  - unset NIC_MAC
  - unset FETCHED_TOKEN

  # 5. Flush configurations and initialize the background service
  - systemctl daemon-reload
  - systemctl enable --now warp-connector.service

final_message: "cf-cloud-init: WARP Connector ready ($INSTANCE_ID, uptime $UPTIME)"


# Vault-Agent One-Shot Token Wrapping runcmd
# runcmd:
#   ...
#   # 2. Install Vault binary for programmatic unwrapping
#   - curl -fsSL hashicorp.com | gpg --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
#   - echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
#   - apt-get update && apt-get install -y vault
#   # Replace 'VAULT_ADDR_HERE' and 'WRAPPED_TOKEN_HERE' via deployment pipeline variable interpolation
#   - export VAULT_ADDR="internal.net"
#   - export WRAPPED_TOKEN="s.X4jHk92Lp01Mv..."   
#   # Unwrap the one-shot token to get the real WARP orchestration secret token
#   - export WARP_SECRET=$(VAULT_TOKEN="$WRAPPED_TOKEN" vault kv get -field=token secret/data/cloudflare/connector)
#   # Clear sensitive installation variables out of active shell process memory
#   - unset WRAPPED_TOKEN
#   - unset WARP_SECRET
#   ...
