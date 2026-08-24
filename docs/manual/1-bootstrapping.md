# Manual 1 - Bootstrapping

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
