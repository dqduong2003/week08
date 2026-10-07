# Task 10.2D – Runbook (redo: all infrastructure from GitHub Actions)

Tutor feedback on the first submission: *"all infrastructure must be created
using GitHub action not sure why you are doing from local system. kindly redo
task and provide complete yml file"*.

What changed for the redo:

| File | Change |
|---|---|
| `.github/workflows/pipeline.yml` | **New, single complete pipeline.** Terraform provision → backend tests → build → Docker Scout gate → push → deploy staging → smoke test → deploy production → Prometheus/Grafana. |
| `.github/workflows/destroy.yml` | **New.** Manual `terraform destroy` from Actions (type `destroy` to confirm). |
| `.github/workflows/01`–`06-*.yml` | **Deleted.** Their contents are folded into `pipeline.yml`. |
| `terraform/versions.tf` | `backend "azurerm" {}` added: remote state in Azure Blob, shared by every Actions run. |
| `terraform/container_registry.tf` | `admin_enabled = false`, because Actions now uses `az acr login` through OIDC. |
| `terraform/output.tf` | ACR admin password and kubeconfig-command outputs removed (no longer used). |
| `terraform/terraform.tfvars.example` | New globally unique names (`kt103528453wk102d`, `kt103528453wk102dsa`). The old ACR name `s225757776week102d` is already taken in Azure. |

**Why it's possible now:** the earlier submission assumed GitHub Actions
could not authenticate to Azure, because the Swinburne Entra tenant blocks app
registrations and service principals. A **user-assigned managed identity** is
an Azure *resource* rather than an Entra app registration, and it supports
**GitHub OIDC federated credentials**. You are `Owner` on the Azure for
Students subscription, so you can create one. GitHub Actions then signs in with
a short-lived OIDC token, with no client secret, registry password or
kubeconfig stored in GitHub, and runs `terraform apply` itself.

> **Cost:** about USD $13–15/day while AKS runs. Do Steps 3–6 in one sitting,
> then run Step 7.

### Screenshot checklist

Numbers match the order the screenshots appear in `Task_10.2D_Documentation.md`.

| # | What | Captured in | Report section |
|---|---|---|---|
| 1 | Managed identity → Federated credentials | Step 1 | §2 Terraform |
| 2 | Terraform job: `Plan: N to add` and `Apply complete!` | Step 3 | §2 Terraform |
| 3 | Portal: resource group `sit722-week10-2d` and its resources | Step 3 | §2 Terraform |
| 4 | *(optional)* Re-run: Terraform `No changes` | Step 3 | §2 Terraform |
| 5 | `Destroy Infrastructure` run green | Step 7 | §2 Terraform |
| 6 | Docker Scout step **failing** with the CVE list | Step 6 (reuse from first submission) | §3 Scout scanning |
| 7 | Deployment blocked for that commit | Step 6 (reuse from first submission) | §3 Scout scanning |
| 8 | Docker Scout step **passing** in `build-scan-push` | Step 3 | §4 Remediation |
| M1–M3 | Monitoring pods, managed Prometheus (optional), Grafana login | Step 5 → `MONITORING-SETUP.md` | §5 Monitoring deployed |
| M4–M9 | Grafana dashboards, Prometheus targets and query | Step 5 → `MONITORING-SETUP.md` | §6 Dashboards & metrics |
| 9 | Pipeline summary graph, all 7 jobs green | Step 3 | §7 Pipeline run |
| 10 | `kubectl` — nodes + staging/production/monitoring healthy | Step 4 | §7 Pipeline run |
| 11 | Production app in a browser | Step 4 | §7 Pipeline run |

Screenshot 5 (destroy) appears in §2 but is captured **last**. Take every
other screenshot first, because destroying removes the cluster.

---

## Step 1 – One-time identity bootstrap (the only local step)

Actions needs an identity before it can log in to anything, so this one
thing has to exist before the first run. **It creates no application
infrastructure.** The resource group, ACR, Storage and AKS are all created
by the pipeline. Run these commands in PowerShell, logged in with `az login`:

```powershell
$SUB    = az account show --query id -o tsv
$TENANT = az account show --query tenantId -o tsv
$REPO   = "dqduong2003/week08"
$RG     = "sit722-cicd-bootstrap"
$ID     = "gh-actions-sit722"

# Resource providers are currently NOT registered on this subscription
# (checked with `az provider show`), so register the ones the pipeline uses.
foreach ($p in "Microsoft.ManagedIdentity","Microsoft.Storage","Microsoft.ContainerRegistry",
               "Microsoft.ContainerService","Microsoft.Network","Microsoft.Compute",
               "Microsoft.OperationalInsights") {
  az provider register --namespace $p --wait
}

# The pipeline's identity (kept in its own RG so `terraform destroy` never deletes it)
az group create -n $RG -l australiaeast
az identity create -n $ID -g $RG
$CLIENT_ID    = az identity show -n $ID -g $RG --query clientId -o tsv
$PRINCIPAL_ID = az identity show -n $ID -g $RG --query principalId -o tsv

# Trust GitHub's OIDC tokens from this repo. Jobs that declare
# `environment:` present an environment subject rather than the branch
# subject, so all three subjects are needed.
az identity federated-credential create -g $RG --identity-name $ID --name gh-main `
  --issuer https://token.actions.githubusercontent.com --audiences api://AzureADTokenExchange `
  --subject "repo:${REPO}:ref:refs/heads/main"
az identity federated-credential create -g $RG --identity-name $ID --name gh-env-staging `
  --issuer https://token.actions.githubusercontent.com --audiences api://AzureADTokenExchange `
  --subject "repo:${REPO}:environment:staging"
az identity federated-credential create -g $RG --identity-name $ID --name gh-env-production `
  --issuer https://token.actions.githubusercontent.com --audiences api://AzureADTokenExchange `
  --subject "repo:${REPO}:environment:production"

# Contributor: create resources. User Access Administrator: Terraform creates
# the AcrPull role assignment for AKS.
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal `
  --role "Contributor" --scope "/subscriptions/$SUB"
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal `
  --role "User Access Administrator" --scope "/subscriptions/$SUB"

