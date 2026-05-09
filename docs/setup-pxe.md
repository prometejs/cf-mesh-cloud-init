# Setup — PXE / iPXE bare metal

Boot bare-metal hosts from the network with a NoCloud datasource served over
HTTP. Recommended when you control the LAN and want a roll-your-own
provisioning path. For a managed alternative see
[setup-maas.md](setup-maas.md) or [setup-tinkerbell.md](setup-tinkerbell.md).

## Topology

```
   ┌─────────────────────┐                ┌──────────────────────┐
   │  Provisioner host   │                │   Bare-metal target   │
   │  10.0.10.10         │                │   (PXE boot, no OS)   │
   │                     │                │                       │
   │  dnsmasq (DHCP+TFTP)│ DHCP/TFTP/HTTP │                       │
   │  nginx (HTTP seed)  │◀──────────────▶│                       │
   │  /srv/tftp          │                │                       │
   │  /srv/http          │                │                       │
   └─────────────────────┘                └──────────────────────┘
```

## 1. Provisioner host packages

```bash
sudo apt-get install -y dnsmasq nginx ipxe pxelinux syslinux-common
```

## 2. dnsmasq (DHCP + TFTP + PXE chainload)

Copy [`pxe/dnsmasq.conf.example`](../pxe/dnsmasq.conf.example) to
`/etc/dnsmasq.d/pxe.conf`, adjust the network/IPs, then:

```bash
sudo install -m0644 /usr/lib/PXELINUX/lpxelinux.0  /srv/tftp/
sudo install -m0644 /usr/lib/syslinux/modules/bios/{ldlinux.c32,vesamenu.c32,libcom32.c32,libutil.c32} /srv/tftp/
sudo install -m0644 /usr/lib/ipxe/undionly.kpxe /srv/tftp/
sudo install -m0644 /usr/lib/ipxe/ipxe.efi      /srv/tftp/   # if you have UEFI hosts
sudo systemctl restart dnsmasq
```

## 3. iPXE boot script over HTTP

Copy [`pxe/ipxe-boot.example`](../pxe/ipxe-boot.example) to
`/srv/http/boot.ipxe`. Ensure `/srv/http/ubuntu/22.04/{vmlinuz,initrd,*.iso}`
are present (extract from a fresh Ubuntu live-server ISO).

The kernel cmdline contains the NoCloud directive:

```
ds=nocloud-net;s=http://10.0.10.10/seed/${mac:hexhyp}/
```

iPXE substitutes `${mac:hexhyp}` with the booting NIC's MAC, so each host
gets its own seed directory.

## 4. Render per-host seeds

For each site you want to provision, render and place a `user-data` and
`meta-data` file under `/srv/http/seed/<MAC>/`:

```bash
SITE=site-a
MAC_HEX=01-aa-bb-cc-dd-ee-ff   # the booting host's NIC MAC, hex-hyphenated
DEST=/srv/http/seed/$MAC_HEX

mkdir -p "$DEST"

HOSTNAME=$SITE \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
SECRETS_MODE=http \
SECRET_FETCH_URL="https://secrets.internal/warp/$SITE?nonce=$(uuidgen)" \
SECRET_FETCH_AUTH_HEADER="Authorization: Bearer $(cat enrollment.token)" \
  ./scripts/render-userdata.sh > "$DEST/user-data"

cat > "$DEST/meta-data" <<EOF
instance-id: $SITE-$(date +%s)
local-hostname: $SITE
EOF
```

`SECRETS_MODE=http` is recommended over `baked` here so the tunnel_token
never sits in the HTTP-served user-data.

## 5. Boot the host

Power on with PXE first in BIOS/UEFI. dnsmasq → iPXE → kernel + initrd →
autoinstall + cloud-init → WARP registered.

Watch progress on the provisioner: `journalctl -u dnsmasq -f` and
`tail -f /var/log/nginx/access.log`. On the target, switch to TTY2 during
install for live cloud-init logs.

## Troubleshooting

- **iPXE loops back to BIOS PXE.** dnsmasq tags aren't matching; re-check
  `dhcp-match=set:ipxe,175` and your client-arch tags.
- **Kernel boots but no seed found.** Verify the URL — `curl
  http://10.0.10.10/seed/$MAC_HEX/user-data` from another host on the LAN.
  Cloud-init's NoCloud datasource appends `user-data` and `meta-data` to
  the `s=` path, so the trailing slash matters.
- **Seed served but cloud-init never runs.** The kernel may have the wrong
  `ds=` syntax. Cloud-init wants exactly `ds=nocloud-net;s=...` — the
  semicolon and comma matter.
