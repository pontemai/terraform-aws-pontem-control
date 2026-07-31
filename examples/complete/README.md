# Complete example

A working root module. Copy this directory, change the inputs marked in
[`main.tf`](main.tf), and follow the install steps in the
[repo README](../../README.md).

`main.tf` sources the module by relative path so CI validates this example against
the module in the same commit. Point `source` at the module's Git URL and a tag
when you copy it out:

```hcl
module "pontem_control" {
  source = "github.com/pontemai/terraform-aws-pontem-control?ref=v0.1.0"
  # ...
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6.0 |
| aws | ~> 6.0 |

## Outputs

| Name | Description |
| ---- | ----------- |
| acm\_certificate\_arn | ACM certificate ARN, for checking issuance status. |
| acm\_validation\_records | DNS records to create by hand when route53\_zone\_id is not set. Empty otherwise. |
| app\_url | Where the control plane will answer once DNS points at the load balancer. |
| aws\_account\_id | Account these resources live in. |
| aws\_region | Region these resources live in. |
| cp\_runtime\_assumed\_role\_arn | Session-stripped assumed-role ARN of the control-plane runtime role. Send this and aws\_account\_id to Pontem. |
| db\_password | Database password, for the application Secret. |
| db\_password\_secret\_name | Secrets Manager name of the database password, for the External Secrets path. |
| device\_jwt\_signing\_key | Device JWT signing key, for the application Secret. |
| device\_jwt\_signing\_key\_secret\_name | Secrets Manager name of the device JWT signing key, for the External Secrets path. |
| helm\_values | Chart values for this deployment. |
| ingress\_class\_manifest | The alb IngressClass and its parameters, to apply with kubectl. |
| namespace | Namespace to install the chart into. |
| update\_kubeconfig\_command | Points kubectl at the new cluster. |
<!-- END_TF_DOCS -->
