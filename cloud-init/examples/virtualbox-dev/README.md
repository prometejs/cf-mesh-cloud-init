# Example: VirtualBox dev VM (baked secret)

Hand-rendered illustration of the smallest viable user-data. For production
or any non-throwaway use, render from `cloud-init/user-data.tpl` via
`scripts/render-userdata.sh` instead — that path keeps secrets out of the
repo.

To run:

```bash
# Replace placeholders, then:
../../../scripts/make-seed-iso.sh user-data /tmp/seed.iso
```

Attach `/tmp/seed.iso` to a VirtualBox Ubuntu 22.04+ VM as a CD/DVD and boot.
