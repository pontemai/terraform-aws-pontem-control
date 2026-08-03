# README Refinement Design

## Audience and goal

The reader already uses Terraform and is deploying the Pontem control plane in
their AWS account. The README should explain this module's contract and the
Pontem-specific work required after Terraform finishes, without teaching state
storage or basic Terraform CLI usage.

## Structure

- Keep the deployment scope, unavailable features, created resources, and
  product-specific requirements near the top.
- Replace the current first two install steps with a concise `Usage` section:
  link the complete example, show the required inputs, and explain only the EKS
  access constraint that is easy to get wrong.
- Rename the remaining install sequence `After Terraform applies` and retain the
  certificate, Pontem federation, Kubernetes, Helm, DNS, and verification steps.
- Keep External Secrets Operator, day-two operations, troubleshooting,
  destruction, development, and generated Terraform reference sections below
  the initial deployment path.
- Delete backend configuration guidance, `terraform init` / `terraform apply`
  instructions, and repeated explanations that do not change a Pontem-specific
  action or expectation.

## Scope and verification

Change `README.md` only. Preserve generated Terraform documentation markers and
content. Run `make check` after editing.

After the README change, inspect the post-apply steps against the module and
report which can be automated safely, preferring Terraform resources or outputs
over new scripts. Do not implement that follow-up automation without a separate
approved design.
