# Manual 1 - Bootstrap

This documentation describes the process of bootstrapping the Hetzner dedicated server.

## 1. Installing a base OS

Follow these steps:

1. Select the OS we want to install
    1. Select your server on the [Hetzner Robot Server Console](https://robot.hetzner.com/server)
    2. Click **Linux**
    3. Select **Debian 13 base** as **Operating System** 
    4. Select your key as the **public key**
    5. Toggle the **Data Loss** box
    6. Click **Activate Linux Installation**
2. Power the server off and then on again
    1. Click **Reset**
    2. Click **Press power button of server**
    3. Click **Send** (this powers the server off)
    4. Wait for the server to be powered off
    5. Click **Press power button of server** again
    6. Click **Send** (this powers the server back on)

Now, let's try connecting to it:

1. Click **IP** and note down your server's public IP address
2. Run, from a terminal: `ssh root@<server-ip>`

**NOTE**: if you `ssh`'d into the server before installing the OS, you'll need to reset your known host fingerprint:

```bash
ssh-keygen -R <server-ip>
```

## 2. Pointing DNS at the server

Ansible reaches the server by name, and Caddy needs names to get TLS
certificates for. All three come from DNS records you create by hand.

Follow these steps:

1. Note down the server's public IP address
    1. Select your server on the [Hetzner Robot Server Console](https://robot.hetzner.com/server)
    2. Click **IP**
2. Create the records
    1. Open the [Cloudflare dashboard](https://dash.cloudflare.com) and select the **grncunha.com** domain
    2. Click **DNS**, then **Add record**
    3. Add each of these three records:

        | Type | Name | IPv4 address | Proxy status |
        | --- | --- | --- | --- |
        | `A` | `homelab` | your server's IP | **DNS only** |
        | `A` | `vpn.homelab` | your server's IP | **DNS only** |
        | `A` | `proxmox.homelab` | your server's IP | **DNS only** |

**NOTE**: proxy status must be **DNS only** (the grey cloud), not **Proxied**
(the orange one). Cloudflare's proxy would break the TLS certificate and block
the UDP traffic the mesh needs.

Now, let's check the records work:

```bash
dig +short homelab.grncunha.com
dig +short vpn.homelab.grncunha.com
dig +short proxmox.homelab.grncunha.com
```

All three should print your server's IP address. If one prints nothing, wait a minute
and try again. If one prints a different address, that record is proxied — go
back and set it to **DNS only**.

From here on you can use the name instead of the IP:

```bash
ssh root@homelab.grncunha.com
```

Next: [Configuring the server](./2-configure-server.md).
