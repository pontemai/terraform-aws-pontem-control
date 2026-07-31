# chart_values

Renders the pontem-control chart values and the `alb` IngressClass manifest from
the resources the root module created. Not meant to be called directly — the root
module passes its own outputs in.

This is a separate module because it uses no provider. That makes the seam between
this repo and the pontem-control chart the one thing here that can be asserted on
in CI: `terraform test` plans it with no credentials and no network, and the
[tests](tests/render.tftest.hcl) check the rendered output key by key against what
the chart's `values.schema.json` and cross-field guards accept.

`tests/golden_values.yaml` and `tests/golden_ingressclass.yaml` are the rendered
output for the fixture inputs in that test file, and the tests assert against them
byte for byte. A change to a template — including to its comments, which are the
customer's explanation of the values — therefore shows up as a diff of the golden
file in the pull request. Run `make goldens` from the repo root to re-render them.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6.0 |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| acm\_certificate\_arn | ACM certificate ARN for app\_domain\_name, attached by the IngressClassParams rather than by a chart annotation. | `string` | n/a | yes |
| app\_domain\_name | Hostname the control plane is served at; becomes ingress.domain. | `string` | n/a | yes |
| aws\_region | Region the pods run in; becomes aws.region, used by the AWS secrets backend and the GCP federation. | `string` | n/a | yes |
| db\_host | RDS endpoint hostname, no port. | `string` | n/a | yes |
| db\_name | Application database name. | `string` | n/a | yes |
| db\_port | RDS Postgres port. | `number` | n/a | yes |
| db\_user | Application database user. | `string` | n/a | yes |
| oidc\_audience | OIDC API audience, rendered as both auth.oidc.audience (the API's validation) and admin.auth0.audience (what the browser requests tokens for). One value, two consumers — they have to agree. | `string` | n/a | yes |
| oidc\_client\_id | Public SPA client ID, rendered as admin.auth0.clientId. Browser-only. | `string` | n/a | yes |
| oidc\_domain | Identity provider host with no scheme, e.g. "your-tenant.us.auth0.com", rendered as admin.auth0.domain. The admin container rebuilds "https://<host>/" from it, so a scheme here would produce a doubled one. | `string` | n/a | yes |
| oidc\_issuer | OIDC issuer URL, rendered as auth.oidc.issuer for the API's token validation. | `string` | n/a | yes |
| credentials\_secret\_name | Name of the Kubernetes Secret holding the application's secret environment; becomes credentials.existingSecret.name. | `string` | `"pontem-control"` | no |
| wif\_audience | GCP Workload Identity Federation audience, rendered as gcp.wifAudience. Pontem issues this per customer once the AWS account and the control-plane runtime role ARN are known, so the default is a deliberately loud placeholder rather than an empty string — the chart refuses to install with it unset, and a sentinel is easier to spot in a diff than a blank. | `string` | `"REPLACE_ME_PONTEM_SUPPLIED"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| helm\_values | Rendered pontem-control chart values for this deployment. |
| ingress\_class\_manifest | The `alb` IngressClass and its IngressClassParams, as a manifest to apply with kubectl. |
<!-- END_TF_DOCS -->
