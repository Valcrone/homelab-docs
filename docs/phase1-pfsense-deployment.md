# Phase 1: pfSense Deployment and VLAN 10 Activation

## Objective

Deploy pfSense as a VM inside Proxmox on Node 1, with WAN bound to VLAN 1 and LAN bound to VLAN 10. This activates VLAN 10 as a real, routed network segment. It previously existed only as an unused switch definition from Phase 0.

## Prerequisites

- Phase 0 complete: switch, VLAN 10 defined, both nodes installed and updated
- Netgate Installer ISO (`netgate-installer-vX.X-RELEASE-amd64.iso.gz`) downloaded from shop.netgate.com/products/netgate-installer, checksum verified against the official checksums file (netgate.com/hubfs/pfSense-plus-installer-checksums.txt) before decompressing
- 7-Zip or equivalent to decompress the `.gz` to a plain `.iso`
- A spare switch port and Ethernet cable for temporary direct PC access to VLAN 10 during initial pfSense configuration

## Steps

1. Change the Dell's switch port (Port 2) from a VLAN 1-only access port to a trunk port carrying both VLANs. In the switch's 802.1Q VLAN Membership screen, with VLAN ID set to `10`, mark Port 2 as **T** (tagged). Port 2 remains untagged on VLAN 1 (unchanged from Phase 0).

   Verification: switch and Proxmox dashboard remain reachable immediately after applying.

2. Make the existing `vmbr0` bridge VLAN aware, rather than creating a second bridge. Node → Network → select `vmbr0` → Edit → check **VLAN aware** → Apply Configuration.

   Verification: `vmbr0`'s VLAN aware column shows Yes, Proxmox dashboard remains reachable.

3. Upload the verified pfSense ISO to Proxmox's local storage: Node → local → ISO Images → Upload → select the `.iso` file (not the `.gz`). Hash algorithm can be left as SHA-256 with the checksum pasted in, or set to None if verification was already done locally. Leaving the checksum field literally blank causes an upload failure, since the field defaults to the placeholder text "none" rather than an empty value.

