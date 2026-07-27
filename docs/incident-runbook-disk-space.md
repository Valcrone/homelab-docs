# Incident Runbook: Service Unreachable After Reboot (Disk Space Exhaustion)

## Applies To

Any Docker-hosted service in this homelab (Wazuh, osTicket) that becomes unreachable following a VM reboot, restart, or extended downtime, where the underlying host has not been checked recently for disk usage.

## Symptom

A service's web interface fails to load, times out, or returns a "not ready" message, despite the VM itself being reachable via SSH and `ping`. `docker compose ps` shows one or more containers in a `Restarting` state while others in the same stack remain `Up`.

## Real Incident Reference

This runbook is based on a genuine incident: the Wazuh dashboard returned "server is not ready yet" after a routine VM reboot. The `wazuh.indexer` container was crash-looping while `wazuh.manager` and `wazuh.dashboard` stayed up. Root cause: the VM's root filesystem was completely full (100% used), and the indexer's OpenSearch base needs to write to disk on startup, so it could never complete initialization. See osTicket #771447 for the full worked ticket.

## Triage Steps

1. **Confirm the VM itself is reachable**, not just the service.

   ```bash
   ping -c 3 <vm-ip>
   ssh <user>@<vm-ip> "hostname"
   ```

   If the VM itself is unreachable, this is a different class of problem (network, VM power state), not what this runbook covers.

2. **Check container status** for the affected stack.

   ```bash
   docker compose -f <path-to-compose-file> ps
   ```

   Look specifically for any container in a `Restarting` state while its siblings show `Up`. A single container crash-looping while others in the same stack stay healthy is a strong signal of a resource problem (disk, memory) specific to that one component, not a broader stack failure.

3. **Check disk usage on the host.**

   ```bash
   df -h
   ```

   A root filesystem at or near 100% used is the most common cause of this exact symptom pattern for any container that needs to write to disk on startup (databases, search indices, log-heavy services).

4. **If disk is full, check whether the LVM volume group has unallocated space** before assuming anything needs to be deleted.

   ```bash
   sudo vgs
   sudo lvs
   ```

   If `VFree` on the volume group is greater than zero, the logical volume was simply never extended to use the full virtual disk originally provisioned, no data loss risk, this is a safe, purely additive fix.

## Resolution: Extending Disk Space (No Data Loss)

Only follow this path if step 4 above confirmed free space exists in the volume group.

```bash
sudo lvextend -l +100%FREE /dev/<volume-group>/<logical-volume>
sudo resize2fs /dev/mapper/<volume-group>-<logical-volume>
```

Verify:

```bash
df -h /
```

Confirm the filesystem now shows meaningfully more total size and available space than before.

## Resolution: Restarting the Crash-Looping Container

Once disk space is confirmed available, the crash-looping container should recover on its own within a minute or two as it retries its startup sequence. If it does not:

```bash
docker compose -f <path-to-compose-file> restart <service-name>
```

## Verification

1. `docker compose ps` shows all containers in the stack as `Up`, none `Restarting`
2. The service's own web interface loads correctly
3. Any downstream dependents (for example, monitored agents reporting into this service) show as active/healthy again

## If This Is Not the Cause

If disk usage is not the issue (plenty of free space, but a container still crash-loops), check the container's own logs before assuming anything else:

```bash
docker logs <container-name> --tail 50
```

Look for explicit error messages rather than assuming based on symptoms alone; a crash loop can also result from a corrupted data volume, a bad configuration change, or an incompatible version mismatch after an image update.

## Prevention

This class of incident is best caught proactively rather than discovered via an outage. Recommended: add disk usage monitoring and alerting (for example, a Zabbix trigger on root filesystem utilization) for every VM host, not just hosts already being monitored for other reasons. At the time of this incident, the Wazuh VM itself had no active Zabbix monitoring, only Docker/SSH-based management, which is part of why the condition went unnoticed until it caused a real outage. See osTicket #451357 (Monitoring Configuration Request) for the follow-up tracking this gap.
