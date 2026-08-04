# README Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the README a concise module reference for Terraform users while retaining the Pontem-specific work after apply.

**Architecture:** Change only the hand-written README flow: replace Terraform basics with a copyable module example, then retain and renumber the post-apply procedure. Preserve the generated reference verbatim and assess future automation without implementing it.

**Tech Stack:** Markdown, HCL, Terraform, Make

## Global Constraints

- The reader already uses Terraform.
- Keep the deployment scope, unavailable features, created resources, and requirements near the top.
- Change `README.md` only for the implementation.
- Preserve the Terraform-docs markers and all generated content between them.
- Run `make check` after editing.
- Report automation opportunities after the README commit; do not implement them.

---

### Task 1: Refine the README flow

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: required inputs from `variables.tf` and the existing post-apply commands.
- Produces: `Usage` and `After Terraform applies` sections with valid internal anchors.

- [x] **Step 1: Replace Terraform basics with Usage**

Remove the backend example and basic `terraform init` / `terraform apply` commands. Link `examples/complete`, then add a copyable `module "pontem_control"` block using source `github.com/pontemai/terraform-aws-pontem-control` and all six required inputs: `app_domain_name`, `cluster_admin_principal_arns`, `cluster_endpoint_public_access_cidrs`, `oidc_issuer`, `oidc_audience`, and `oidc_client_id`.

Keep the EKS principal caveat and this deployment expectation:

```text
Creating the EKS cluster and RDS instance usually takes 20 to 30 minutes.
```

- [x] **Step 2: Preserve the Pontem-specific path**

Rename the remaining flow `After Terraform applies`, number its subsections 1 through 6, and retain certificate validation, Pontem federation, Kubernetes setup, Helm installation, DNS, and verification. Update every README anchor to the new numbers, and leave ESO, day-two operations, troubleshooting, destruction, and development in place.

- [x] **Step 3: Verify and commit**

Run:

```bash
make check
git diff --check
sed -n '/<!-- BEGIN_TF_DOCS -->/,/<!-- END_TF_DOCS -->/p' README.md | shasum -a 256
```

Expected: all validation, lint, generated-doc checks, 23 root tests, and 4 chart-values tests pass; the generated block hash remains `06d15acacc14fd9cd5f16429f46e548ed28ee5c4fe671c112cac9fcdb187f41f`.

Commit:

```bash
git add README.md
git commit -m "docs: refine README usage flow"
```

### Task 2: Assess follow-up automation

**Files:**
- Inspect: `README.md`, `acm.tf`, `eks.tf`, `identity.tf`, `outputs.tf`, `versions.tf`, and `modules/chart_values/`

**Interfaces:**
- Consumes: the six post-apply actions and their current Terraform resources or outputs.
- Produces: a prioritized read-only assessment; no repository changes.

- [x] **Step 1: Classify each action**

Identify what Terraform already manages, what belongs in a caller-owned Kubernetes/Helm layer, and what must remain external because it requires Pontem coordination, DNS outside Route53, or browser validation.

- [x] **Step 2: Report the smallest safe follow-ups**

Prefer native Terraform resources and existing outputs over scripts. State the provider-lifecycle boundary that keeps Kubernetes and Helm resources out of this AWS module, then confirm the worktree is clean.
