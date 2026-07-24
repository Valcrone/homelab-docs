# Phase 2: Zabbix Deployment and Node Monitoring

## Objective

Deploy Zabbix as a monitoring VM on Node 1 (Proxmox), get its frontend reachable and functional, and add both physical nodes (Node 1 and Node 2) as monitored hosts with live data flowing. This activates VLAN 10's first real internal service beyond pfSense itself.

## Prerequisites

- Phase 1 complete: pfSense deployed, VLAN 10 routed and reachable
- Ubuntu Server 24.04.4 LTS ISO (used instead of 26.04; see Common Mistakes)
- pfSense VM running before starting the Zabbix VM installer, since pfSense's LAN interface is what hands out DHCP on VLAN 10

## Steps

1. Create the VM in Proxmox: name `zabbix`, single NIC on `vmbr0` with VLAN Tag `10` set directly on the NIC (no untagged WAN-style second NIC needed, unlike pfSense). VirtIO network model, Proxmox's per-VM Firewall checkbox left ON (unlike pfSense, since this VM is not itself a firewall). 2 cores, 2048 MiB RAM, 32 GB disk on SATA bus, Qemu Agent enabled.

2. Start the pfSense VM first, then start the Zabbix VM and boot its installer. Confirm the installer gets a DHCP address on VLAN 10 (expect `192.168.1.101`) before proceeding. If networking autoconfiguration fails, confirm pfSense is actually running; nothing on VLAN 10 can reach DHCP without it.

3. Install Ubuntu Server 24.04.4 LTS. Set hostname `homelab-zabbix`, user `rabih`, OpenSSH yes, skip Ubuntu Pro, skip Featured Snaps.

   **Do not use Ubuntu 26.04 for this VM.** Zabbix's official APT repository has no build for Ubuntu 26.04 ("resolute") as of this build; only up to 24.04 ("noble"). See Common Mistakes for the full failure this caused.

4. Update the system and install PostgreSQL.

   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo apt install postgresql -y
   ```

   Verification: `systemctl status postgresql` shows `active (exited)`.

5. Create the Zabbix database user and database.

   ```bash
   sudo -u postgres createuser --pwprompt zabbix
   sudo -u postgres createdb -O zabbix zabbix
   ```

   Set the password to `zabbix123` when prompted (internal-only credential, never typed by a human after initial setup).

   Verification: `sudo -u postgres psql -c "\du"` lists the `zabbix` role; `sudo -u postgres psql -c "\l"` lists the `zabbix` database owned by `zabbix`.

6. Add Zabbix's official repository, matching the OS codename exactly.

   ```bash
   wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb
   sudo dpkg -i zabbix-release_latest_7.0+ubuntu24.04_all.deb
   sudo apt update
   ```

7. Install the Zabbix server, frontend, and agent components.

   ```bash
   sudo apt install zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts zabbix-agent -y
   ```

   Verification: `dpkg -l | grep zabbix` shows 6 lines (5 components plus the `zabbix-release` package itself).

8. Import the PostgreSQL schema. Redirect output to a log file rather than the terminal; the script is large.

   ```bash
   zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | sudo -u zabbix psql zabbix > /tmp/schema_import.log 2>&1
   ```

   Verify with:

   ```bash
   grep -i error /tmp/schema_import.log
   ```

   Success is no output at all. If this is a repeat attempt against a database that already has data in it (for example after an earlier partial run), you will instead see a long cascade of `current transaction is aborted, commands ignored until end of transaction block` lines. This cascade is not the real error; it is Postgres refusing all further statements after one earlier failure inside the same transaction. Filter it out to find the actual cause:

   ```bash
   grep -i error /tmp/schema_import.log | grep -v "current transaction is aborted"
   ```

   If the real error is a duplicate key violation on tables like `images` or `role`, the database already has seed data in it from an earlier attempt. Drop and recreate it, then import again against the empty database.

   ```bash
   sudo -u postgres psql -c "DROP DATABASE zabbix;"
   sudo -u postgres psql -c "CREATE DATABASE zabbix OWNER zabbix;"
   ```

9. Configure the Zabbix server's database connection.

   ```bash
   sudo nano /etc/zabbix/zabbix_server.conf
   ```

   Uncomment and set:

   ```text
   DBHost=localhost
   DBName=zabbix
   DBUser=zabbix
   DBPassword=zabbix123
   ```

   Verification:

   ```bash
   sudo grep -n -E "^DBHost|^DBName|^DBUser|^DBPassword" /etc/zabbix/zabbix_server.conf
   ```

   All four should show with no leading `#`.

