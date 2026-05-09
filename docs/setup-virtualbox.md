# Setup — VirtualBox dev VM

Provision a single Ubuntu 22.04+ VM on macOS / Linux laptop using a NoCloud
seed ISO. Recommended for iterating on user-data without touching shared
infra.

## Prerequisites

- VirtualBox 7+
- Ubuntu Server 22.04 (or 24.04) ISO downloaded
- `xorriso`, `genisoimage`, or `mkisofs` (for `make-seed-iso.sh`)
- Your ansible SSH public key

## 1. Create the VM (once)

```bash
NAME=warp-dev-site-a
ISO=~/Downloads/ubuntu-22.04.5-live-server-amd64.iso

VBoxManage createvm --name "$NAME" --ostype Ubuntu_64 --register
VBoxManage modifyvm "$NAME" --memory 2048 --cpus 2 --ioapic on \
  --boot1 dvd --boot2 disk --boot3 none --boot4 none
VBoxManage createhd --filename ~/VirtualBox\ VMs/"$NAME"/"$NAME".vdi --size 20480
VBoxManage storagectl "$NAME" --name "SATA" --add sata --controller IntelAhci
VBoxManage storageattach "$NAME" --storagectl "SATA" --port 0 --device 0 \
  --type hdd --medium ~/VirtualBox\ VMs/"$NAME"/"$NAME".vdi
VBoxManage storageattach "$NAME" --storagectl "SATA" --port 1 --device 0 \
  --type dvddrive --medium "$ISO"
```

## 2. Wire an isolated network

For inter-VM discovery without exposing your laptop's LAN, use a VirtualBox
**internal network** (no host bridge) plus a host-only adapter for SSH from
the laptop.

```bash
# Adapter 1: internal network "warp-lan" (VM↔VM only)
VBoxManage modifyvm "$NAME" --nic1 intnet --intnet1 warp-lan

# Adapter 2: host-only network so the laptop can SSH in
VBoxManage hostonlyif create                            # creates vboxnet0 if missing
VBoxManage hostonlyif ipconfig vboxnet0 --ip 192.168.56.1 --netmask 255.255.255.0
VBoxManage modifyvm "$NAME" --nic2 hostonly --hostonlyadapter2 vboxnet0
```

For dnsmasq on the internal network (DHCP + DNS for VM↔VM discovery):

```bash
# Stop the VirtualBox-internal DHCP if you previously enabled it,
# then add a fresh server bound to warp-lan:
VBoxManage dhcpserver add --network=warp-lan \
  --server-ip=10.10.99.1 --lower-ip=10.10.99.50 --upper-ip=10.10.99.150 \
  --netmask=255.255.255.0 --enable
```

WARP Connector advertises each VM's CIDR into Cloudflare's private network,
so once two VMs are up and registered you can reach them by their
`<site>.<private_dns_suffix>` private DNS name from any WARP-enrolled
client — no further VirtualBox networking needed.

## 3. Render user-data and build the seed ISO

```bash
cd cf-cloud-init

WARP_TUNNEL_TOKEN="$(./scripts/fetch-warp-token.sh dev-site-a)" \
HOSTNAME=dev-site-a \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
SECRETS_MODE=baked \
  ./scripts/render-userdata.sh > /tmp/user-data

./scripts/make-seed-iso.sh /tmp/user-data /tmp/seed-dev-site-a.iso
```

## 4. Attach the seed ISO and boot

```bash
# Add a second DVD slot for the seed ISO (port 1 already has the installer)
VBoxManage storageattach "$NAME" --storagectl "SATA" --port 2 --device 0 \
  --type dvddrive --medium /tmp/seed-dev-site-a.iso

VBoxManage startvm "$NAME"
```

The Ubuntu autoinstall flow detects the `CIDATA` volume and runs cloud-init
unattended. On first boot the cloud-init log lives at
`/var/log/cloud-init.log` and the final WARP message is in
`/var/log/cloud-init-output.log`.

## 5. Verify

```bash
# From the host (host-only adapter):
ssh -i ~/.ssh/ansible ansible@<vm-host-only-ip> -- \
  'cloud-init status --long && warp-cli --accept-tos status'
```

## Tips

- After the VM boots, **detach the seed ISO** before snapshotting or
  cloning — otherwise the next boot replays cloud-init.
- `cloud-init clean --logs && shutdown -h now` produces a clean template
  VDI ready for cloning.
