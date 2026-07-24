# Phase 3: Wazuh Deployment and Node Monitoring

## Objective

Deploy Wazuh as a Docker-based SIEM stack (manager, indexer, dashboard) on Node 1, and add both physical nodes as monitored agents with live data flowing. This activates VLAN 10's second internal service and demonstrates a Docker-based deployment approach, distinct from Zabbix's native install.

## Prerequisites

- Phase 2 complete: Zabbix deployed, VLAN 10 access pattern (SSH tunnel through Proxmox) already established
- pfSense VM running before starting the Wazuh VM installer
- Proxmox host has a VLAN 10 interface already (`vmbr0.10`, added in Phase 2) for tunnel jump-host access

## Steps

1. Create the VM in Proxmox: name `wazuh`, single NIC on `vmbr0` with VLAN Tag `10`. VirtIO network model, Proxmox Firewall checkbox ON, Qemu Agent enabled. 4 cores, 8192 MiB RAM, 60 GB disk on SATA bus. Do not enable HA; this is a standalone Proxmox host with no cluster to fail over to, and the HA manager expects cluster resources that do not exist here.

2. Install Ubuntu Server 26.04 LTS. Hostname `homelab-wazuh`, user `rabih`, OpenSSH yes, skip Ubuntu Pro, skip Featured Snaps. Confirm the installer gets a DHCP address on VLAN 10 before proceeding; pfSense must be running first.

3. Update the system.

   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

4. Install Docker using the official convenience script rather than Ubuntu's bundled `docker.io` package, to get a current Docker Engine plus the Compose plugin that Wazuh's stack requires.

   ```bash
   curl -fsSL https://get.docker.com -o get-docker.sh
   sudo sh get-docker.sh
   sudo usermod -aG docker rabih
   ```

   Log out and back in for the group membership to take effect, then confirm:

   ```bash
   docker run hello-world
   ```

   **If this fails with an IPv6 connection error** (`dial tcp [2600:...]: connect: network is unreachable`), this network has no working IPv6 route out, and Docker's resolver is trying IPv6 first. Force Docker to prefer IPv4:

   ```bash
   sudo mkdir -p /etc/docker
   echo '{"ip-forward": true, "ipv6": false}' | sudo tee /etc/docker/daemon.json
   sudo systemctl restart docker
   ```

   Retry `docker run hello-world`; it should now pull and run successfully.

5. Check `vm.max_map_count`, required by the indexer's OpenSearch base for memory-mapped files.

   ```bash
   sysctl vm.max_map_count
   ```

   Wazuh's documented minimum is 262144. If lower, raise it; a modern kernel default may already exceed this.

6. Clone Wazuh's official single-node Docker stack, pinned to a specific tagged release rather than the default branch, which may point at in-development code.

   ```bash
   git clone https://github.com/wazuh/wazuh-docker.git -b v4.9.0
   cd wazuh-docker/single-node
   ```

7. Generate the indexer's TLS certificates, a one-time step using a separate compose file.

   ```bash
   docker compose -f generate-indexer-certs.yml run --rm generator
   ```

   The resulting `config/wazuh_indexer_ssl_certs/` directory is intentionally locked down (root-owned, mode 700); `sudo` is needed to inspect it, and the individual cert files are owned by a mix of your shell user and internal container UIDs. This is expected, not a misconfiguration.

8. Bring up the stack.

   ```bash
   docker compose up -d
   docker compose ps
   ```

   All three services (manager, indexer, dashboard) should show `Up`. Expect a brief startup race in the manager's logs: repeated "Failed to connect to backoff(elasticsearch(...))" and "OpenSearch Security not initialized" messages while the indexer finishes its own security plugin bootstrap. This resolves on its own within roughly a minute; look for "Connection to backoff(elasticsearch(...)) established" to confirm it settled.

9. Reach the dashboard from a browser. Since the VM is on VLAN 10, tunnel through Proxmox the same way as Zabbix, using a distinct local port to avoid conflicting with any existing tunnel.

   ```bash
   ssh -L 9443:192.168.1.103:443 -J root@<proxmox-ip> rabih@192.168.1.103
   ```

   Browse to `https://localhost:9443`. Accept the self-signed certificate warning. Log in with the stack's default credentials (`admin` / `SecretPassword`) and change the password immediately under the dashboard's security settings.

10. Install and configure the Wazuh agent on each physical node.

    Both nodes' own distributions (Debian 13 "trixie" for Node 1/Proxmox, Ubuntu 26.04 for Node 2) carry newer Wazuh agent packages by default through Wazuh's own `stable` APT repository than the pinned `v4.9.0` manager stack supports. **Wazuh requires the agent version to be equal to or lower than the manager version; a newer agent is rejected outright.** Install the exact matching version rather than the repo's default `latest`.

    Add Wazuh's repository on each node:

    ```bash
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
    sudo chmod 644 /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee -a /etc/apt/sources.list.d/wazuh.list
    sudo apt update
    ```

    Check available versions and install the one matching the manager exactly:

    ```bash
    apt-cache madison wazuh-agent
    sudo apt install wazuh-agent=4.9.0-1 -y
    ```

