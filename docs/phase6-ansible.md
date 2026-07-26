# Phase 6: Ansible Configuration Management

## Objective

Codify OS hardening, Docker installation, and Zabbix/Wazuh agent configuration as repeatable Ansible playbooks across all four hosts (Node 1, Node 2, the Zabbix VM, the Wazuh VM). End state: any of this configuration can be reapplied idempotently, drift is detected and corrected automatically, and the manual steps from Phases 2 through 4 are now expressed as code rather than only existing as one-time terminal history.

## Prerequisites

- Phases 2 through 5 complete: Zabbix, Wazuh, osTicket, and the Terraform AWS foundation all in place
- WSL (Windows Subsystem for Linux) installed, since Ansible requires a Linux or macOS control node and does not run natively on Windows
- SSH key-based authentication set up to all four hosts, replacing password auth for Ansible's automation

## Steps

1. Install WSL.

   ```powershell
   wsl --install
   ```

   This installs WSL2 with Ubuntu as the default distribution. Create a Unix user account when prompted, matching the existing `rabih` convention.

2. Install Ansible inside WSL.

   ```bash
   sudo apt update
   sudo apt install ansible -y
   ```

   Verification: `ansible --version` reports a working install. WSL's filesystem mount at `/mnt/c/Users/<username>/` gives direct access to the actual Windows-side repo clone, no separate copy needed.

3. Generate an SSH key pair inside WSL and copy it to all four hosts, replacing password-based SSH access with key-based access. This closes out a hardening item flagged since Phase 2.

   ```bash
   ssh-keygen -t ed25519 -C "ansible-homelab"
   ssh-copy-id root@10.0.0.181
   ssh-copy-id -o ProxyJump=root@10.0.0.181 rabih@192.168.1.101
   ssh-copy-id -o ProxyJump=root@10.0.0.181 rabih@192.168.1.103
   ssh-copy-id -o ProxyJump=root@10.0.0.181 rabih@192.168.1.105
   ```

   Verification: `ssh <host> "hostname"` succeeds for all four hosts with no password prompt.

4. Set up passwordless sudo for the `rabih` user on the three non-root hosts (Node 2, Zabbix VM, Wazuh VM). This is a one-time manual bootstrapping step, done once with an interactive password, specifically so all further Ansible runs needing privilege escalation do not require a password at all.

   ```bash
   ssh -t -o ProxyJump=root@10.0.0.181 rabih@<host-ip> "echo 'rabih ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/rabih-ansible && sudo chmod 440 /etc/sudoers.d/rabih-ansible"
   ```

   This step turned out to be necessary rather than optional: Ubuntu 26.04 uses a different sudo implementation with different interactive prompt wording than the classic `[sudo] password for <user>:` text. Ansible's privilege escalation detection could not recognize the different prompt and consistently timed out waiting for it, even with a correct password supplied via `-K`. Rather than fighting prompt-matching across differing sudo implementations, passwordless sudo for the automation user sidesteps the problem entirely and is standard practice for automation accounts.

5. Set up the Ansible inventory at `ansible/inventory/hosts.yml`, defining all four hosts, their connection details, and logical groups (`proxmox`, `physical_nodes`, `vms`, `monitored_hosts`, `docker_hosts`). VLAN 10 hosts need `ansible_ssh_common_args: '-o ProxyJump=root@10.0.0.181'` set per-host, since Ansible's own SSH connections need the same jump-host path used manually throughout this project. Host-specific variables (`zabbix_agent_server`, `wazuh_agent_server`) are also defined here, since Node 1 and Node 2 sit in different network positions relative to their monitoring servers and need different addresses (see Common Mistakes).

6. Set `ansible.cfg` at the repo root with a default inventory path. WSL reports any path under `/mnt/c/` as world-writable regardless of the file's actual Windows permissions, and Ansible refuses to auto-load a config file from a location it considers world-writable, as a safety measure against tampering. Point at the config explicitly via an environment variable instead of relying on auto-discovery:

   ```bash
   export ANSIBLE_CONFIG=/mnt/c/Users/<username>/homelab-docs/ansible.cfg
   echo 'export ANSIBLE_CONFIG=/mnt/c/Users/<username>/homelab-docs/ansible.cfg' >> ~/.bashrc
   ```

   Verification:

   ```bash
   ansible all -m ping
   ```

   All four hosts report `"ping": "pong"`.

7. Run the hardening playbook (`ansible/playbooks/hardening.yml`): installs and enables unattended security upgrades, installs and enables UFW with SSH explicitly allowed before the firewall itself is enabled, in that specific order, to avoid any risk of a lockout.

   ```bash
   ansible-playbook ansible/playbooks/hardening.yml --check --diff
   ansible-playbook ansible/playbooks/hardening.yml
   ```

   Verification: `ansible all -m ping` afterward still shows all four hosts reachable, confirming the firewall changes did not break SSH access anywhere.