10. Configure Nginx for the Zabbix frontend. Edit `/etc/zabbix/nginx.conf` and uncomment the `listen` and `server_name` lines:

    ```text
    listen          8080;
    server_name     192.168.1.101;
    ```

    Port 8080 is used deliberately, kept separate from port 80 for clarity on a single-purpose VM.

11. Confirm the Nginx config is actually being loaded. Debian and Ubuntu's Nginx only reads files included via `/etc/nginx/conf.d/*.conf` or `/etc/nginx/sites-enabled/*`; `/etc/zabbix/nginx.conf` sits outside both by default.

    ```bash
    ls -la /etc/nginx/conf.d/zabbix.conf
    ```

    The `zabbix-nginx-conf` package creates this as a symlink automatically, but it may point at a file that does not exist (`/etc/nginx/zabbix.conf`, not the file you edited). If so, replace it:

    ```bash
    sudo rm /etc/nginx/conf.d/zabbix.conf
    sudo ln -s /etc/zabbix/nginx.conf /etc/nginx/conf.d/zabbix.conf
    sudo nginx -t
    sudo systemctl reload nginx
    ```

    Verification: `sudo ss -tlnp | grep nginx` shows a `LISTEN` entry on port 8080.

12. Set PHP's timezone, required by the Zabbix frontend. Find the FPM php.ini's `date.timezone` line (commented out by default, prefixed with `;`, not `date`):

    ```bash
    sudo grep -rn "date.timezone" /etc/php/8.3/
    ```

    Edit the FPM version specifically (not the CLI one):

    ```bash
    sudo sed -i 's/^;date.timezone =$/date.timezone = America\/Chicago/' /etc/php/8.3/fpm/php.ini
    ```

    Verification: `sudo sed -n '989p' /etc/php/8.3/fpm/php.ini` shows the set line with no leading `;` (line number may vary by PHP point release; find it first with the grep above).

13. Install the PHP PostgreSQL extension. The `zabbix-frontend-php` package can resolve to MySQL's PHP driver instead of PostgreSQL's depending on what else is already installed; check before assuming it is correct.

    ```bash
    php -m | grep -i pgsql
    ```

    If this returns nothing, install the extension and restart PHP-FPM:

    ```bash
    sudo apt install php8.3-pgsql -y
    sudo systemctl restart php8.3-fpm
    ```

14. Restart PHP-FPM and start/enable the Zabbix server and Nginx.

    ```bash
    sudo systemctl restart php8.3-fpm
    sudo systemctl enable --now zabbix-server nginx
    ```

    Verification:

    ```bash
    systemctl is-active php8.3-fpm zabbix-server nginx
    ```

    All three should print `active`.

15. Confirm the frontend responds locally on the VM before trying to reach it from a browser elsewhere.

    ```bash
    curl -I http://localhost:8080
    ```

    Expected: `HTTP/1.1 302 Found` redirecting to `setup.php`.

16. Reach the frontend from a browser. Since the Zabbix VM sits on VLAN 10 and the admin PC does not stay connected to that VLAN, use an SSH tunnel through the Proxmox host as a jump host instead of physically reconnecting to a VLAN 10 switch port.

    This requires Proxmox itself to have a route to VLAN 10, which it does not have by default; only tagged VM NICs did. Add a VLAN sub-interface on the Proxmox host: System, Network, Create, Linux VLAN, name `vmbr0.10`, VLAN Tag `10`, address `192.168.1.10/24`, no gateway. Apply Configuration.

    Verification from the Proxmox shell: `ping -c 3 192.168.1.101` shows 0% packet loss.

    From the admin PC:

    ```bash
    ssh -L 8080:192.168.1.101:8080 -J root@<proxmox-ip> rabih@192.168.1.101
    ```

    Leave that session open, then browse to `http://localhost:8080`.

17. Complete the frontend's first-run setup wizard: language, pre-requisites check (all should show OK once step 13 is done), database connection (type PostgreSQL, host `localhost`, port `0` for default, database `zabbix`, schema `public`, user `zabbix`, password `zabbix123`, plain text credential storage, no TLS needed for a local socket connection), Zabbix server name and default timezone (`America/Chicago`), then Install.

18. Log in with the default account (`Admin` / `zabbix`) and immediately change the password under Users, Users, Admin, since this is a widely known default.

