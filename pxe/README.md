# pxe/

Sample configs for booting bare-metal hosts via PXE/iPXE with the NoCloud
datasource pulled over HTTP.

Files here are illustrative — paths, IPs, and MAC addresses must be adjusted
to your LAN. See [`docs/setup-pxe.md`](../docs/setup-pxe.md) for the full
walkthrough.

| File | Role |
|---|---|
| `dnsmasq.conf.example`     | DHCP + TFTP + PXE chainload to iPXE |
| `pxelinux.cfg-default.example` | Legacy PXELINUX menu (BIOS hosts) |
| `ipxe-boot.example`        | iPXE script: chainloads kernel + initrd, sets cloud-init `ds=` |
