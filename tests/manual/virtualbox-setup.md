# VirtualBox setup

Stand up a PXE/seed provisioner and one or more client VMs on a macOS/Linux laptop. The provisioner serves PXE + cloud-init seeds; clients PXE-boot off it and come up as registered WARP Connectors. PXE/dnsmasq detail lives in [../../pxe/SETUP.md](../../pxe/SETUP.md).

## Prerequisites

- VirtualBox 7+
- Ubuntu Server 22.04 or 24.04 ISO
- Your ansible SSH public key

## Network topology

A VirtualBox **internal network** named `pxe-lab` carries all VM↔VM traffic — no host bridge, no laptop LAN exposure. The provisioner has a second **bridged** adapter(access to physical physical network) for outbound internet and routes clients through it once cloud-init runs.

## Provisioner VM

1. Create the VM, install Ubuntu, mount the shared storage holding the
   PXE/ISO/seed assets.
2. Attach two NICs: `pxe-lab` (internal) and a bridged adapter.
3. Note the `pxe-lab` NIC's MAC address in VirtualBox.
4. On the VM, run `netplan status` and find the interface whose MAC
   matches.
5. Pin its static IP via netplan:
   ```yaml
   network:
     version: 2
     ethernets:
       <interface-name>:
         addresses:
           - <static-ip>/24
   ```
6. Configure dnsmasq, TFTP, and the HTTP seed root — see
   [../../pxe/SETUP.md](../../pxe/SETUP.md).

## Client VMs

Create each with no installer ISO and a single NIC on `pxe-lab`. Power on — the provisioner answers DHCP/PXE and cloud-init takes over.

Once registered, every host is reachable by its
`<site>.<private_dns_suffix>` name from any WARP-enrolled client via
Cloudflare's private network — no further VirtualBox-side networking
required.

## Verify
```bash
ssh -i ~/.ssh/ansible ansible@<host> \
  'cloud-init status --long && warp-cli --accept-tos status'
```

## Tips
- `cloud-init clean --logs && shutdown -h now` produces a clean template VDI ready for cloning.
- First-boot logs: `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log`.
- Stop the Provisioner VirtualBox-internal DHCP if you previously enabled it