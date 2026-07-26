# Phase 7: Event Pipeline (Zabbix to SNS to Lambda to S3)

## Objective

Wire Zabbix, AWS SNS, Lambda, and S3 together into a working event pipeline: a real Zabbix trigger fires a custom alert script, which gathers a live Wazuh snapshot and publishes a combined payload to SNS; a Lambda function subscribed to that topic archives the payload to S3. End state: an actual Zabbix problem event, with no manual intervention, results in a JSON object landing in S3 within seconds.

## Prerequisites

- Phase 5 complete: S3 bucket, SNS topic, and base IAM role already provisioned via Terraform
- Phase 6 complete: Ansible inventory and SSH key access to all hosts in place
- AWS credentials for the `terraform-homelab` user configured locally

## Architecture Decision

Lambda cannot reach into the home network directly; there is no VPN or direct connection between AWS and the homelab in this project's scope. Rather than have Lambda attempt to fetch a Wazuh snapshot itself, the local alert script gathers the snapshot at alert time (while it has homelab network access) and includes it directly in the SNS payload. Lambda's job is reduced to archiving whatever payload it receives, no outbound reach into the private network required.

## Steps

1. Add the Lambda function, its SNS subscription, and a dedicated, tightly-scoped IAM user to `terraform/main.tf`. The new IAM user (`zabbix-sns-publisher`) is deliberately scoped to exactly one action (`sns:Publish`) on exactly one resource (this topic's ARN), a real least-privilege example rather than reusing the broader `terraform-homelab` credentials for this purpose.

2. Add the `archive` provider to `terraform/provider.tf`, used to automatically zip the Lambda's Python source from `terraform/lambda/`.

3. Write the Lambda function (`terraform/lambda/lambda_function.py`): receives an SNS event, writes the message body to S3 under a date-organized key (`zabbix-alerts/YYYY/MM/DD/HHMMSS-<message-id>.json`).

4. Run `terraform init` (picks up the new provider) and `terraform apply`.

   **If this fails with an IAM `AccessDenied` error on `lambda:CreateFunction`** even though the correct managed policy (`AWSLambda_FullAccess`) is confirmed attached via `aws iam list-attached-user-policies`, this is IAM policy propagation delay, not a real permissions problem. Confirm by testing the exact same action directly via `aws lambda create-function` outside Terraform; if that succeeds, simply retry `terraform apply`, it will resume from where it left off rather than repeating already-created resources.

5. Retrieve the new user's credentials via Terraform outputs rather than reading them from state directly.

   ```bash
   terraform output sns_topic_arn
   terraform output s3_bucket_name
   terraform output zabbix_publisher_access_key_id
   terraform output -raw zabbix_publisher_secret_access_key
   ```

   Treat the secret key as sensitive: copy it directly from the terminal into wherever it needs to go, never paste it into a chat, ticket, or any other logged channel. If it is ever exposed that way regardless, treat it as compromised and rotate it (`terraform taint aws_iam_access_key.zabbix_publisher_key` followed by `apply`).

6. Install the AWS CLI on the Zabbix VM (Ubuntu's own repo did not carry an `awscli` package on this release; use AWS's official installer instead) and configure it with the scoped publisher credentials via `aws configure`.

   Verification: `aws sts get-caller-identity` confirms the `zabbix-sns-publisher` identity; `aws sns publish` to the topic succeeds; `aws s3 ls` fails with `AccessDenied`, confirming the scoping is genuinely enforced, not just configured.

7. Set up SSH key trust from the Zabbix VM to the Wazuh VM, generating a fresh key pair dedicated to this automation path (not reusing the Ansible control node's key).

8. Write the alert script (`/usr/lib/zabbix/alertscripts/zabbix_sns_alert.sh` on the Zabbix VM), which:
   - Accepts Zabbix's standard three alert-script arguments (recipient, subject, message)
   - Fetches the last few lines of Wazuh's live alerts log via SSH through Proxmox as a jump host
   - Falls back to a plain "unavailable" note rather than failing outright if that SSH step fails, so a Zabbix alert still reaches SNS even without the enrichment
   - Builds the combined JSON payload with `jq` (never manual string concatenation, which breaks on special characters in log content)
   - Publishes to SNS via the AWS CLI

9. Set up credentials and SSH access for the actual user Zabbix's server process runs as (`zabbix`, not the interactive `rabih` login), since that is the identity that executes the alert script for real. This means a separate `~/.aws/credentials` under `/var/lib/zabbix/.aws/` and a copy of the SSH key pair under `/var/lib/zabbix/.ssh/`, with ownership and permissions corrected accordingly.

   Verification: `sudo -u zabbix /usr/lib/zabbix/alertscripts/zabbix_sns_alert.sh "test" "subject" "message"` succeeds and returns a real SNS `MessageId`.

10. Create the Zabbix media type (Alerts, Media types, Create media type): type Script, pointing at the alert script, with `{ALERT.SENDTO}`, `{ALERT.SUBJECT}`, `{ALERT.MESSAGE}` as script parameters.

    **A media type is not usable without a message template**, even if the script itself works correctly when run manually. Add one under the media type's Message templates tab (Problem type, with a Subject and Message using standard Zabbix macros like `{EVENT.NAME}`, `{HOST.NAME}`, `{EVENT.SEVERITY}`). Skipping this produces a silent, unhelpful failure logged only as "No message defined for media type," with no indication that the script or credentials were ever at fault.

11. Assign the media type to a user (Users, Users, select user, Media tab, Add), then create a trigger action (Alerts, Actions, Trigger actions, Create action) with an operation sending to that user via this specific media type.

12. Test with a real, automatically-fired trigger rather than only a manual script run, this is the only way to confirm the actual action wiring, not just the script's own correctness. Stopping a monitored host's Zabbix agent reliably produces a real "Zabbix agent is not available" problem after a few minutes.

    ```bash
    ansible <host> -b -m systemd -a "name=zabbix-agent2 state=stopped"
    ```

    Check Reports, Action log for the resulting attempt, and confirm the archived payload in S3:

    ```bash
    aws s3 ls s3://<bucket>/zabbix-alerts/ --recursive
    aws s3 cp s3://<bucket>/zabbix-alerts/<key> -
    ```

    Restore the agent afterward:

    ```bash
    ansible <host> -b -m systemd -a "name=zabbix-agent2 state=started"
    ```

## Verification

- A real, automatically-fired Zabbix trigger produces a `Sent` entry in Reports, Action log
- The corresponding S3 object contains the correct subject and multi-line message content
- `aws sts get-caller-identity` as the scoped publisher succeeds; any action outside `sns:Publish` on this one topic fails with `AccessDenied`

## Common Mistakes

- Assuming an `AccessDenied` error from a freshly-attached IAM managed policy means the policy is wrong. IAM permission changes can take up to a minute or two to fully propagate; verify the policy is genuinely attached, then simply wait and retry before concluding anything is misconfigured.
- Creating a Zabbix media type and assuming it is ready to use once the script and parameters are set. Without a message template, Zabbix has no content to pass as `{ALERT.SUBJECT}`/`{ALERT.MESSAGE}` and fails before ever invoking the script, logging only a generic "No message defined for media type" with no indication the script itself was never the problem.
- Testing an alert script only by running it manually as your own interactive user. Zabbix's server process runs alert scripts as its own dedicated system user (`zabbix`), which has its own home directory, its own AWS credentials location, and its own SSH key store, none of which are shared with an interactive login automatically. A script that works perfectly when run manually can still fail silently in production if credentials and keys were only ever set up for the wrong user.
- Discovering, well after the fact, that a general OS hardening pass (enabling a default-deny firewall) silently blocked a service's own management interface that was never explicitly listed as needing an allow rule. A firewall rule set written for "the services we use most" can still break access to something used rarely enough that the gap isn't noticed for a long time; when it is found, fix it in the actual IaC source (the hardening playbook) rather than only patching the live system, so it does not silently regress on a future rebuild.
- Chasing an intermittent, narrowly-reproducible failure (working reliably for one user, failing reliably for another, on an otherwise identical connection path) past the point of diminishing returns during a single session. Documenting a known limitation honestly, with what was ruled out and what wasn't, is more valuable than an open-ended debugging spiral that risks destabilizing a system that was actually healthy.

## Known Limitation

The Wazuh snapshot enrichment step is not fully reliable. It works correctly when the alert script is run manually by an interactive user (`rabih`), but consistently fails with `kex_exchange_identification: banner line 0: This account is currently not available` when the identical SSH command (same key, same jump host, same target) is run as the `zabbix` system user specifically. Ruled out during investigation: Proxmox firewall (disabled), fail2ban/sshguard (not installed), PAM account lockout (`faillock` showed no entries), a stray `/etc/nologin` file (absent), and UFW rules (unrelated to this specific path). The pipeline degrades gracefully when this happens, the Zabbix alert itself still reaches SNS and gets archived to S3 correctly, just without the Wazuh snapshot enrichment, so this does not block the phase's core deliverable, but it remains unresolved and worth a fresh look in a future session.

## Time Estimate

5-8 hours, including the extended troubleshooting session covering IAM propagation, the missing message template, the UFW port 8006 discovery, and the still-open Wazuh snapshot investigation.