4. Create the VM: Create VM → General (name: `pfsense`) → OS (select the uploaded ISO; Guest OS Type: **Other**, since pfSense is FreeBSD-based, not Linux) → System (defaults fine) → Disks (change Bus/Device from IDE to **SATA**; 32G on `local-lvm` is sufficient) → CPU (**2 cores**, socket: 1) → Memory (**2048 MiB**) → Network (first NIC: bridge `vmbr0`, no VLAN tag, model **VirtIO**, uncheck Proxmox's per-interface Firewall checkbox since pfSense handles firewalling itself) → Confirm → Finish. Leave "Start after created" unchecked.

5. Add the second NIC before first boot: VM → Hardware → Add → Network Device → bridge `vmbr0`, **VLAN Tag: 10**, model VirtIO, Firewall unchecked.

   Verification: Hardware tab shows two Network Devices, one with no tag (WAN) and one with `tag=10` (LAN).

6. Start the VM, open its Console. Netgate Installer boots: Accept license, Install pfSense, WAN interface = vtnet0 (matches the untagged NIC's MAC), DHCP mode for WAN, LAN interface = vtnet1 (matches the VLAN 10-tagged NIC's MAC), static LAN IP (default `192.168.1.1/24` is fine, becomes VLAN 10's addressing).

7. Select **Install CE** at the subscription validation screen (no active Plus subscription). ZFS file system, GPT partition scheme, single-disk stripe (expected and fine for a single virtual disk). Confirm the destroy-disk warning (safe: this is the VM's own empty virtual disk, unrelated to any other data). Reboot when installation completes.

   Common issue: if the console stops responding to any input (arrow keys, Enter) after a confirmation screen, the noVNC session itself has broken, not the VM. Close the console tab and reopen a fresh one from the VM's page rather than waiting or retrying keystrokes.

8. Confirm clean boot: console should show the pfSense menu directly (not the installer again), with WAN and LAN interfaces listed along with their IPs.

9. pfSense's web GUI listens on the LAN interface only, by design, and nothing is connected to VLAN 10 yet at this point. Set an unused switch port (Port 4) to untagged VLAN 10:
   - Port PVID Configuration: set Port 4's PVID to `10`
   - VLAN Membership (VLAN 1): remove Port 4 (must change PVID first; the switch will not allow removing a port from a VLAN matching its current PVID)
   - VLAN Membership (VLAN 10): add Port 4 as **U** (untagged)

10. Connect a PC directly to Port 4 via Ethernet cable. Renew its network lease (`ipconfig /release` then `ipconfig /renew` on Windows) rather than waiting for automatic renewal.

    Verification: `ipconfig` shows an address in `192.168.1.x` with gateway `192.168.1.1` on the wired adapter.

11. Browse to `http://192.168.1.1`. Log in with `admin` / `pfsense` (default credentials).

12. Setup wizard, General Information: hostname/domain defaults are fine (`home.arpa`, not `.local`, avoids mDNS conflicts). Leave DNS servers blank (Override DNS checked) to use WAN-provided DNS automatically.

13. Time Server Information: set Timezone to match your actual location (not the UTC default). This matters for correlating logs and alerts in later phases.

14. Configure WAN Interface: DHCP, defaults fine. **Uncheck "Block RFC1918 Private Networks."** This is required whenever pfSense's WAN address is itself a private range (e.g. `10.0.0.x`), which is the case in any setup where pfSense sits behind an existing home router (double NAT). Leaving this checked blocks pfSense's own legitimate WAN traffic. Leave "Block bogon networks" checked, unrelated setting.

15. Configure LAN Interface: confirm `192.168.1.1/24` matches what was set during install.

16. Change admin Account Password: set a new password, distinct from other node passwords given this device's role as the network's edge firewall.

17. Reload and finish. Confirm the dashboard loads and shows both interfaces up with correct IPs.

18. Keep Port 4 permanently designated as the VLAN 10 admin access port, rather than reverting it. No device lives on VLAN 10 permanently yet (that starts in later phases with Zabbix, Wazuh, and osTicket), so a known, dedicated port for reaching pfSense's dashboard is more practical than reconfiguring the switch each time admin access is needed. Disconnect the PC's cable from Port 4 when done; the port's VLAN 10 membership stays in place for next time. The PC's WiFi adapter remains on VLAN 1 throughout and needs no changes, only the wired adapter goes idle on disconnect.

19. Commit phase documentation and tag the milestone.

    ```bash
    git add .
    git commit -m "Phase 1: pfSense deployment and VLAN 10 activation"
    git tag v0.3.0-pfsense
    git push
    git push --tags
    ```

## Verification

- pfSense dashboard reachable at `192.168.1.1` from a device on VLAN 10
- WAN interface shows a valid DHCP-assigned address from the home network
- LAN interface shows `192.168.1.1`, DHCP server active
- Switch Port 2 confirmed as a trunk (untagged VLAN 1, tagged VLAN 10)
- Proxmox `vmbr0` confirmed VLAN aware
- Switch Port 4 confirmed as a permanent untagged VLAN 10 access port, reserved for pfSense dashboard admin access

## Common Mistakes

- Leaving "Block RFC1918 Private Networks" enabled when WAN itself has a private address; this silently blocks pfSense's own internet connectivity.
- Trying to reach pfSense's dashboard from a device still on VLAN 1; the two networks cannot communicate directly until pfSense's own firewall/NAT rules are configured to permit it.
- Assuming a frozen installer console means the install itself hung; check whether basic key presses (arrow keys) have any effect at all before assuming a slow process, a broken noVNC session is a much more common cause and is fixed by reopening the console tab.
- Attempting to remove a switch port from a VLAN's membership without first changing that port's PVID away from the same VLAN; the switch will reject the membership change until PVID is updated first.
- Leaving the checksum field literally as the word "none" during an ISO upload in Proxmox; this is read as a literal expected hash and causes the upload to fail verification.
- Selecting IDE for the VM's disk bus by default; works, but is a slower legacy option with no benefit for this VM.

## Time Estimate

2-3 hours for a clean run, longer if working through console/keyboard-focus issues or unfamiliar BIOS/VLAN settings.
