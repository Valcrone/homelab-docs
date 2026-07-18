# Phase 0: Network Foundation and Base OS Install

## Objective

Wire in the Netgear GS305E managed switch with VLAN segmentation, install Proxmox VE on Node 1 (Dell Precision Tower 3420), and install Ubuntu Server 26.04 LTS on Node 2 (HP EliteDesk 800 G5 Mini). End state: both nodes reachable on the network, switch VLAN defined and ready for later phases.

## Prerequisites

- Netgear GS305E switch, power adapter, 3+ Ethernet cables (one self-terminated with crimped RJ45 connectors)
- TP-Link RE500X range extender, configured in Range Extender mode, bridging the home WiFi network to a wired Ethernet connection near the switch
- USB drive (8 GB+) for installer media
- Proxmox VE ISO (proxmox.com/downloads)
- Ubuntu Server 26.04 LTS ISO (ubuntu.com/download/server)
- Rufus or balenaEtcher for writing ISOs to USB (Proxmox's ISO only supports DD/raw write mode, not ISO/File copy mode; this is expected)
- KVM switch or equivalent temporary monitor/keyboard access to both nodes for initial install
- Both nodes backed up if any data on the Windows 11 installs needs to survive; this phase wipes both drives

## VLAN Design

| VLAN | Purpose | Status this phase |
|------|---------|--------------------|
| 1 | Default. Switch management, internet uplink | Active, untagged |
| 10 | Internal homelab traffic (Proxmox VMs, osTicket) | Defined, not yet enforced |

The GS305E's 802.1Q VLAN mode supports numeric VLAN IDs only, no name field. VLAN 10 is referred to by number only in switch configuration.

VLAN 10 traffic isolation is finalized once pfSense is built in a later phase. For this phase, both nodes stay on the untagged default VLAN so they have direct internet access for OS installation and updates.

## Port Plan (GS305E, 5 ports)

| Port | Connects to | Mode |
|------|-------------|------|
| 1 | RE500X range extender (bridging home router WiFi to wired uplink) | Untagged, VLAN 1 |
| 2 | Node 1 (Dell) | Untagged, VLAN 1 (temporary); will convert to trunk in the pfSense phase |
| 3 | Node 2 (HP) | Untagged, VLAN 1 (temporary) |
| 4 | Unused | Reserved |
| 5 | Unused | Reserved |

A direct wired connection from the router to the switch was used temporarily during initial setup to isolate a switch addressing issue (see Step 2). Once the switch itself was confirmed working correctly, the RE500X was reconnected as the permanent uplink with no further issues.

## Steps

1. Set up the RE500X range extender in Range Extender mode near the switch, bridging it to the home router's WiFi. Connect the RE500X's Ethernet port to switch Port 1 using the self-terminated (hand-crimped) cable. Connect the Dell to Port 2 and the HP to Port 3. Power on the switch.

2. Find the switch's IP address. Use a network scanning tool (e.g. Advanced IP Scanner) or the Netgear Switch Discovery Tool to locate it by manufacturer/MAC prefix rather than relying on the router's device list, which may not label it clearly.

   If the switch never received a DHCP address, it falls back to a fixed default of `192.168.0.239`; temporarily set your PC's Ethernet adapter to a static IP in the `192.168.0.x` range to reach it, log in, and set DHCP Mode to Enable + Refresh so it picks up a normal address on your home network.

   If the switch is still unreachable at that point, temporarily connect the router directly to switch Port 1 with a wired cable to rule out the extender as a variable while diagnosing. Once the switch is confirmed reachable and correctly addressed, reconnect the RE500X to Port 1 as the permanent uplink.

   Verification: switch's web GUI is reachable at an IP within your home network's normal range (not the `192.168.0.239` fallback), through the RE500X connection.

3. Log into the switch's web GUI. Default credentials are on a label on the switch itself.

   Under the **VLAN** tab, switch to **802.1Q** mode (not Port-Based). Enabling 802.1Q disables Port-Based VLAN mode; this is expected. Create VLAN ID `10`. Leave all ports on VLAN 1 for now, do not tag any ports yet.

   Verification: VLAN table shows both VLAN 1 (all ports) and VLAN 10 (no ports) listed.

4. Create install media. Download the Proxmox VE ISO and the Ubuntu Server 26.04 LTS ISO. Verify the Proxmox ISO's SHA256 checksum against the value published on the Proxmox downloads page before writing it. Use Rufus or balenaEtcher to write the Ubuntu ISO to the USB drive first.

5. Start the Ubuntu Server 26.04 install on Node 2 (HP EliteDesk).

   Boot from USB, select "Install Ubuntu Server." Accept defaults for network (DHCP) and storage (use entire disk, LVM group, no encryption). Set hostname, username, and password. Say yes to installing OpenSSH server; leave password authentication over SSH enabled. Skip Ubuntu Pro. Skip all Featured Server Snaps. Let the install run.

   This step can run unattended once past the initial prompts. Move to Step 6 while it finishes.

6. Write the Proxmox VE ISO to a second USB drive, or reuse the first once Node 2's install has copied what it needs from it.

7. Start the Proxmox VE install on Node 1 (Dell Precision Tower).

   Boot from USB in **UEFI mode** (not Legacy; switching Legacy/UEFI modes can affect the existing Windows Boot Manager entries and is not needed for this install). If the USB drive does not appear in the boot menu in any mode, check BIOS Setup → System Configuration → USB Configuration → **Enable USB Boot Support**. This setting is disabled by default on some Dell business-class systems and independently blocks USB booting regardless of Secure Boot or Legacy/UEFI mode.

   Select "Install Proxmox VE (Graphical)." Accept the disk target, set country/timezone/keyboard layout, set a root password and email. On the Management Network Configuration screen, the Hostname field requires a fully qualified domain name (must contain a dot); a plain hostname like `homelab-node1` is rejected. Use a form like `homelab-node1.local` instead. Note: `.local` is used here for expediency at the OS-hostname level only; it is not the recommended choice for a network domain more broadly. See Phase 1 for why `.local`/mDNS conflicts matter for pfSense's own domain setting, and consider aligning this hostname's suffix in a later cleanup pass if consistency matters for the portfolio writeup. Confirm the auto-detected IP, gateway, and DNS match your home network range.

   Verification: after reboot, the console shows `https://<node1-ip>:8006/`. Confirm it's reachable from a browser on the same network (expect a self-signed certificate warning, this is normal).

8. Confirm Node 2 finished installing. SSH into it:

   ```bash
   ssh <username>@<node2-ip>
   ```

   Verification: SSH session opens without error.

9. Fix Proxmox's default repository configuration before updating. A fresh install has only the paid enterprise repositories enabled, which causes `apt-get update` to fail with exit code 100 since there's no subscription key.

   In the Proxmox web GUI: Node → Updates → Repositories. Disable both `pve-enterprise` and `ceph-enterprise` sources. Add the `pve-no-subscription` repository. Do not add a Ceph repository of any kind; this build has no Ceph component.

   Verification: Node → Updates → Refresh completes without error, and shows "You get updates for Proxmox VE."

10. Update both nodes.

    On Node 1, through the Proxmox web GUI: Node → Updates → Refresh, then Upgrade. If a kernel update is installed, reboot the node afterward to activate it (Node → Reboot).

    On Node 2:

    ```bash
    sudo apt update && sudo apt upgrade -y
    ```

11. Commit phase documentation and tag the milestone.

    ```bash
    git add .
    git commit -m "Phase 0: network foundation and base OS install"
    git tag v0.2.0-foundation
    git push
    git push --tags
    ```

## Verification

- Switch web GUI shows VLAN 10 created (802.1Q mode)
- Proxmox web GUI reachable at `https://<node1-ip>:8006`, no repository errors, current updates installed
- Node 2 reachable via SSH, current updates installed

## Common Mistakes

- Self-crimped cable showing link issues or no link light. Recheck the wire order against the T568B standard and confirm the connector is fully seated (all 8 pins visibly touching the contacts) before assuming it's a switch or port problem.
- Assuming the switch itself is broken when it's unreachable. Check whether it actually received a DHCP address before suspecting the extender, cabling, or switch hardware; a temporary direct router-to-switch connection is a useful way to isolate the switch from the extender as a variable.
- Writing the wrong ISO to the USB drive, or a corrupted/incomplete download; verify the checksum before writing, especially for the Proxmox ISO.
- USB drive not appearing in the Dell's boot menu in any mode. Check BIOS Setup → USB Configuration → Enable USB Boot Support before assuming the media or Secure Boot settings are the problem.
- Switching a Dell system between Legacy and UEFI boot mode when Windows is still installed. This can cause "No Boot Device Found" since Windows' GPT/UEFI setup won't be found in Legacy mode. Switch back to UEFI to recover.
- Entering a plain hostname (no dot) on the Proxmox network configuration screen; it requires an FQDN format.
- Running `apt-get update`/Proxmox's Updates → Refresh immediately after install without disabling the enterprise repositories first; fails with exit code 100.
- Forgetting to enable OpenSSH server during the Ubuntu install, which means no remote access to Node 2 until a monitor/keyboard is reattached.
- Skipping the post-upgrade reboot on Proxmox when a new kernel was installed; the node keeps running the old kernel until rebooted.

## Time Estimate

2-3 hours for a clean run. Budget extra time if troubleshooting USB boot detection or BIOS settings on unfamiliar hardware.
