# chart_values

Renders the pontem-control chart values from resources created by the root module.
It is not meant to be called directly.

This is a separate module because it uses no provider. That makes the seam between
this repo and the pontem-control chart the one thing here that can be asserted on
in CI: `terraform test` plans it with no credentials and no network, and the
[tests](tests/render.tftest.hcl) check the rendered output key by key against what
the chart's `values.schema.json` and cross-field guards accept.

The template in `templates/` is the rendered output, including its operator-facing
comments.

`helm_values` sets `awsTurnkey.enabled: true` and
`externalSecretsOperator.enabled: true`.
`externalDns.enabled` follows `route53_zone_id`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6.0 |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| acm\_certificate\_arn | ACM certificate ARN for app\_domain\_name; becomes awsTurnkey.certificateArn. | `string` | n/a | yes |
| app\_domain\_name | Hostname the control plane is served at; becomes ingress.domain. | `string` | n/a | yes |
| aws\_region | Region the pods run in; becomes aws.region, used by the AWS secrets backend and the GCP federation. | `string` | n/a | yes |
| cluster\_name | Stable EKS cluster name; becomes externalDns.txtOwnerId. | `string` | n/a | yes |
| db\_host | RDS endpoint hostname, no port. | `string` | n/a | yes |
| db\_name | Application database name. | `string` | n/a | yes |
| db\_password\_secret\_name | Secrets Manager name containing DATABASE\_PASSWORD; becomes awsTurnkey.dbPasswordSecretName. | `string` | n/a | yes |
| db\_port | RDS Postgres port. | `number` | n/a | yes |
| db\_user | Application database user. | `string` | n/a | yes |
| device\_jwt\_signing\_key\_secret\_name | Secrets Manager name containing DEVICE\_JWT\_SIGNING\_KEY; becomes awsTurnkey.deviceJwtSigningKeySecretName. | `string` | n/a | yes |
| oidc\_audience | OIDC API audience, rendered as both auth.oidc.audience (the API's validation) and admin.auth0.audience (what the browser requests tokens for). One value, two consumers — they have to agree. | `string` | n/a | yes |
| oidc\_client\_id | Public SPA client ID, rendered as admin.auth0.clientId. Browser-only. | `string` | n/a | yes |
| oidc\_issuer | OIDC issuer URL, rendered as auth.oidc.issuer for the API's token validation. The admin app is configured with the host on its own, which is derived from this. | `string` | n/a | yes |
| wif\_audience | GCP Workload Identity Federation audience, rendered as gcp.wifAudience. | `string` | n/a | yes |
| route53\_zone\_id | Route53 hosted zone ID; becomes externalDns.zoneIdFilters and its effective aws-zone-id-filter argument. Null disables ExternalDNS. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| helm\_values | Rendered pontem-control chart values for this deployment. |
<!-- END_TF_DOCS -->
