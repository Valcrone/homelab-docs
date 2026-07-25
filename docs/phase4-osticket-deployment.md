# Phase 4: Node 2 VLAN 10 Migration and osTicket Deployment

## Objective

Move Node 2 from the untagged home network onto VLAN 10, matching the architecture's intended segmentation, then deploy osTicket as a Docker-based ticketing system on Node 2. End state: Node 2 lives on the same protected network as pfSense, Zabbix, and Wazuh, and osTicket is reachable with a working staff panel and public ticket submission.

## Prerequisites

- Phase 3 complete: Zabbix and Wazuh both deployed and monitoring both physical nodes
- Physical or console access to Node 2 available, needed once during the VLAN migration since its network identity changes mid-process
- Node 2's current switch port confirmed (Port 3, per the Phase 0 port plan)

## Steps

1. On the switch's web GUI, move Port 3 from VLAN 1 to VLAN 10. The order matters and differs from a first glance at the settings: add the port to the destination VLAN's membership first, then change its PVID, then remove it from the old VLAN's membership. Attempting to set a port's PVID to a VLAN it is not yet a member of is rejected; attempting to remove a port from a VLAN that still matches its current PVID is also rejected.

   - VLAN Membership, VLAN 10: set Port 3 to U (untagged)
   - Port PVID Configuration: set Port 3's PVID to 10
   - VLAN Membership, VLAN 1: remove Port 3

   Node 2 loses its current network connection immediately once the last step applies; this is expected.

2. Force Node 2 to renew its network lease. A VLAN membership change at the switch does not cause the physical link to drop, so a DHCP client will often keep using its old, now-invalid lease indefinitely rather than detecting the change and renewing automatically. If dedicated DHCP client tools are unavailable, flapping the interface forces nearly any DHCP client to renew:

   ```bash
   sudo ip link set eno1 down
   sudo ip link set eno1 up
   ip a
   ```

   Verification: `ip a` shows a `192.168.1.x` address on the main interface, replacing the old `10.0.0.x` address.

3. Confirm connectivity on the new network.

   ```bash
   ping -c 3 192.168.1.1
   ping -c 3 8.8.8.8
   ```

   Both should succeed, confirming the gateway and outbound internet routing work correctly on VLAN 10.

4. Update the monitoring agents already installed on Node 2 from Phases 2 and 3. Both were configured to reach their respective servers through a NAT port forward on pfSense's WAN address, a workaround required only because Node 2 used to sit on a different network than the Zabbix and Wazuh VMs. Now that Node 2 shares VLAN 10 with both of them directly, point each agent at the real internal address instead; this is simpler and removes an unnecessary NAT hop.

   Wazuh agent:

   ```bash
   sudo sed -i 's/<address>OLD_ADDRESS<\/address>/<address>192.168.1.103<\/address>/' /var/ossec/etc/ossec.conf
   sudo systemctl restart wazuh-agent
   ```

   Zabbix agent:

   ```bash
   sudo sed -i 's/^Server=OLD_ADDRESS/Server=192.168.1.101/' /etc/zabbix/zabbix_agent2.conf
   sudo systemctl restart zabbix-agent2
   ```

   Also update each server's own record of Node 2's address, since it changed: in the Zabbix frontend, edit the `homelab-node2` host's interface IP; in Wazuh, no manual update is needed since agents register with `any` as their IP and are identified by name, not address.

   Verification: `agent_control -l` on the Wazuh manager shows `homelab-node2` as `Active`; the Zabbix frontend's Hosts page shows a green availability badge for `homelab-node2`, and Latest data shows current timestamps.

5. Pin the Wazuh agent package version to prevent a routine system update from silently breaking manager compatibility again. A plain `apt upgrade` will otherwise pull whatever version the distribution's Wazuh repository currently considers `stable`, which may be newer than the manager supports (see Common Mistakes in Phase 3's doc for the underlying compatibility rule).

   ```bash
   sudo apt-mark hold wazuh-agent
   ```

6. Install Docker on Node 2 using the same method as the Wazuh VM.

   ```bash
   curl -fsSL https://get.docker.com -o get-docker.sh
   sudo sh get-docker.sh
   sudo usermod -aG docker rabih
   ```

   Log out and back in for the group change to apply, then confirm:

   ```bash
   docker run hello-world
   ```

