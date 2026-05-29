# PXE + iPXE bare metal

> The steps below are automated by
> [`scripts/bootstrap-provisioner.sh`](../scripts/bootstrap-provisioner.sh) —
> run that for a one-shot setup. This page is the reference for what it does.

## iPXE
open-source enhanced replacement for PXE firmware; speaks all the modern protocols the original PXE spec lacks. iPXE doesn't replace client's PXE firmware. it is chainloaded, client does PXE boot, the DHCP server tells it to load the iPXE binary instead of pxelinux.0. bare-metal hosts boots from network with a NoCloud datasource served over HTTP.

#### Sequence
```mermaid
sequenceDiagram
    participant C as Client firmware
    participant D as DHCP server
    participant T as TFTP server
    participant I as iPXE
    participant H as HTTP server
    rect rgba(0,0,0, 0)
    Note over C,T: PXE phase — identical to regular PXE
    C->>D: 1. sends DHCPDISCOVER, Need IP and boot file
    D->>C: 2. IP + undionly.kpxe via TFTP
    C->>T: 3. Send undionly.kpxe
    T->>C: 4. iPXE binary (~80 KB)
    end
    Note over C,I: 5. Client runs iPXE — iPXE takes over
    I->>D: 6. DHCP request (own network stack)
    D->>I: Lease + optional script URL
    alt 7. Script provided?
        I->>H: 8. Fetch iPXE script via HTTP
        H->>I: Script body
        Note over I: 9. Script says: boot kernel/ISO from HTTP URL
        I->>H: 10. GET kernel/ISO
        H->>I: Boot files (fast)
        Note over I: iPXE boots the kernel
    else No script
        Note over I: Fall back to default boot
    end
```

## Configuring PXE server
```
   ┌─────────────────────┐                ┌───────────────────┐
   │ Provisioner host    │                │ Bare-metal target │
   │ 10.0.10.10          │                │ (PXE boot, no OS) │
   │                     │                │                   │
   │ dnsmasq (DHCP+TFTP) │ DHCP/TFTP/HTTP │                   │
   │ apache (HTTP seed)  │◀──────────────▶│                   │
   │ /srv/tftp           │                │                   │
   │ /var/www/html       │                │                   │
   └─────────────────────┘                └───────────────────┘
```

### 1. Install packages
```bash
sudo apt-get install -y dnsmasq apache2
sudo a2enmod proxy proxy_http   # for the /seed/ reverse-proxy
```
### 2. Load iPXE binaries
i. Create the TFTP directory:
```bash
sudo mkdir -p /srv/tftp
```
ii. Load the iPXE binaries into `/srv/tftp/`.
#### Option A — via the `ipxe` package
```bash
sudo apt-get install -y ipxe
sudo install -m0644 /usr/lib/ipxe/undionly.kpxe /srv/tftp/
sudo install -m0644 /usr/lib/ipxe/ipxe.efi      /srv/tftp/   # if you have UEFI hosts
```
#### Option B — via `wget`
```bash
sudo wget -P /srv/tftp/ http://boot.ipxe.org/undionly.kpxe
sudo wget -P /srv/tftp/ http://boot.ipxe.org/ipxe.efi        # for UEFI clients
```
### 3. Configure dnsmasq (DHCP + TFTP + PXE -> iPXE chainload)
Copy [`pxe/dnsmasq.conf.example`](./dnsmasq.conf.example) to
`/etc/dnsmasq.d/pxe.conf` and replace the `{{...}}` placeholders with your
network/IPs (the bootstrap script renders this for you).
### 4. Add iPXE boot script
i. Create the Web Server directory:
```bash
sudo mkdir -p /var/www/html
```
ii. Copy [`pxe/boot.ipxe.example`](boot.ipxe.example) to
`/var/www/html/boot.ipxe` and replace the `{{IP}}`/`{{UBUNTU_VERSION}}`
placeholders (the bootstrap script renders this for you).
### 5. Add ISO boot files
Ensures `/var/www/html/ubuntu/22.04/{vmlinuz,initrd,*.iso}`
are present (extract from a fresh Ubuntu live-server ISO).
```bash
sudo mkdir -p /var/www/html/ubuntu
sudo mount -o loop ubuntu-22.04.4-live-server-amd64.iso /mnt
sudo cp -r /mnt/* /var/www/html/ubuntu/
sudo umount /mnt
``` 
### 6. Configure Apache (static PXE + seed proxy)
A single vhost both serves the static PXE assets from `/var/www/html`
(`/boot.ipxe`, `/ubuntu/<ver>/…`) **and** reverse-proxies `/seed/` to the
Python seed daemon on `127.0.0.1:8080`. Copy
[`pxe/apache-provisioner.conf.example`](apache-provisioner.conf.example) to
`/etc/apache2/sites-available/cf-mesh-provisioner.conf`, then enable it:
```bash
sudo cp pxe/apache-provisioner.conf.example /etc/apache2/sites-available/cf-mesh-provisioner.conf
sudo a2ensite cf-mesh-provisioner
sudo a2dissite 000-default        # this vhost is now the file server for /var/www/html
```
Everything is restricted to RFC1918 clients — tighten the `Require ip` CIDR
lists in the vhost to your actual PXE/management subnets. (For a host that
serves *only* seeds with no PXE files, use the locked-down
[`tests/deploy/seed-server.conf`](../tests/deploy/seed-server.conf) instead.)
### 7. Restart everything and test
```bash
sudo systemctl restart dnsmasq
sudo systemctl restart apache2
# static asset must be served (200), not 403:
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/boot.ipxe
# seed proxy up (200 for a known MAC, 404 otherwise — both prove Apache→Python):
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/seed/aa-bb-cc-00-00-0a/meta-data
```

## Rendering Host/Client
For each site you want to provision, render and place a `user-data` and
`meta-data` file under `/var/www/html/seed/<NIC-MAC>/`

See more in [cloud-init/RENDERING.md](../cloud-init/RENDERING.md)

## Starting a Host/Client
Power on with PXE first in BIOS/UEFI. 

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

## Monitoring
On provisioner to watch DHCP/TFTP requests live:
```bash
sudo journalctl -u dnsmasq -f 
tail -f /var/log/apache/access.log
```
On the target, switch to TTY2 during install for live cloud-init logs.