19. Install and configure the Zabbix agent on each physical node to be monitored.

    On Node 2 (Ubuntu 26.04, HP), Ubuntu's own repository already carries a compatible `zabbix-agent2` package; no need to add Zabbix's official repo for the agent alone.

    ```bash
    sudo apt install zabbix-agent2 -y
    ```

    On Node 1 (Debian 13 "trixie", the Proxmox host OS itself), Debian's own repository also carries a compatible version.

    ```bash
    apt install zabbix-agent2 -y
    ```

20. Configure each agent's `/etc/zabbix/zabbix_agent2.conf`, setting a unique `Hostname` per node and pointing `Server`/`ServerActive` at the Zabbix server.

    Traffic from the Zabbix VM (VLAN 10) to either physical node (home network) passes through pfSense, which applies its default outbound NAT rule to that traffic since the physical nodes are not on the network segment pfSense treats as VLAN 10's internal side. This rewrites the source address to pfSense's WAN IP. As a result, each agent must allow connections from pfSense's WAN address, not the Zabbix server's actual VLAN 10 address.

    ```bash
    sudo sed -i 's/^Server=127.0.0.1/Server=<pfsense-wan-ip>/' /etc/zabbix/zabbix_agent2.conf
    sudo sed -i 's/^ServerActive=127.0.0.1/ServerActive=<pfsense-wan-ip>/' /etc/zabbix/zabbix_agent2.conf
    sudo sed -i 's/^Hostname=Zabbix server/Hostname=<node-hostname>/' /etc/zabbix/zabbix_agent2.conf
    ```

    Restart the agent so the change actually takes effect. If the package installer already started the agent once before this edit, `systemctl enable --now` alone will not reload the running process's config; it only affects whether the service starts on future boots. Use `restart` explicitly.

    ```bash
    sudo systemctl restart zabbix-agent2
    ```

    Verification: `sudo ss -tlnp | grep zabbix` shows the agent listening on port 10050. Check `/var/log/zabbix/zabbix_agent2.log` for connection rejections; a fresh restart should stop them.

21. In the Zabbix frontend, create a host entry per physical node under Data collection, Hosts. Host name must exactly match the agent's configured `Hostname`. Set the interface IP to the node's real address (not pfSense's WAN address; that rewrite only affects what the agent sees as the incoming source, not what the server dials as its destination). Link the "Linux by Zabbix agent" template at creation time so polling has something to check immediately.

    Verification: the host's availability badge turns green within a minute or two of the agent restart, and Monitoring, Latest data shows populated values (CPU, memory, filesystem, network interfaces) when filtered to that host.

22. Commit phase documentation and tag the milestone.

    ```bash
    git add .
    git commit -m "Phase 2: Zabbix deployment and node monitoring"
    git tag v0.4.0-zabbix
    git push
    git push --tags
    ```

## Verification

- Zabbix frontend reachable at `http://192.168.1.101:8080` (via SSH tunnel from off-VLAN-10 devices)
- Zabbix server, PostgreSQL, Nginx, and PHP-FPM all show `active` status
- Zabbix VM itself, plus `homelab-node1` and `homelab-node2`, all show green availability and populated Latest data

## Common Mistakes

- Installing Ubuntu 26.04 for the Zabbix VM. Zabbix's official repository has no build for a release this new yet; the dependency resolution fails with a long list of unsatisfied packages. Use one LTS release behind on servers running vendor-packaged software, a normal and defensible practice, not an inconsistency.
- Re-running the schema import against a database that already has seed data in it. Produces a wall of "current transaction is aborted" messages that obscure the one real error earlier in the same transaction; filter those out, or better, drop and recreate the database before a repeat import.
- Assuming `/etc/zabbix/nginx.conf` takes effect just because it exists. Nginx only reads what is included via `conf.d/` or `sites-enabled/`; the package's own symlink can point at a file that was never created.
- Trusting the "PHP databases support" line on the frontend's pre-requisites page without checking it matches your actual database. It will silently show MySQL support only if the wrong PHP driver got installed, and PostgreSQL connection setup will fail on the next screen.
- Assuming a NAT-crossing agent connection will be seen by the target as coming from the real server IP. If traffic crosses a router applying outbound NAT, the agent must allow the router's translated address, not the server's own address.
- Believing `systemctl enable --now` reloads a config for a service that is already running. It only affects future boots if the service is already active; use `restart` after any config change to a running service.

## Time Estimate

3-4 hours for a clean run on both VM setup and the two-node agent rollout, longer if the OS version mismatch forces a rebuild like it did here.