11. Register each agent from inside the manager container before configuring the agent side.

    ```bash
    docker exec -it single-node-wazuh.manager-1 /var/ossec/bin/manage_agents
    ```

    Choose **A** to add. Use the node's hostname (`homelab-node1`, `homelab-node2`) as the agent name, and `any` for the IP address rather than a specific address; traffic from either node crosses pfSense's NAT boundary and will not arrive from the address it originated at. Choose **E** to extract the newly created agent's key; copy the full base64 string exactly.

12. Configure each agent to point at the manager, and import its key.

    Traffic from a physical node to the Wazuh VM must cross pfSense, but the physical nodes' default gateway is the home router, not pfSense; the home router has no route to VLAN 10 and silently drops the packet before it ever reaches pfSense. A NAT port forward on pfSense's WAN interface solves this without touching either node's own routing table (see Common Mistakes for the full diagnosis path).

    Point the agent at pfSense's WAN address, not the Wazuh VM's actual VLAN 10 address:

    ```bash
    sudo sed -i 's/<address>MANAGER_IP<\/address>/<address><pfsense-wan-ip><\/address>/' /var/ossec/etc/ossec.conf
    ```

    Import the key:

    ```bash
    sudo /var/ossec/bin/manage_agents
    ```

    Choose **I**, paste the key extracted in the previous step, confirm, quit, then start the agent:

    ```bash
    sudo systemctl enable --now wazuh-agent
    ```

13. On pfSense, add a NAT port forward so traffic hitting the WAN address on the agent ports reaches the Wazuh VM. Firewall, NAT, Port Forward, Add:

    - Interface: WAN
    - Protocol: TCP
    - Destination: WAN address
    - Destination port range: 1514 to 1515
    - Redirect target IP: the Wazuh VM's address
    - Redirect target port: 1514

    Leave the automatic associated filter rule checkbox checked; it creates the matching WAN pass rule alongside the NAT redirect. This single rule serves both physical nodes, since it is not restricted by source address.

14. Verify each agent shows as connected from the manager's side, not just that the raw TCP port opens.

    ```bash
    docker exec -it single-node-wazuh.manager-1 /var/ossec/bin/agent_control -l
    ```

    Expect `Active` for both `homelab-node1` and `homelab-node2`. If an agent instead shows `Never connected` or `Unknown` despite the agent's own log showing a successful connection, check the manager's own log for `wazuh-db` errors (see Common Mistakes); this points to internal state corruption on the manager side, not a network or agent problem.

15. Commit phase documentation and tag the milestone.

    ```bash
    git add .
    git commit -m "Phase 3: Wazuh deployment and node monitoring"
    git tag v0.5.0-wazuh
    git push
    git push --tags
    ```

## Verification

- Wazuh dashboard reachable at `https://192.168.1.103` (via SSH tunnel) and showing real alert data on the Overview page
- Manager, indexer, and dashboard containers all show `Up` via `docker compose ps`
- Both `homelab-node1` and `homelab-node2` show `Active` via `agent_control -l`, with FIM and other event data visible in the dashboard filtered by agent

## Common Mistakes

- Assuming Docker's registry pull failure over IPv6 means Docker itself is broken. If this network has no real IPv6 route out, Docker's resolver still tries IPv6 first by default. Confirm with `curl -6` versus `curl -4` against the registry before concluding anything is misconfigured, then force IPv4 preference in `daemon.json`.
- Letting the agent install pull whatever version a distribution's Wazuh `stable` repo currently offers. Wazuh strictly requires agent version to be equal to or lower than the manager version; installing the repo's default `latest` against an older pinned manager stack fails enrollment with an explicit version error. Check `apt-cache madison wazuh-agent` and pin the exact matching version.
- Assuming a physical node's traffic to the Wazuh VM will reach pfSense automatically the way a VM on pfSense's own LAN side does. A physical node's default gateway is the home router, which has no route to VLAN 10 and drops the packet silently; this shows as a connection timeout, not a refusal, and produces no log entry anywhere on pfSense, since the traffic never arrives there. Confirm with `ip route get <target>` on the node to see which gateway it actually uses before assuming a firewall rule alone will fix it.
- Registering an agent, then purging and reinstalling its package, then re-importing the same key onto the same agent ID. This can leave the manager's internal database in a state where new agents repeatedly fail an internal group-assignment step (`wazuh-db: ERROR: There was an error assigning the groups to agent`) regardless of which agent ID is used, and the symptom survives a plain manager container restart. Recognize this as corrupted internal state, not a registration mistake, and resolve it by tearing down the stack's data volumes entirely (`docker compose down -v`) and rebuilding fresh, the same principle used for the Zabbix schema re-import issue.
- Confusing Proxmox's own address with pfSense's WAN address when configuring an agent's manager pointer. They are different hosts on the same home network range; sending agent traffic to Proxmox's address instead of pfSense's produces a fast, active "connection refused" rather than a timeout, since Proxmox has nothing listening on that port, which can look superficially like a firewall rejection.

## Time Estimate

5-7 hours for a clean run given the version-pinning lesson is already known; expect the higher end if agent version mismatches or manager state corruption need to be diagnosed from scratch, as they did in this build.