7. Set up osTicket using a Docker image with active maintenance. Do not assume any osTicket image found through a search is currently working; verify against its actual Docker Hub or GitHub page how recently it was updated before committing to it. An older, unmaintained image describing itself as running "always fresh, bleeding edge" osTicket source can break outright: current osTicket source code can use PHP syntax the image's own stale, unmaintained PHP runtime does not support, producing a PHP parse error and a crash loop that has nothing to do with configuration.

   Create a project directory and compose file using `rinkp/osticket-dockerized`, an actively maintained image, paired with MariaDB.

   ```bash
   mkdir -p ~/osticket-docker
   cd ~/osticket-docker
   ```

   ```bash
   cat > docker-compose.yml << 'EOF'
   services:
     mariadb:
       image: mariadb:11
       container_name: osticket-mariadb
       restart: unless-stopped
       environment:
         MYSQL_ROOT_PASSWORD: rabihlab
         MYSQL_DATABASE: osticket
         MYSQL_USER: osticket
         MYSQL_PASSWORD: rabihlab
       volumes:
         - osticket_db_data:/var/lib/mysql

     osticket:
       image: rinkp/osticket-dockerized:latest
       container_name: osticket-app
       restart: unless-stopped
       depends_on:
         - mariadb
       ports:
         - "8081:80"
       environment:
         OST_SECRET_SALT: <32-character-random-string>
         OST_ADMIN_EMAIL: <admin-email-used-as-login>
         OST_ADMIN_PASSWD: <admin-password>
         OST_HELPDESK_URL: http://192.168.1.105:8081
         OST_DBHOST: mariadb:3306
         OST_DBNAME: osticket
         OST_DBUSER: osticket
         OST_DBPASS: rabihlab

   volumes:
     osticket_db_data:
   EOF
   ```

   `OST_SECRET_SALT` is mandatory; generate a genuine 32-character random string rather than a placeholder. `OST_ADMIN_EMAIL` doubles as the staff login username for this image, unlike some other osTicket images that separate the two.

8. Bring up the stack.

   ```bash
   docker compose up -d
   docker compose ps
   ```

   Give it under a minute for osTicket to connect to MariaDB and run its own database installation on first start. Early log lines showing repeated `mysqli_sql_exception: Connection refused` during this window are expected; osTicket is retrying before MariaDB finishes its own startup, not failing outright. Look for a line confirming successful installation before concluding otherwise.

   The container's Docker-reported health status may show `unhealthy` even when the application is fully functional; verify against the actual HTTP response rather than the health label alone.

   ```bash
   curl -I http://localhost:8081
   ```

   Expected: `HTTP/1.1 200 OK`.

9. Reach osTicket from a browser. Since Node 2 is now on VLAN 10, use the same SSH tunnel jump-host pattern as the other VMs, run this from your actual local machine's terminal, not from within any existing SSH session, since the target port is already bound locally on Node 2 itself.

   ```bash
   ssh -L 8081:192.168.1.105:8081 -J root@<proxmox-ip> rabih@192.168.1.105
   ```

   Browse to `http://localhost:8081` for the public support portal, and `http://localhost:8081/scp/login.php` for the staff panel, logging in with the `OST_ADMIN_EMAIL`/`OST_ADMIN_PASSWD` values set above. Change the password after first login if it was left at a shared or default value.

10. Commit phase documentation and tag the milestone.

    ```bash
    git add .
    git commit -m "Phase 4: Node 2 VLAN 10 migration and osTicket deployment"
    git tag v0.6.0-osticket
    git push
    git push --tags
    ```

## Verification

- Node 2 reachable at a `192.168.1.x` address, with working gateway and internet connectivity
- Zabbix and Wazuh both show Node 2 as active/healthy on its new address
- `docker compose ps` on Node 2 shows both `osticket-app` and `osticket-mariadb` up
- osTicket's public portal and staff panel are both reachable and functional at `http://192.168.1.105:8081`

## Common Mistakes

- Assuming a switch VLAN membership change alone forces a connected device to renew its DHCP lease. The physical link typically stays up throughout, so the device has no signal to trigger a renewal on its own; force it with a link flap or explicit DHCP client command.
- Trying to change a port's PVID before it is already a member of the destination VLAN, or trying to remove a port from a VLAN that still matches its PVID. Both are rejected by the switch; the correct order is add to new VLAN, change PVID, then remove from old VLAN.
- Leaving monitoring agent configs pointed at an old NAT workaround address after the underlying network topology changes. A working NAT-crossing configuration is not automatically wrong once it is no longer needed, but it is unnecessary complexity and a stale dependency; simplify it once a direct path exists.
- Letting a routine `apt upgrade` silently pull a newer package version that breaks a deliberately pinned compatibility requirement. Anything version-sensitive across two connected systems, like a Wazuh agent and manager, needs an explicit `apt-mark hold` once the matching version is installed, not just a one-time correct install.
- Picking a Docker image for a self-hosted app based on search result popularity or a well-written README alone, without checking how recently it was actually updated. An image that has not been rebuilt in years can still advertise "always fresh" upstream source, producing exactly this kind of runtime incompatibility once the underlying project's code has moved past what the stale image's own runtime supports.
- Running an SSH tunnel command from inside an existing SSH session instead of from the actual local machine. The port forward binds locally to wherever the command is actually typed; running it on the remote host itself tries to bind a port that is often already in use there, producing an address-in-use error that looks unrelated to the real mistake.

## Time Estimate

4-6 hours, split roughly evenly between the VLAN migration (including DHCP renewal troubleshooting) and osTicket's Docker setup (including the time spent moving off an image that turned out to be broken).
