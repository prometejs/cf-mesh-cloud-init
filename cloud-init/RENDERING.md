# Rendering templates

The `meta-data`<sub>instance identity file</sub> and `user-data`<sub>init script file</sub> templates are required by cloud-init's NoCloud datasource (`ds=nocloud-net;`). This doc covers how we render them.

## Rendering strategies
**Pre-registration** renders instance-specific seed files ahead of time — assuming the provisioner already knows each MAC — and serves them from paths like `/var/www/html/seed/<NIC-MAC>/user-data`. Simple, but secrets end up embedded on disk and exposed over HTTP.

**Just-in-Time (JIT)** renders cloud-init data dynamically when the PXE-booted client requests it during initialization, reducing long-lived secret exposure and enabling per-boot credential generation.

## Why per-machine configs?
Each machine installs a WARP Connector and needs its own connector secret to register. In our setup the clients' MACs aren't known beforehand, so configs are generated the moment a machine actually requests them — i.e. JIT.

## How JIT actually works
The static `/var/www/html/seed/` directory tree is replaced by a tiny web service (Flask / FastAPI / Go) — see [seed-server.py](../scripts/seed-server.py).

#### Boot Sequence E2E
```mermaid
sequenceDiagram
    participant C as Client VM
    participant D as dnsmasq
    participant I as iPXE
    participant H as HTTP boot server
    participant K as Kernel / cloud-init
    participant S as Seed server
    participant V as Vault

    rect rgb(0,0,0,0)
        Note over C,H: PXE phase — firmware-driven
        C->>D: T+0s — DHCPDISCOVER
        D->>C: T+0.1s — IP + bootfile (undionly.kpxe)
        C->>D: T+0.5s — TFTP fetch undionly.kpxe
        Note over C,I: Client executes iPXE — handoff
    end

    rect rgb(0,0,0,0)
        Note over I,H: iPXE phase
        I->>D: T+1s — Own DHCP request
        D->>I: Lease + option 175 → boot.ipxe URL
        I->>H: T+1.2s — GET http://10.0.10.10/boot.ipxe
        H->>I: boot.ipxe script
        Note over I: T+1.3s — Script sets ${mac:hexhyp}<br/>URL = /seed/08-00-27-aa-bb-cc/
        I->>H: T+1.4s — GET kernel + initrd
        H->>I: kernel + initrd
    end

    rect rgb(0,0,0,0)
        Note over K,S: Kernel + cloud-init phase
        Note over K: T+5s — Kernel boots, cloud-init starts
        K->>S: T+5.5s — GET /seed/{MAC}/user-data
        Note over S: ★ Seed server first learns the MAC ★
        Note over S: T+5.6s — Validate MAC,<br/>lookup → "web-01",<br/>render user-data template
        S->>V: Wrap secret-id (role web-server, TTL 5m)
        V->>S: wrap_token
        S->>K: 200 OK with rendered YAML
        K->>S: T+5.7s — GET /seed/{MAC}/meta-data
        S->>K: instance-id
    end

    rect rgb(0,0,0,0)
        Note over K,V: Autoinstall phase (~5–15 min)
        Note over K: T+6s — Autoinstall begins
        Note over K: T+~10m — Late-commands:<br/>unwrap token, write secret-id<br/>to /etc/vault-agent/secret-id
        K->>V: Unwrap wrap_token
        V->>K: secret-id
    end

    rect rgb(0,0,0,0)
        Note over C,V: Post-reboot: Installed processes like vault agent runs
    end
```

## Securely passing secrets in the cloud-init phase
**The secret-zero problem** — how do we inject the first credential a workload needs to authenticate to a secret store, without baking long-lived secrets into images or rendered templates? That initial credential has to come from somewhere.

#### Options for injecting the secret
1. **IMDSv2 metadata bootstrap** *(recommended)* — the instance retrieves short-lived credentials from the platform metadata service during the `runcmd` phase. No static secrets in templates or user-data.
2. **Vault wrapped-token bootstrap** — a short-TTL, single-use wrapped token (e.g. 60s) is passed via cloud-init; the instance unwraps it during initialization to retrieve its real secrets.
3. **Provisioning service callout** *(selected for testing)* — the instance contacts an internal provisioning/inventory service over HTTP(S) at boot to fetch bootstrap credentials or config metadata.

*The Provisioning Service Callout suits the local VirtualBox environment: NAT networking gives reliable outbound guest-to-host communication without requiring bridged networking, cloud metadata services, or a full HashiCorp Vault deployment.*
