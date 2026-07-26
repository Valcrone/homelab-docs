# Phase 5: Terraform and AWS Foundation

## Objective

Provision the AWS resources needed for the later event pipeline (Phase 7) using Terraform: an S3 bucket for Wazuh log archives, an SNS topic for Zabbix alert notifications, and an IAM role scoped for a future Lambda function to write to both. End state: infrastructure exists in AWS, defined entirely as code, with no manual console configuration.

## Prerequisites

- An AWS account with billing configured (a dedicated fresh account was used here for a clean free tier allowance, though this is optional; S3, SNS, and IAM cost negligibly at this project's scale regardless of free tier status)
- A confirmed Basic (free) support plan, not a paid tier
- Terraform installed locally
- AWS CLI installed locally, used only to configure credentials

## Steps

1. Install Terraform.

   ```powershell
   winget install --id Hashicorp.Terraform
   ```

   Close and reopen the terminal for the PATH change to take effect, then verify:

   ```powershell
   terraform -version
   ```

2. Create a dedicated IAM user for Terraform rather than using root account credentials. In the AWS Console, IAM, Users, Create user:

   - User name: `terraform-homelab`
   - Do not enable console access; this user only needs programmatic (API) access

   Attach these AWS-managed policies directly (broad scope, acceptable for a personal account with nothing else in it; a tighter custom policy restricted to specific resource ARNs is a documented future improvement, not done here):

   - `AmazonS3FullAccess`
   - `AmazonSNSFullAccess`
   - `IAMFullAccess`

   On the user's Security credentials tab, create an access key with use case "Command Line Interface (CLI)".

3. Install the AWS CLI and configure it with the new user's credentials.

   ```powershell
   winget install --id Amazon.AWSCLI
   ```

   Close and reopen the terminal, then:

   ```powershell
   aws configure
   ```

   Enter the access key ID, secret access key, region `us-east-1`, and output format `json` when prompted. This writes credentials to a local file that both the AWS CLI and Terraform read automatically; credentials are never placed in any project file or committed to git.

   Verification:

   ```powershell
   aws sts get-caller-identity
   ```

   Confirms the account ID and IAM user ARN match what was just created.

4. Create `terraform/provider.tf`, declaring the AWS and random providers and target region.

   ```hcl
   terraform {
     required_providers {
       aws = {
         source  = "hashicorp/aws"
         version = "~> 5.0"
       }
       random = {
         source  = "hashicorp/random"
         version = "~> 3.0"
       }
     }
   }

   provider "aws" {
     region = "us-east-1"
   }
   ```

5. Create `terraform/main.tf`, defining the actual resources.

   - `random_id`: generates a short unique suffix so the S3 bucket name does not collide with any other bucket globally, since S3 bucket names are unique across all of AWS, not just within one account
   - `aws_s3_bucket`: the log archive bucket itself, tagged for identification
   - `aws_s3_bucket_public_access_block`: explicitly blocks all public access; this bucket holds security log data and should never be publicly reachable
   - `aws_sns_topic`: the topic Zabbix will publish alerts to in Phase 7
   - `aws_iam_role` and `aws_iam_role_policy`: a role scoped narrowly to what a future Lambda function needs, write access to only this specific bucket's ARN plus the minimum CloudWatch Logs permissions required to run, not broad access to all S3 or all logs

   See the file itself for the full resource definitions.

6. Initialize Terraform, which downloads the declared provider plugins.

   ```powershell
   terraform init
   ```

   Verification: reports both providers installed successfully and creates `.terraform.lock.hcl`.

7. Review the plan before applying anything.

   ```powershell
   terraform plan
   ```

   Confirm it shows only resources to create, nothing to change or destroy, and that the resource count and types match what was actually written.

8. Apply.

   ```powershell
   terraform apply
   ```

   Type `yes` when prompted. Verification: `Apply complete! Resources: 6 added, 0 changed, 0 destroyed.`

9. Confirm the resources exist in the AWS Console directly, not just in Terraform's own state file: S3 shows the new bucket in the correct region; SNS Topics shows the new topic; IAM Roles shows the new role.

10. Run the same formatting and validation checks CI will run, before committing.

    ```powershell
    terraform fmt -check
    terraform validate
    ```

    `fmt -check` prints nothing on success; any filenames printed indicate formatting to fix. `validate` should report the configuration is valid.

11. Confirm `.gitignore` already excludes Terraform's local state and plugin directory before committing (it does, from the repo's original setup): `*.tfstate`, `*.tfstate.backup`, and `.terraform/` must never be committed, since the state file can contain sensitive resource details and the plugin directory is large and machine-specific. `.terraform.lock.hcl` should be committed, since it pins exact provider versions for reproducibility.

12. Commit phase documentation and tag the milestone.

    ```bash
    git add .
    git commit -m "Phase 5: Terraform and AWS foundation"
    git tag v0.7.0-terraform
    git push
    git push --tags
    ```

## Verification

- `terraform plan` run again shows no changes, confirming the applied state matches the configuration exactly
- S3 bucket, SNS topic, and IAM role all visible and correctly configured in the AWS Console
- CI pipeline's `terraform fmt -check` and `terraform validate` jobs pass on push, running for the first time now that real `.tf` files exist

## Common Mistakes

- Using root account credentials directly with Terraform instead of a dedicated, scoped IAM user. Root credentials have unrestricted access to the entire account with no ability to narrow permissions; a dedicated IAM user, even with broad managed policies attached, is still a meaningfully smaller blast radius and can be revoked independently.
- Pasting access keys into a chat conversation, documentation, or any file that might be committed. Treat any credential that has been exposed this way as compromised and rotate it, regardless of how minor the account's actual risk seems.
- Forgetting that a fresh terminal session is required after installing a CLI tool via winget; the PATH update does not apply to an already-open shell.
- Committing `.terraform/` or `terraform.tfstate`. Both are already covered by this repo's `.gitignore`, but this is worth double-checking on any new machine or fresh clone, since a state file left untracked locally with no backup is itself a risk if the machine is lost, a tradeoff accepted here for a personal project but worth understanding as a real limitation of local state.

## Time Estimate

1.5-2.5 hours, most of it in initial AWS account and IAM user setup rather than the Terraform configuration itself, which is small at this stage.
