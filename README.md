# homelab-docs

Two-node homelab build: infrastructure, monitoring, SIEM, ticketing, and IaC pipeline documentation.

## Architecture

**Node 1, Dell Precision Tower 3420**
Proxmox VE hypervisor. Hosts pfSense, Zabbix, and Wazuh as VMs.

**Node 2, HP EliteDesk 800 G5 Mini**
Ubuntu Server 26.04 LTS, bare metal, standalone (not clustered with Node 1). Hosts osTicket via Docker.

**Network**
Netgear GS305E managed switch, 802.1Q VLAN tagging on physical ports. One port stays untagged for switch management.

**IaC**

- `terraform/`: AWS resources (S3, SNS, IAM)
- `ansible/`: VM provisioning, agent deployment, OS hardening

**Event pipeline**
Zabbix alert → SNS notification + Lambda archives the relevant Wazuh log snapshot to S3.

**CI**
GitHub Actions lints markdown and runs `terraform fmt -check` / `terraform validate` on push.

**Deferred**
Kubernetes and Active Directory, planned as future additions, not part of this build.

## Repo Structure

```text
homelab-docs/
├── docs/           phase-by-phase build documentation
├── terraform/      AWS IaC
├── ansible/        provisioning and hardening playbooks
└── .github/workflows/  CI pipeline
```

## Phase Index

| Step | Description | Doc | Status |
|------|-------------|-----|--------|
| Repo Setup | Repo structure and CI pipeline | `docs/00-repo-setup.md` | Complete |
| Phase 0 | Network foundation and base OS install | `docs/phase0-foundation.md` | Complete |
| Phase 1 | pfSense deployment and VLAN 10 activation | `docs/phase1-pfsense-deployment.md` | Complete |
| Phase 2 | Zabbix deployment and node monitoring | `docs/phase2-zabbix-deployment.md` | Complete |
| Phase 3 | Wazuh deployment and node monitoring | `docs/phase3-wazuh-deployment.md` | Complete |

## Release Tags

Each phase milestone is marked with a git tag instead of a changelog file. See repo tags for history.
