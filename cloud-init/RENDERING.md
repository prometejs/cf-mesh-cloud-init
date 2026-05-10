# Rendering templates
[*metadata*][instance identity file] and [*user-data*][init script file] templates provided are required by cloud-init's nocloud data source; see `ds=nocloud-net;s=http://...`. 

Each instance needs dedicated rendered configs from [meta-data.tpl](./meta-data.tpl) and [user-data.tpl](./user-data.tpl) which is stored in a /var/www/html/seed/<NIC-MAC>/user-data. This can be achieved by:
- Pre-registration (provisioner knows MACs in advance)
- Just-in-time (provisioner reacts to boot)

[Hover over me](https://example.com "This is the tooltip text!")

## Why do we need per machine configs?
each machine installs a warp connector that needs to the connector secret to be run. 

## Test case
Because clients MAC are unknown beforehand, we need to generate per-machine configs the moment a machine actually requests them.

## How Just-in-Time Actually Works
We replace static `/var/www/html/seed/` directory tree with a web application. The simplest version is a tiny Flask/FastAPI/Go service: see [seed-server.py](../scripts/seed-server.py)

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
        Note over C,V: Optional - Post-reboot — Vault Agent
        Note over C: T+~12m — Reboot
        K->>V: AppRole login (role-id + secret-id)
        V->>K: client token
        K->>V: Fetch application secrets
        V->>K: secrets
    end
```

## Securely passing secrets in the cloudinit phase
**Problem**: How do we securely inject secrets during provisioning without baking long-lived credentials into images or rendered templates?

**Challenge**: solving the “secret zero” problem: securely providing an initial credential that allows a workload to authenticate to a secret store and retrieve all other secrets during cloud-init.

#### Options for Injecting the Secret
1. **IMDSv2 Metadata Bootstrap** (Recommended): The instance retrieves short-lived credentials from the platform metadata service during the runcmd boot phase. No static secrets are embedded in templates or user data.
2. **Vault Wrapped Token Bootstrap**: A short-TTL, single-use wrapped token is passed via cloud-init. Before provisioning, HashiCorp Vault generates a wrapped bootstrap token (e.g., 60s TTL) that the instance unwraps during initialization to retrieve its actual secrets.
3. **Provisioning Service Callout** (Selected for Testing): During boot, the instance contacts an internal provisioning or inventory service over HTTP(S) to fetch bootstrap credentials or configuration metadata.

*The Network-Boot Inventory Callout approach is well-suited for the local VirtualBox test environment because NAT networking allows reliable outbound guest-to-host communication without requiring bridged networking, cloud metadata services, or a full HashiCorp Vault deployment.*