"AZURE_CLIENT_ID       = $CLIENT_ID"
"AZURE_TENANT_ID       = $TENANT"
"AZURE_SUBSCRIPTION_ID = $SUB"
```

Note the `${REPO}` braces: plain `$REPO:` would be read by PowerShell as a
scoped variable name.

> **[Screenshot 1]** Azure portal (directory: **Swinburne University**) → search **Managed Identities** → `gh-actions-sit722` → **Settings → Federated credentials**, showing the three GitHub subjects.
> Do not use Entra ID → *App registrations*: that lists app registrations, not managed identities. An app registration with the same name is a different object.

---

## Step 2 – Configure GitHub

Repo → **Settings → Secrets and variables → Actions**.

**Delete the old ones** from the first submission:
- Variables `ACR_NAME`, `ACR_LOGIN_SERVER`, `AKS_RESOURCE_GROUP`, `AKS_CLUSTER_NAME`
- Secrets `ACR_USERNAME`, `ACR_PASSWORD`, `KUBE_CONFIG`
- `AZURE_STORAGE_CONNECTION_STRING`, from both environments

**Repository variables** (these are IDs, not secrets):

| Name | Value |
|---|---|
| `AZURE_CLIENT_ID` | from Step 1 |
| `AZURE_TENANT_ID` | from Step 1 |
| `AZURE_SUBSCRIPTION_ID` | from Step 1 |

**Repository secrets** (keep them if they still exist):

| Name | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub PAT (Read-only) |

**Environments** `staging` and `production`, each with 6 secrets:
`POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=postgres`,
`JWT_SECRET_KEY=koalatech-local-development-secret`,
`DEFAULT_ADMIN_USERNAME=admin`, `DEFAULT_ADMIN_EMAIL=admin@koalatech.edu.au`,
`DEFAULT_ADMIN_PASSWORD=AdminPassword123!`.

The storage connection string no longer goes into GitHub. The deploy jobs
read it from the storage account that Terraform creates.

---

## Step 3 – Push to `main`: the pipeline provisions and deploys everything

```powershell
cd "week10-10.2D"
git push -u origin feature/10.2d-gha-provisioning
# then open a PR feature/10.2d-gha-provisioning -> main on GitHub and merge it
# (or: git checkout main; git merge feature/10.2d-gha-provisioning; git push origin main)
```

The push to `main` starts **KoalaTech CI/CD Pipeline**. The first run takes
about 20–25 minutes, most of it AKS creation in the `terraform` job.

> **[Screenshot 2]** `Provision infrastructure (Terraform)` job log: `terraform plan` showing `Plan: N to add, 0 to change, 0 to destroy`, and `terraform apply` ending with **`Apply complete!`**.
> **[Screenshot 3]** Azure portal → resource group `sit722-week10-2d`, showing ACR, Storage and AKS created by the pipeline (tags show `ManagedBy = Terraform`).
> **[Screenshot 8]** One `Build, scan and push …` job expanded, showing **Analyze image with Docker Scout** passing.
> **[Screenshot 9]** The run's **summary graph** with all 7 jobs green: `terraform` and `backend-test` → `build-scan-push` (×6) → `deploy-staging` → `smoke-test-staging` → `deploy-production` → `deploy-monitoring`.

### Optional: prove idempotency

Re-run the workflow (**Actions → KoalaTech CI/CD Pipeline → Run workflow**,
branch `main`). The `terraform` job should now report **`No changes. Your
infrastructure matches the configuration.`**

> **[Screenshot 4]** (optional) Second run's Terraform log: `No changes`.

---

## Step 4 – Verify the deployment

```powershell
az aks get-credentials --resource-group sit722-week10-2d --name aks-sit722-week10-2d --overwrite-existing
kubectl get nodes
kubectl get pods,svc,pvc -n staging
kubectl get pods,svc,pvc -n production
kubectl get pods -n monitoring
kubectl get svc frontend -n production -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# open http://<that-ip>
```

> **[Screenshot 10]** Terminal: 3 nodes, all three namespaces healthy.
> **[Screenshot 11]** Browser: production app reachable at its LoadBalancer IP.

---

## Step 5 – Monitoring screenshots

Follow `MONITORING-SETUP.md` (Screenshots M1–M9).

---

## Step 6 – Docker Scout "before" evidence

The report needs the gate shown **failing** as well as passing (Screenshot 8).
The "before" screenshots from the first submission are still valid evidence
of the gate. They show the same scan step, which now lives in
`pipeline.yml`'s `build-scan-push` job. Reuse them as Screenshots 6–7.

> **[Screenshot 6]** CI failing at "Analyze image with Docker Scout", with the CVE list visible in the log (first submission's Screenshot 3).
> **[Screenshot 7]** Deployment not running for that commit, showing the gate blocked promotion (first submission's Screenshot 4).

**Alternative (re-capture under the new pipeline):** temporarily set
`PyJWT==2.10.1` in one service's `requirements.txt` and push to `main`. The
Scout step fails, and the run graph shows `deploy-staging` →
`deploy-monitoring` as **skipped**. Capture that as Screenshots 6–7, then
revert and push again.

---

## Step 7 – DESTROY everything from Actions

**Actions → Destroy Infrastructure → Run workflow** (branch `main`), and type
`destroy` in the confirm box.

> **[Screenshot 5]** `Destroy Infrastructure` run green, with the log ending in `Destroy complete!` and `Resource group sit722-week10-2d deleted.`

Then remove the bootstrap pieces once the task has been marked:

```powershell
az group delete -n sit722-cicd-bootstrap --yes      # identity + Terraform state
az role assignment list --scope "/subscriptions/$(az account show --query id -o tsv)" -o table  # orphaned entries can be deleted
az group list -o table                              # should not list sit722-week10-2d
```

Also revoke the Docker Hub PAT if you no longer need it.
