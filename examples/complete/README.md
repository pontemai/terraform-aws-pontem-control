# Complete example

A working root module. Copy this directory, change the inputs marked in
[`main.tf`](main.tf), and follow the install steps in the
[repo README](../../README.md).

When you copy the example, replace the relative module `source` with its Git URL
and a tag:

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
| terraform | >= 1.11.0 |
| aws | >= 6.45.0, < 7.0.0 |

## Outputs

| Name | Description |
| ---- | ----------- |
| acm\_certificate\_arn | ACM certificate ARN, for checking issuance status. |
| acm\_validation\_records | DNS records to create when neither Route53 input is set. Empty otherwise. |
| app\_url | Where the control plane will answer once DNS points at the load balancer. |
| aws\_account\_id | Account these resources live in. |
| aws\_region | Region these resources live in. |
| cluster\_name | EKS cluster name. |
| cp\_runtime\_assumed\_role\_arn | Session-stripped assumed-role ARN of the control-plane runtime role. Send this and aws\_account\_id to Pontem. |
| db\_password\_secret\_name | Secrets Manager name of the database password. |
| device\_jwt\_signing\_key\_secret\_name | Secrets Manager name of the device JWT signing key. |
| helm\_values | Chart values for this deployment. |
| namespace | Namespace to install the chart into. |
| route53\_name\_servers | Name servers for a hosted zone created by the module. |
| update\_kubeconfig\_command | Points kubectl at the new cluster. |
<!-- END_TF_DOCS -->
