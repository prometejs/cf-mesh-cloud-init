# Setup — netboot.xyz

[netboot.xyz][nb] is a hosted iPXE menu — point your iPXE / PXE chainload at
`https://boot.netboot.xyz` and you get a curated menu of OS installers
without hosting any kernel/initrd images yourself.

[nb]: https://netboot.xyz/

## When to use it

- You want PXE-style network boot **without running your own image
  mirror**.
- You're booting one or two machines, occasionally.
- You're OK with a public boot endpoint (or self-host the netboot.xyz
  Docker image on your LAN — same UX).

## When *not* to use it

- Air-gapped / locked-down networks: even self-hosted, you'll need to
  mirror upstream OS assets.
- You want full control over which kernel cmdline gets passed (netboot.xyz
  menu entries don't easily inject `ds=nocloud-net;...`).

## Wiring cf-cloud-init in

netboot.xyz handles **install media delivery**. cloud-init's NoCloud
datasource still needs to find user-data. Two paths:

1. **Pass cloud-init flags via the netboot.xyz custom menu.** Self-host
   netboot.xyz on your LAN and add a custom menu entry that appends
   `ds=nocloud-net;s=http://<your-seed-host>/<host>/` to the kernel line.
2. **Use post-install on the freshly-booted OS.** Let netboot.xyz hand you
   a vanilla install, then SSH in and run `scripts/post-install-apply.sh`.
   See [post-install.md](post-install.md).

For learning purposes the first approach gives you a useful subset of PXE
without running dnsmasq/nginx yourself; the second is faster to start but
adds a manual step.

## Advantages

- **No image hosting.** netboot.xyz keeps OS installers fresh.
- **Tiny iPXE chain.** A few KB of bootcode is all you need on your LAN.
- **Self-host option.** `docker run netbootxyz/netbootxyz` for full
  on-prem.

## Trade-offs

- Customising the kernel cmdline cleanly requires a custom menu entry —
  fine for a fixed set of host types, awkward for per-host divergence.
- Public-internet boot endpoint by default — not all environments allow
  outbound from baremetal during install.
