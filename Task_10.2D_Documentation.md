# SIT722 Software Deployment and Operation — Task 10.2D

## IaC, Security Scanning & Monitoring in the CI/CD Pipeline

**Student:** Daniel Dang (103528453) **Trimester:** 2026/T2
**Repository:** `github.com/dqduong2003/week08` (`main`)

---

## 1. Updated GitHub Actions workflow files

| File | Purpose |
|---|---|
| `.github/workflows/pipeline.yml` | End-to-end pipeline: Terraform → tests → build → Docker Scout → push → staging → smoke test → production → monitoring |
| `.github/workflows/destroy.yml` | Manual `terraform destroy` |

```
terraform ──────┐
                ├─> build-scan-push (x6) ─> deploy-staging ─> smoke-test-staging
backend-test ───┘        ─> deploy-production ─> deploy-monitoring
```

Both files are reproduced in full in [Appendix A](#appendix-a--complete-githubworkflowspipelineyml) and [Appendix B](#appendix-b--complete-githubworkflowsdestroyyml). Every job signs in to Azure with GitHub OIDC through a user-assigned managed identity. No Azure credentials are stored in GitHub.

---

## 2. Evidence of Terraform execution within the pipeline

The `terraform` job creates its remote-state storage, then runs `fmt -check`, `init`, `validate`, `plan` and `apply`. It provisions the resource group, ACR, Storage account, 3-node AKS cluster and `AcrPull` role assignment, and passes the resource names to later jobs as job outputs.

> **[Screenshot 1]** Azure portal (Swinburne directory) → Managed Identities → `gh-actions-sit722` → **Federated credentials**, showing the three GitHub OIDC subjects (`main`, `staging`, `production`) that let the pipeline sign in to Azure without stored secrets.

> **[Screenshot 2]** `Provision infrastructure (Terraform)` job log: `Plan: N to add` and **`Apply complete!`**.

> **[Screenshot 3]** Azure portal: resource group `sit722-week10-2d` with ACR, Storage and AKS, tagged `ManagedBy = Terraform`.

> **[Screenshot 4]** (optional) Re-run: Terraform reports `No changes` (idempotent).

> **[Screenshot 5]** `Destroy Infrastructure` run: `Destroy complete!`.

---

## 3. Evidence of Docker Scout vulnerability scanning

In `build-scan-push`, `docker/scout-action` runs `cves` (Critical/High, `exit-code: true`) and `policy` after the image is built and before it is pushed.

On the first full pipeline run, Scout failed 4 of the 6 images. `student`, `lecturer`, `course` and `enrollment-service` pinned `PyJWT==2.13.0`, which has six newly published advisories:

| CVE | Severity | CVSS | Issue |
|---|---|---|---|
| CVE-2026-102268 | **CRITICAL** | 9.1 | Improper verification of cryptographic signature |
| CVE-2026-102266, -102271, -102272, -102273 | HIGH | 7.4 | Improper verification of cryptographic signature |
| CVE-2026-102267 | HIGH | 7.4 | Exposure of sensitive information |

All six are fixed in `PyJWT 2.14.0`. `user-service` passed only because it declared `PyJWT>=2.13.0`, so pip happened to install a newer, unaffected release.

> **[Screenshot 6]** `Build, scan and push koalatech-student-service` failing at **Analyze image with Docker Scout**, with the CVE list in the log.

> **[Screenshot 7]** Run graph: four scan jobs failed, and `Deploy to Staging` through `Deploy Monitoring` were skipped. The gate blocked promotion.

---

## 4. Evidence of remediation

**Fix for the findings above:** all five backend `requirements.txt` files now pin `PyJWT==2.14.0`, the fixed version Scout reported. `user-service` is pinned exactly as well, so its build no longer depends on whatever version pip resolves at build time.

> **[Screenshot 8]** The re-run after the fix, with **Analyze image with Docker Scout** passing for every image.

**Earlier remediation rounds** (commit `d4cd1c5`), found the same way:

1. `python-multipart` 0.0.20 → 0.0.30 (CVE-2026-24486, HIGH, path traversal) and `PyJWT` 2.10.1 → 2.13.0 (CVE-2026-32597 / -48526).
2. `fastapi` 0.116.1 → 0.133.0. This cleared three HIGH `starlette` CVEs whose fixed versions exceed fastapi's old `starlette<0.48.0` bound.
3. Added `apk update && apk upgrade` to the frontend's `nginx:1.27-alpine` stage, which picks up the patched `curl` (CVE-2026-9079, CRITICAL).
4. Set `ignore-base: true` / `only-fixed: true`. Two HIGH CVEs in Debian `zlib`/`perl` in `python:3.12-slim` have no upstream fix. The gate still blocks every fixable application-layer finding.

---

## 5. Evidence that Prometheus and Grafana are deployed and configured

The `deploy-monitoring` job installs `kube-prometheus-stack` with `helm upgrade --install` into the `monitoring` namespace. The stack includes Prometheus, Alertmanager, Grafana, `kube-state-metrics` and `node-exporter`. The job then verifies the rollouts and confirms that production is still reachable.

> **[Screenshot M1]** All `monitoring` pods `Running`.

> **[Screenshot M2]** (optional) Azure Monitor managed Prometheus enabled on the cluster.

> **[Screenshot M3]** Grafana home page after logging in.

---

## 6. Dashboards and collected metrics

> **[Screenshot M4]** Kubernetes / Compute Resources / Cluster: cluster-wide CPU and memory.

> **[Screenshot M5]** Kubernetes / Compute Resources / Namespace (Pods), filtered to `staging`.

> **[Screenshot M6]** Node Exporter / Nodes, across the 3 AKS nodes.

> **[Screenshot M7]** Prometheus / Overview: ingestion and scrape health.

> **[Screenshot M8]** Prometheus `/targets`: scrape targets `UP`.

> **[Screenshot M9]** Query `kube_pod_container_status_running{namespace="staging"}` listing the KoalaTech pods.

---

## 7. Evidence of successful pipeline execution

> **[Screenshot 9]** Run summary graph: all jobs green, from `terraform` through `deploy-monitoring`.

> **[Screenshot 10]** `kubectl get pods,svc,pvc` for `staging`, `production` and `monitoring`, all healthy.

> **[Screenshot 11]** Production frontend reachable in a browser.

---

## 8. Integration, placement and DevOps/DevSecOps value

**Terraform** is the first job, so the infrastructure is created and updated from code before anything is deployed to it. It runs `fmt`, `validate`, `plan` and `apply` against shared remote state in Azure Blob Storage, and a `concurrency` group prevents two applies running at once. Re-runs with no changes report `No changes`, so applying on every push is safe. Its outputs feed every later job, so no resource names or credentials are copied by hand. Authentication uses short-lived GitHub OIDC tokens from a managed identity rather than stored secrets.

**Docker Scout** sits between build and push. An image with a fixable Critical or High CVE fails the job before it reaches ACR, and because every deploy job depends on this one, a failed scan also stops staging, production and monitoring. Limiting the gate to fixable application-layer findings keeps it strict without failing on base-image issues the team cannot patch.

**Monitoring** is the last stage, because Prometheus and Grafana need a running cluster and workloads to observe. `helm upgrade --install` is idempotent, so running it on every pipeline keeps the stack current without disrupting it. The final reachability check confirms that production still serves traffic.

Together these stages form a DevSecOps loop. Infrastructure is versioned and applied automatically, vulnerabilities are caught before release rather than after, credentials are short-lived, and the running system stays observable. This shortens feedback and makes every change reproducible and auditable from the Actions history.

---

## 9. Reflection on generative AI use

I used Claude Code to design and write the workflows, the Terraform backend configuration and this documentation.

- **Adopted:** OIDC with a user-assigned managed identity, after read-only `az` checks confirmed the account is subscription `Owner`. A managed identity needs no Entra app registration, which the student tenant blocks.
- **Modified:** Claude's first remediation pinned only `python-multipart` and `PyJWT`. When Scout then reported `starlette` CVEs, I accepted the `fastapi` bump only after it was verified locally (app import and `pytest --collect-only`).
- **Rejected:** an earlier suggestion to run `terraform apply` locally because of the tenant restriction. It did not meet the requirement for pipeline-driven infrastructure.

I reviewed every change, and I ran every cloud, credential and `git push` step myself.

---

## Appendix A — complete `.github/workflows/pipeline.yml`

```yaml
name: KoalaTech CI/CD Pipeline

# One end-to-end pipeline, run entirely in GitHub Actions:
#
#   terraform ─┐
#              ├─> build-scan-push ─> deploy-staging ─> smoke-test-staging
#   backend-test┘                         ─> deploy-production ─> deploy-monitoring
#
# Every Azure resource (resource group, ACR, Storage, AKS, AcrPull role
# assignment) is provisioned by the `terraform` job - nothing is created
# from a local machine. Later jobs read the names they need from that job's
# outputs, so no Azure value is copied into GitHub by hand.
#
# Authentication: GitHub OIDC -> an Azure user-assigned managed identity
# with federated credentials (see SETUP-10.2D.md). No service principal, no
# client secret, no registry password, no kubeconfig is stored in GitHub;
# every job gets a short-lived token for that run only.

on:
  push:
    branches:
      - main
  workflow_dispatch:

# id-token: write lets each job request a GitHub OIDC token for azure/login
# and for Terraform's azurerm provider/backend.
permissions:
  id-token: write
  contents: read

# Never run two pipelines (and so two `terraform apply`s) against the same
# state at once; queue instead of cancelling a half-finished apply.
concurrency:
  group: koalatech-pipeline-${{ github.ref }}
  cancel-in-progress: false

env:
  # --- Azure identity (non-secret IDs, stored as repository variables) ---
  ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
  ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
  ARM_USE_OIDC: "true"

  # --- Terraform remote state (created by the terraform job if missing) ---
  TFSTATE_RESOURCE_GROUP: sit722-cicd-bootstrap
  TFSTATE_STORAGE_ACCOUNT: kt103528453tfstate
  TFSTATE_CONTAINER: tfstate
  TFSTATE_KEY: week10-2d.terraform.tfstate
  TFSTATE_LOCATION: australiaeast

  # --- Terraform input variables (terraform.tfvars is git-ignored) ---
  TF_IN_AUTOMATION: "true"
  TF_VAR_location: Australia East
  TF_VAR_resource_group_name: sit722-week10-2d
  TF_VAR_acr_name: kt103528453wk102d
  TF_VAR_storage_account_name: kt103528453wk102dsa
  TF_VAR_aks_cluster_name: aks-sit722-week10-2d
  TF_VAR_aks_dns_prefix: sit722week102d
  TF_VAR_aks_node_count: "3"
  TF_VAR_aks_node_vm_size: Standard_B2s_v2
  TF_VAR_environment: development

jobs:

  # =========================================================
  # 1. Infrastructure as Code - provision Azure with Terraform
  # =========================================================
  terraform:
    name: Provision infrastructure (Terraform)
    runs-on: ubuntu-latest

    defaults:
      run:
        working-directory: terraform

    outputs:
      resource_group: ${{ steps.tf-outputs.outputs.resource_group }}
      acr_name: ${{ steps.tf-outputs.outputs.acr_name }}
      acr_login_server: ${{ steps.tf-outputs.outputs.acr_login_server }}
      aks_cluster_name: ${{ steps.tf-outputs.outputs.aks_cluster_name }}
      storage_account_name: ${{ steps.tf-outputs.outputs.storage_account_name }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      # Terraform's remote state store is itself created here, idempotently,
      # so the only thing that exists before the first run is the pipeline's
      # own identity.
      - name: Ensure Terraform state storage exists
        run: |
          az group create \
            --name "$TFSTATE_RESOURCE_GROUP" \
            --location "$TFSTATE_LOCATION" \
            --output none

          if ! az storage account show \
                --name "$TFSTATE_STORAGE_ACCOUNT" \
                --resource-group "$TFSTATE_RESOURCE_GROUP" \
                --output none 2>/dev/null; then
            az storage account create \
              --name "$TFSTATE_STORAGE_ACCOUNT" \
              --resource-group "$TFSTATE_RESOURCE_GROUP" \
              --location "$TFSTATE_LOCATION" \
              --sku Standard_LRS \
              --kind StorageV2 \
              --min-tls-version TLS1_2 \
              --allow-blob-public-access false \
              --output none
          fi

          az storage container create \
            --name "$TFSTATE_CONTAINER" \
            --account-name "$TFSTATE_STORAGE_ACCOUNT" \
            --auth-mode key \
            --output none

      - name: Set up Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"
          # Wrapper off so `terraform output -raw` returns the bare value.
          terraform_wrapper: false

      - name: Terraform format check
        run: terraform fmt -check -recursive -diff

      - name: Terraform init (Azure Blob remote state)
        run: |
          terraform init -input=false \
            -backend-config="resource_group_name=$TFSTATE_RESOURCE_GROUP" \
            -backend-config="storage_account_name=$TFSTATE_STORAGE_ACCOUNT" \
            -backend-config="container_name=$TFSTATE_CONTAINER" \
            -backend-config="key=$TFSTATE_KEY"

      - name: Terraform validate
        run: terraform validate

      - name: Terraform plan
        run: terraform plan -input=false -out=tfplan

      - name: Terraform apply
        run: terraform apply -input=false -auto-approve tfplan

      - name: Export Terraform outputs
        id: tf-outputs
        run: |
          {
            echo "resource_group=$(terraform output -raw resource_group_name)"
            echo "acr_name=$(terraform output -raw acr_name)"
            echo "acr_login_server=$(terraform output -raw acr_login_server)"
            echo "aks_cluster_name=$(terraform output -raw aks_cluster_name)"
            echo "storage_account_name=$(terraform output -raw storage_account_name)"
          } >> "$GITHUB_OUTPUT"
          cat "$GITHUB_OUTPUT"


  # =========================================================
  # 2. Backend tests (no Azure access - runs alongside Terraform)
  # =========================================================
  backend-test:
    name: Test ${{ matrix.service }}
    runs-on: ubuntu-latest

    strategy:
      fail-fast: false
      matrix:
        include:
          - service: user-service
            database: users
            port: 5433
          - service: student-service
            database: students
            port: 5434
          - service: lecturer-service
            database: lecturers
            port: 5435
          - service: course-service
            database: courses
            port: 5436
          - service: enrollment-service
            database: enrollments
            port: 5437

    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: ${{ matrix.database }}
        ports:
          - ${{ matrix.port }}:5432
        options: >-
          --health-cmd="pg_isready -U postgres -d ${{ matrix.database }}"
          --health-interval=5s
          --health-timeout=5s
          --health-retries=10

    env:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: ${{ matrix.database }}
      POSTGRES_HOST: localhost
      POSTGRES_PORT: ${{ matrix.port }}
      JWT_SECRET_KEY: koalatech-ci-test-secret
      JWT_ALGORITHM: HS256
      ACCESS_TOKEN_EXPIRE_MINUTES: 30
      DEFAULT_ADMIN_USERNAME: admin
      DEFAULT_ADMIN_EMAIL: admin@koalatech.edu.au
      DEFAULT_ADMIN_PASSWORD: AdminPassword123!
      AZURE_STORAGE_CONNECTION_STRING: ""
      AZURE_STORAGE_CONTAINER_NAME: ""

    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Set up Python
        uses: actions/setup-python@v6
        with:
          python-version: "3.12"

      - name: Install dependencies
        working-directory: ${{ matrix.service }}
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements.txt

      - name: Run tests
        working-directory: ${{ matrix.service }}
        run: pytest -v


  # =========================================================
  # 3. Build -> Docker Scout security gate -> push to ACR
  # =========================================================
  build-scan-push:
    name: Build, scan and push ${{ matrix.image }}
    runs-on: ubuntu-latest
    needs:
      - terraform
      - backend-test

    env:
      ACR_LOGIN_SERVER: ${{ needs.terraform.outputs.acr_login_server }}

    strategy:
      fail-fast: false
      matrix:
        include:
          - service: frontend
            image: koalatech-frontend
          - service: user-service
            image: koalatech-user-service
          - service: student-service
            image: koalatech-student-service
          - service: lecturer-service
            image: koalatech-lecturer-service
          - service: course-service
            image: koalatech-course-service
          - service: enrollment-service
            image: koalatech-enrollment-service

    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      # Token-based registry login from the OIDC session - the ACR admin
      # user is disabled in Terraform, so there is no registry password.
      - name: Login to Azure Container Registry
        run: az acr login --name "${{ needs.terraform.outputs.acr_name }}"

      - name: Build Docker image
        run: |
          docker build \
            --platform linux/amd64 \
            -t "$ACR_LOGIN_SERVER/${{ matrix.image }}:${{ github.sha }}" \
            ./${{ matrix.service }}

      # Docker Scout evaluates via Docker Hub's backend regardless of which
      # registry hosts the image, so it needs its own Docker Hub login.
      - name: Login to Docker Hub (for Docker Scout)
        uses: docker/login-action@v4
        with:
          registry: docker.io
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      # Security gate between build and push: a fixable Critical/High CVE
      # introduced by this application layer fails the job here, before the
      # image ever reaches ACR or a deployment could pull it.
      #
      # ignore-base: true - don't gate on advisories that exist unchanged in
      #   the upstream base image (Debian OS packages with no patched version
      #   yet); this repo can't fix those.
      # only-fixed: true  - don't gate on advisories with no available fix.
      - name: Analyze image with Docker Scout
        uses: docker/scout-action@v1
        with:
          command: cves
          image: ${{ env.ACR_LOGIN_SERVER }}/${{ matrix.image }}:${{ github.sha }}
          exit-code: true
          only-severities: critical,high
          ignore-base: true
          only-fixed: true

      - name: Evaluate Docker Scout policies
        uses: docker/scout-action@v1
        with:
          command: policy
          image: ${{ env.ACR_LOGIN_SERVER }}/${{ matrix.image }}:${{ github.sha }}
          organization: ${{ secrets.DOCKERHUB_USERNAME }}

      - name: Push Docker image with commit SHA
        run: docker push "$ACR_LOGIN_SERVER/${{ matrix.image }}:${{ github.sha }}"


  # =========================================================
  # 4. Deploy to staging
  # =========================================================
  deploy-staging:
    name: Deploy to Staging
    runs-on: ubuntu-latest
    needs:
      - terraform
      - build-scan-push

    environment:
      name: staging

    env:
      NAMESPACE: staging
      RESOURCE_GROUP: ${{ needs.terraform.outputs.resource_group }}
      AKS_CLUSTER_NAME: ${{ needs.terraform.outputs.aks_cluster_name }}
      STORAGE_ACCOUNT_NAME: ${{ needs.terraform.outputs.storage_account_name }}
      ACR_LOGIN_SERVER: ${{ needs.terraform.outputs.acr_login_server }}
      IMAGE_TAG: ${{ github.sha }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Get AKS credentials
        run: |
          az aks get-credentials \
            --resource-group "$RESOURCE_GROUP" \
            --name "$AKS_CLUSTER_NAME" \
            --admin \
            --overwrite-existing
          kubectl get nodes

      - name: Create namespace
        run: |
          kubectl create namespace "$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -

      # The Blob Storage connection string is read live from the storage
      # account Terraform just created, rather than stored as a GitHub secret.
      - name: Create Kubernetes secrets
        env:
          POSTGRES_USER: ${{ secrets.POSTGRES_USER }}
          POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
          JWT_SECRET_KEY: ${{ secrets.JWT_SECRET_KEY }}
          DEFAULT_ADMIN_USERNAME: ${{ secrets.DEFAULT_ADMIN_USERNAME }}
          DEFAULT_ADMIN_EMAIL: ${{ secrets.DEFAULT_ADMIN_EMAIL }}
          DEFAULT_ADMIN_PASSWORD: ${{ secrets.DEFAULT_ADMIN_PASSWORD }}
        run: |
          STORAGE_CONN=$(az storage account show-connection-string \
            --resource-group "$RESOURCE_GROUP" \
            --name "$STORAGE_ACCOUNT_NAME" \
            --query connectionString -o tsv)
          echo "::add-mask::$STORAGE_CONN"

          kubectl create secret generic postgres-secret \
            --namespace "$NAMESPACE" \
            --from-literal=POSTGRES_USER="$POSTGRES_USER" \
            --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
            --dry-run=client -o yaml | kubectl apply -f -

          kubectl create secret generic application-secret \
            --namespace "$NAMESPACE" \
            --from-literal=POSTGRES_USER="$POSTGRES_USER" \
            --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
            --from-literal=JWT_SECRET_KEY="$JWT_SECRET_KEY" \
            --from-literal=DEFAULT_ADMIN_USERNAME="$DEFAULT_ADMIN_USERNAME" \
            --from-literal=DEFAULT_ADMIN_EMAIL="$DEFAULT_ADMIN_EMAIL" \
            --from-literal=DEFAULT_ADMIN_PASSWORD="$DEFAULT_ADMIN_PASSWORD" \
            --from-literal=AZURE_STORAGE_CONNECTION_STRING="$STORAGE_CONN" \
            --dry-run=client -o yaml | kubectl apply -f -

      - name: Apply Kubernetes manifests
        run: kubectl apply -f kubernetes/staging/

      - name: Update images to this commit
        run: |
          for svc in frontend user-service student-service lecturer-service course-service enrollment-service; do
            kubectl set image "deployment/$svc" \
              "$svc=$ACR_LOGIN_SERVER/koalatech-$svc:$IMAGE_TAG" \
              -n "$NAMESPACE"
          done

      - name: Wait for rollouts
        run: |
          for svc in frontend user-service student-service lecturer-service course-service enrollment-service; do
            kubectl rollout status "deployment/$svc" -n "$NAMESPACE" --timeout=300s
          done

      - name: Show staging resources
        run: |
          kubectl get pods -n "$NAMESPACE"
          kubectl get services -n "$NAMESPACE"
          kubectl get pvc -n "$NAMESPACE"


  # =========================================================
  # 5. Smoke test staging
  # =========================================================
  smoke-test-staging:
    name: Staging Smoke Test
    runs-on: ubuntu-latest
    needs:
      - terraform
      - deploy-staging

    environment:
      name: staging

    steps:
      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Get AKS credentials
        run: |
          az aks get-credentials \
            --resource-group "${{ needs.terraform.outputs.resource_group }}" \
            --name "${{ needs.terraform.outputs.aks_cluster_name }}" \
            --admin \
            --overwrite-existing

      - name: Wait for staging frontend IP
        run: |
          for i in {1..30}; do
            FRONTEND_IP=$(kubectl get service frontend -n staging \
              -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
            if [ -n "$FRONTEND_IP" ]; then
              echo "FRONTEND_IP=$FRONTEND_IP" >> "$GITHUB_ENV"
              exit 0
            fi
            echo "Waiting for staging frontend IP..."
            sleep 10
          done
          echo "Unable to find staging frontend IP."
          exit 1

      - name: Test frontend
        run: curl --fail --retry 10 --retry-delay 5 "http://$FRONTEND_IP"


  # =========================================================
  # 6. Deploy to production (same image SHA - never rebuilt)
  # =========================================================
  deploy-production:
    name: Deploy to Production
    runs-on: ubuntu-latest
    needs:
      - terraform
      - smoke-test-staging

    environment:
      name: production

    env:
      NAMESPACE: production
      RESOURCE_GROUP: ${{ needs.terraform.outputs.resource_group }}
      AKS_CLUSTER_NAME: ${{ needs.terraform.outputs.aks_cluster_name }}
      STORAGE_ACCOUNT_NAME: ${{ needs.terraform.outputs.storage_account_name }}
      ACR_LOGIN_SERVER: ${{ needs.terraform.outputs.acr_login_server }}
      IMAGE_TAG: ${{ github.sha }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Get AKS credentials
        run: |
          az aks get-credentials \
            --resource-group "$RESOURCE_GROUP" \
            --name "$AKS_CLUSTER_NAME" \
            --admin \
            --overwrite-existing
          kubectl get nodes

      - name: Create namespace
        run: |
          kubectl create namespace "$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -

      - name: Create Kubernetes secrets
        env:
          POSTGRES_USER: ${{ secrets.POSTGRES_USER }}
          POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
          JWT_SECRET_KEY: ${{ secrets.JWT_SECRET_KEY }}
          DEFAULT_ADMIN_USERNAME: ${{ secrets.DEFAULT_ADMIN_USERNAME }}
          DEFAULT_ADMIN_EMAIL: ${{ secrets.DEFAULT_ADMIN_EMAIL }}
          DEFAULT_ADMIN_PASSWORD: ${{ secrets.DEFAULT_ADMIN_PASSWORD }}
        run: |
          STORAGE_CONN=$(az storage account show-connection-string \
            --resource-group "$RESOURCE_GROUP" \
            --name "$STORAGE_ACCOUNT_NAME" \
            --query connectionString -o tsv)
          echo "::add-mask::$STORAGE_CONN"

          kubectl create secret generic postgres-secret \
            --namespace "$NAMESPACE" \
            --from-literal=POSTGRES_USER="$POSTGRES_USER" \
            --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
            --dry-run=client -o yaml | kubectl apply -f -

          kubectl create secret generic application-secret \
            --namespace "$NAMESPACE" \
            --from-literal=POSTGRES_USER="$POSTGRES_USER" \
            --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
            --from-literal=JWT_SECRET_KEY="$JWT_SECRET_KEY" \
            --from-literal=DEFAULT_ADMIN_USERNAME="$DEFAULT_ADMIN_USERNAME" \
            --from-literal=DEFAULT_ADMIN_EMAIL="$DEFAULT_ADMIN_EMAIL" \
            --from-literal=DEFAULT_ADMIN_PASSWORD="$DEFAULT_ADMIN_PASSWORD" \
            --from-literal=AZURE_STORAGE_CONNECTION_STRING="$STORAGE_CONN" \
            --dry-run=client -o yaml | kubectl apply -f -

      - name: Apply Kubernetes manifests
        run: kubectl apply -f kubernetes/production/

      - name: Update images to the staging-tested commit
        run: |
          for svc in frontend user-service student-service lecturer-service course-service enrollment-service; do
            kubectl set image "deployment/$svc" \
              "$svc=$ACR_LOGIN_SERVER/koalatech-$svc:$IMAGE_TAG" \
              -n "$NAMESPACE"
          done

      - name: Wait for rollouts
        run: |
          for svc in frontend user-service student-service lecturer-service course-service enrollment-service; do
            kubectl rollout status "deployment/$svc" -n "$NAMESPACE" --timeout=300s
          done

      - name: Show production resources
        run: |
          kubectl get pods -n "$NAMESPACE"
          kubectl get services -n "$NAMESPACE"
          kubectl get pvc -n "$NAMESPACE"


  # =========================================================
  # 7. Monitoring - Prometheus & Grafana (kube-prometheus-stack)
  # =========================================================
  # `helm upgrade --install` is idempotent, so running it on every pipeline
  # run is safe: an unchanged release is a no-op upgrade.
  deploy-monitoring:
    name: Deploy Monitoring (Prometheus & Grafana)
    runs-on: ubuntu-latest
    needs:
      - terraform
      - deploy-production

    steps:
      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Get AKS credentials
        run: |
          az aks get-credentials \
            --resource-group "${{ needs.terraform.outputs.resource_group }}" \
            --name "${{ needs.terraform.outputs.aks_cluster_name }}" \
            --admin \
            --overwrite-existing

      - name: Set up Helm
        uses: azure/setup-helm@v4

      - name: Add the Prometheus community Helm repo
        run: |
          helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
          helm repo update

      - name: Install or upgrade kube-prometheus-stack
        run: |
          helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            --create-namespace \
            --wait \
            --timeout 10m0s

      - name: Verify monitoring pods are healthy
        run: |
          kubectl get pods -n monitoring
          kubectl get svc -n monitoring
          kubectl rollout status deployment/prometheus-grafana -n monitoring --timeout=300s
          kubectl rollout status statefulset/prometheus-prometheus-kube-prometheus-prometheus -n monitoring --timeout=300s

      - name: Confirm the production application is still reachable
        run: |
          FRONTEND_IP=$(kubectl get service frontend -n production \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
          echo "Production frontend: http://$FRONTEND_IP"
          curl --fail --retry 10 --retry-delay 5 "http://$FRONTEND_IP"
```

---

## Appendix B — complete `.github/workflows/destroy.yml`

```yaml
name: Destroy Infrastructure

# Tears down everything the `terraform` job in pipeline.yml created, from
# GitHub Actions, using the same remote state and the same OIDC identity.
# Manual only, and the run must be confirmed by typing "destroy".
#
# Left in place on purpose: the `sit722-cicd-bootstrap` resource group
# (pipeline identity + Terraform state storage). Delete that by hand once
# the task is marked (see SETUP-10.2D.md, final step).

on:
  workflow_dispatch:
    inputs:
      confirm:
        description: 'Type "destroy" to delete all Task 10.2D Azure resources'
        required: true
        type: string

permissions:
  id-token: write
  contents: read

concurrency:
  group: koalatech-pipeline-refs/heads/main
  cancel-in-progress: false

env:
  ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
  ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
  ARM_USE_OIDC: "true"

  TFSTATE_RESOURCE_GROUP: sit722-cicd-bootstrap
  TFSTATE_STORAGE_ACCOUNT: kt103528453tfstate
  TFSTATE_CONTAINER: tfstate
  TFSTATE_KEY: week10-2d.terraform.tfstate

  TF_IN_AUTOMATION: "true"
  TF_VAR_location: Australia East
  TF_VAR_resource_group_name: sit722-week10-2d
  TF_VAR_acr_name: kt103528453wk102d
  TF_VAR_storage_account_name: kt103528453wk102dsa
  TF_VAR_aks_cluster_name: aks-sit722-week10-2d
  TF_VAR_aks_dns_prefix: sit722week102d
  TF_VAR_aks_node_count: "3"
  TF_VAR_aks_node_vm_size: Standard_B2s_v2
  TF_VAR_environment: development

jobs:
  terraform-destroy:
    name: Terraform destroy
    runs-on: ubuntu-latest
    if: inputs.confirm == 'destroy'

    defaults:
      run:
        working-directory: terraform

    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Set up Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"

      - name: Terraform init (Azure Blob remote state)
        run: |
          terraform init -input=false \
            -backend-config="resource_group_name=$TFSTATE_RESOURCE_GROUP" \
            -backend-config="storage_account_name=$TFSTATE_STORAGE_ACCOUNT" \
            -backend-config="container_name=$TFSTATE_CONTAINER" \
            -backend-config="key=$TFSTATE_KEY"

      - name: Terraform destroy
        run: terraform destroy -input=false -auto-approve

      - name: Confirm the resource group is gone
        run: |
          if az group exists --name "$TF_VAR_resource_group_name" | grep -q true; then
            echo "Resource group $TF_VAR_resource_group_name still exists"
            exit 1
          fi
          echo "Resource group $TF_VAR_resource_group_name deleted."
```