8. Run the Docker playbook (`ansible/playbooks/docker.yml`) against `docker_hosts` (Node 2 and the Wazuh VM): checks whether Docker is already installed before attempting the install script, adds the user to the `docker` group, and enforces the IPv6-disabled daemon configuration discovered necessary in Phase 3.

   ```bash
   ansible-playbook ansible/playbooks/docker.yml
   ```

   Verification: running the playbook a second time immediately after shows `changed=0` for both hosts, confirming true idempotency. `docker ps` on both hosts still shows all containers running after any restart triggered by a daemon config change.

9. Run the Zabbix agent playbook (`ansible/playbooks/zabbix_agent.yml`) against `monitored_hosts` (Node 1 and Node 2): ensures the package is installed, enforces the correct `Server`, `ServerActive`, and `Hostname` settings per host, and opens the UFW rule the agent needs to accept inbound polling from the Zabbix server.

   ```bash
   ansible-playbook ansible/playbooks/zabbix_agent.yml --check --diff
   ansible-playbook ansible/playbooks/zabbix_agent.yml
   ```

   Verification: both hosts show a green availability badge in the Zabbix frontend's Hosts page after the next poll cycle.

10. Run the Wazuh agent playbook (`ansible/playbooks/wazuh_agent.yml`) against the same `monitored_hosts` group: ensures the repository, GPG key, and pinned package version are correctly in place, holds the package to prevent the version drift discovered in Phase 4, and sets the correct manager address per host.

    ```bash
    ansible-playbook ansible/playbooks/wazuh_agent.yml --check --diff
    ansible-playbook ansible/playbooks/wazuh_agent.yml
    ```

    Verification:

    ```bash
    ansible homelab-wazuh -a "docker exec single-node-wazuh.manager-1 /var/ossec/bin/agent_control -l"
    ```

    Both `homelab-node1` and `homelab-node2` show `Active`.

11. Commit phase documentation and tag the milestone.

    ```bash
    git add .
    git commit -m "Phase 6: Ansible configuration management"
    git tag v0.8.0-ansible
    git push
    git push --tags
    ```

## Verification

- `ansible all -m ping` reports success for all four hosts
- Re-running any playbook shows `changed=0` across the board, confirming idempotency
- Zabbix frontend shows both physical nodes green; Wazuh manager shows both physical node agents `Active`
- SSH to all four hosts requires no password; sudo on the three non-root hosts requires no password for the `rabih` automation user

## Common Mistakes

- Assuming a single address works for both physical nodes when configuring a monitoring agent's manager/server setting. Node 1 and Node 2 sit in genuinely different network positions: Node 1 remains on the home network and its traffic to either monitoring VM crosses pfSense's NAT boundary, needing the NAT-translated pfSense WAN address, while Node 2 migrated to VLAN 10 in Phase 4 and needs the real, direct address instead. Applying one global value to both breaks one of them, sometimes silently, since the wrong address for Node 2 would have quietly forced it back onto an unnecessary NAT workaround rather than failing outright.
- Enabling a firewall as part of a hardening pass without accounting for every legitimate inbound service a host actually needs, not just SSH. Locking down SSH is the obvious first move, but any other service expecting inbound connections, in this case the Zabbix agent's port 10050, needs its own explicit allow rule once a default-deny firewall is active, or that service silently stops working with no indication the firewall is the cause.
- Fixing a UFW rule to allow a monitoring server's traffic and assuming that resolves connectivity on its own. The monitoring agent's own application-level allowlist (Zabbix's `Server=` setting) is a separate, independent check from the OS firewall; both need to agree on the same expected source address, particularly when NAT translation is involved, since the address arriving at each layer may differ from the address the agent was told to expect.
- Fighting to match an interactive sudo prompt's exact wording across hosts running different sudo implementations, rather than removing the need for prompt-matching entirely. Newer Ubuntu releases can ship a different sudo implementation with different default prompt text than older systems; forcing a custom prompt string via `become_flags` risks breaking the systems that already worked correctly with the default prompt. Passwordless sudo for a dedicated automation account is the more robust fix.
- Comparing a templated config file's content byte-for-byte without matching the exact formatting already on disk. A file that is functionally identical but formatted differently (multi-line JSON versus single-line, for example) will register as changed on every single run under Ansible's `copy` module, since it performs an exact content comparison, not a semantic one, defeating idempotency for no functional reason.

## Time Estimate

5-7 hours, including the one-time WSL and SSH key setup, given how much of the real time went into diagnosing the sudo prompt mismatch and the two rounds of NAT-related firewall and agent config fixes.
