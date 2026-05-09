#cloud-config
# vim: set ft=yaml :
# NoCloud user-data template for Cloudflare WARP Connector hosts.
# Render with scripts/render-userdata.sh — placeholders are {{VAR}}.
# Required: HOSTNAME, ANSIBLE_SSH_PUBKEY, SECRETS_MODE
# Conditional:
#   SECRETS_MODE=baked  -> WARP_TUNNEL_TOKEN
#   SECRETS_MODE=http   -> SECRET_FETCH_URL, optional SECRET_FETCH_AUTH_HEADER
#   SECRETS_MODE=vault  -> VAULT_ADDR, VAULT_KV_PATH, plus AppRole or JWT vars

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
  - path: /etc/ssh/sshd_config.d/10-cf-hardening.conf
    permissions: "0644"
    owner: root:root
    content: |
      PasswordAuthentication no
      PermitRootLogin no
      KbdInteractiveAuthentication no
      ChallengeResponseAuthentication no
      X11Forwarding no
      AllowTcpForwarding no
      MaxAuthTries 3

  - path: /etc/cf-cloud-init/secrets.env
    permissions: "0600"
    owner: root:root
    content: |
      SECRETS_MODE={{SECRETS_MODE}}
      SECRET_FETCH_URL={{SECRET_FETCH_URL}}
      SECRET_FETCH_AUTH_HEADER={{SECRET_FETCH_AUTH_HEADER}}
      VAULT_ADDR={{VAULT_ADDR}}
      VAULT_KV_PATH={{VAULT_KV_PATH}}
      VAULT_ROLE_ID={{VAULT_ROLE_ID}}
      VAULT_SECRET_ID={{VAULT_SECRET_ID}}
      VAULT_JWT_ROLE={{VAULT_JWT_ROLE}}
      VAULT_JWT_PATH={{VAULT_JWT_PATH}}

  - path: /etc/cf-cloud-init/baked-token
    permissions: "0600"
    owner: root:root
    content: |
      {{WARP_TUNNEL_TOKEN}}

  - path: /usr/local/sbin/cf-fetch-secret
    permissions: "0700"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      # Mode-aware tunnel_token fetcher. Reads /etc/cf-cloud-init/secrets.env.
      set -euo pipefail
      # shellcheck disable=SC1091
      source /etc/cf-cloud-init/secrets.env

      case "${SECRETS_MODE:-}" in
        baked)
          tr -d '\n' < /etc/cf-cloud-init/baked-token
          ;;
        http)
          : "${SECRET_FETCH_URL:?SECRET_FETCH_URL required}"
          if [[ -n "${SECRET_FETCH_AUTH_HEADER:-}" ]]; then
            curl -fsSL -H "${SECRET_FETCH_AUTH_HEADER}" "${SECRET_FETCH_URL}" \
              | jq -r '.tunnel_token'
          else
            curl -fsSL "${SECRET_FETCH_URL}" | jq -r '.tunnel_token'
          fi
          ;;
        vault)
          : "${VAULT_ADDR:?VAULT_ADDR required}"
          : "${VAULT_KV_PATH:?VAULT_KV_PATH required}"
          if [[ -n "${VAULT_ROLE_ID:-}" && -n "${VAULT_SECRET_ID:-}" ]]; then
            body=$(jq -nc --arg r "$VAULT_ROLE_ID" --arg s "$VAULT_SECRET_ID" \
              '{role_id:$r,secret_id:$s}')
            vt=$(curl -fsSL --request POST --data "$body" \
              "${VAULT_ADDR}/v1/auth/approle/login" | jq -r '.auth.client_token')
          elif [[ -n "${VAULT_JWT_ROLE:-}" && -n "${VAULT_JWT_PATH:-}" ]]; then
            jwt=$(cat "$VAULT_JWT_PATH")
            body=$(jq -nc --arg r "$VAULT_JWT_ROLE" --arg j "$jwt" \
              '{role:$r,jwt:$j}')
            vt=$(curl -fsSL --request POST --data "$body" \
              "${VAULT_ADDR}/v1/auth/jwt/login" | jq -r '.auth.client_token')
          else
            echo "vault mode requires AppRole or JWT auth vars" >&2; exit 1
          fi
          curl -fsSL -H "X-Vault-Token: $vt" \
            "${VAULT_ADDR}/v1/${VAULT_KV_PATH}" | jq -r '.data.data.tunnel_token'
          ;;
        *)
          echo "unknown SECRETS_MODE: ${SECRETS_MODE:-<empty>}" >&2; exit 1
          ;;
      esac

  - path: /usr/local/sbin/cf-install-warp
    permissions: "0700"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      MARKER=/var/lib/cf-cloud-init/warp.registered
      mkdir -p "$(dirname "$MARKER")"

      if [[ -f "$MARKER" ]] && warp-cli --accept-tos status >/dev/null 2>&1; then
        echo "WARP already registered (marker present, status ok); skipping."
        exit 0
      fi

      . /etc/os-release
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
      arch=$(dpkg --print-architecture)
      cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
      deb [arch=$arch signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $VERSION_CODENAME main
      EOF
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp

      systemctl enable --now warp-svc

      token=$(/usr/local/sbin/cf-fetch-secret)
      if [[ -z "$token" ]]; then
        echo "failed to fetch tunnel_token" >&2; exit 1
      fi

      warp-cli --accept-tos connector new "$token"
      warp-cli --accept-tos connect

      touch "$MARKER"
      echo "WARP Connector registered."

runcmd:
  - [ systemctl, restart, ssh ]
  - [ /usr/local/sbin/cf-install-warp ]
  - [ shred, -u, /etc/cf-cloud-init/baked-token, /etc/cf-cloud-init/secrets.env ]

final_message: "cf-cloud-init: WARP Connector ready ($INSTANCE_ID, uptime $UPTIME)"
