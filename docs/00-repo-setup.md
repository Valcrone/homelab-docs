# Repo Setup

## Objective

Create the `homelab-docs` GitHub repository, authenticate the GitHub CLI, and lay down the base folder structure and CI pipeline before any homelab build work starts.

## Prerequisites

- GitHub account
- Git installed locally (`git --version`)
- GitHub CLI installed (`gh --version`)

## Steps

1. Install GitHub CLI if not already installed.
   - Windows: `winget install --id GitHub.cli`
   - Verify: `gh --version`

2. Authenticate the CLI.

   ```bash
   gh auth login
   ```

   Choose: GitHub.com → HTTPS → Authenticate via web browser. Follow the one-time code prompt in the browser.

   Verify:

   ```bash
   gh auth status
   ```

   Expected output includes `Logged in to github.com as <username>`.

3. Create the repository and clone it locally.

   ```bash
   gh repo create homelab-docs --public --clone
   cd homelab-docs
   ```

4. Create the base folder structure.

   ```bash
   mkdir -p docs terraform ansible .github/workflows
   touch terraform/.gitkeep ansible/.gitkeep
   ```

   `.gitkeep` is a placeholder file. Git does not track empty directories, so this keeps `terraform/` and `ansible/` present in the repo until real files land in them.

5. Add `.gitignore`.

   ```bash
   cat > .gitignore << 'EOF'
   *.tfstate
   *.tfstate.backup
   .terraform/
   *.tfvars
   *.retry
   .vault_pass
   EOF
   ```

6. Add `README.md`, `docs/PHASE_TEMPLATE.md`, `.markdownlint-cli2.jsonc`, and `.github/workflows/ci.yml` (contents below, or copy from the provided files).

7. Commit and push.

   ```bash
   git add .
   git commit -m "Initial repo structure and CI pipeline"
   git push --set-upstream origin main
   ```

8. Tag the milestone.

   ```bash
   git tag v0.1.0-repo-setup
   git push --tags
   ```

## Verification

- Repo visible at `https://github.com/<username>/homelab-docs`
- `gh auth status` shows an authenticated session
- Actions tab shows the CI workflow running on the push with a passing markdown lint job and a Terraform job that reports "no .tf files yet" (expected at this stage)
- `git tag` lists `v0.1.0-repo-setup`

## Common Mistakes

- Running `gh repo create` before `gh auth login` completes. Command fails with an auth error.
- Forgetting `--clone`, which leaves a remote repo with no local working copy.
- Committing `.tfvars` or `.vault_pass` files before `.gitignore` is in place.
- Naming the CI workflow file anything other than `.yml`/`.yaml` inside `.github/workflows/`. GitHub Actions silently ignores anything else.
- Pushing without `--set-upstream` on the first push of a new branch. Git will refuse and tell you to set it; just add the flag and push again.

## Time Estimate

20-30 minutes.
