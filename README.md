# terraform-aws-pontem-control

Terraform for running the Pontem control plane in your own AWS account.

> **Pontem-internal note — this repo is not customer-readable yet.** It is
> private, and `terraform init` against a source a customer cannot read fails.
> Do not send anyone here until the repo is public and licensed.

Terraform creates AWS resources and renders `helm_values`. One Helm release owns
the controllers, application Secret, ingress resources, and workloads inside the
cluster. Terraform does not use Kubernetes, Helm, kubectl, or local-exec
providers or resources.

## What it creates

- A dedicated VPC with public and private subnets in two availability zones.
- An EKS Auto Mode cluster.
- A private, Multi-AZ RDS Postgres instance.
- Secrets Manager secrets for the database password and device JWT signing key.
- An ACM certificate for `app_domain_name`.
- EKS Pod Identity roles for the control-plane pods and External Secrets
  Operator.
- When `route53_zone_id` is set, an ExternalDNS Pod Identity role limited to that
  hosted zone and `app_domain_name`.

The Helm release installs External Secrets Operator, creates the application
Secret from the two Secrets Manager secrets, and creates the `alb` IngressClass.
When `route53_zone_id` is set, it also installs ExternalDNS for the application
hostname.

## Limits

- Device metrics and logs are unavailable. Devices can enroll, receive
  configuration, and report status.
- Tenant file endpoints return 503.
- Membership invite emails require a `RESEND_API_KEY` key in the application
  Secret.

## Requirements

- Terraform >= 1.6.
- AWS credentials that can create IAM, VPC, EKS, RDS, ACM, Secrets Manager, and
  optional Route53 resources.
- AWS CLI, kubectl, and Helm 3.
- A region that offers EKS Auto Mode.
- From Pontem: a `gcp.wifAudience`, access to the distribution registry, and a
  released chart version.

## Configure

See [`examples/complete`](examples/complete) for a complete root module.

```hcl
module "pontem_control" {
  source = "github.com/pontemai/terraform-aws-pontem-control"

  app_domain_name = "pontem.example.com"

  cluster_admin_principal_arns = [
    "arn:aws:iam::123456789012:role/YourAdminRole",
  ]
  cluster_endpoint_public_access_cidrs = [
    "203.0.113.0/24",
  ]

  oidc_issuer    = "https://example.us.auth0.com/"
  oidc_audience  = "https://pontem.example.com"
  oidc_client_id = "YourOidcSpaClientId"

  # Optional: enables automatic ACM validation and application DNS.
  route53_zone_id = "Z0123456789ABCDEFGHIJ"
}
```

`cluster_admin_principal_arns` is the only path to the Kubernetes API. Use IAM
role or user ARNs, not the `arn:aws:sts::...:assumed-role/...` value printed by
`aws sts get-caller-identity`.

Terraform state contains the database password and device JWT signing key.

## Deploy

### 1. Apply Terraform

```bash
terraform init
terraform apply
```

The EKS cluster and RDS instance usually take 20 to 30 minutes to create.

If `route53_zone_id = null`, create the DNS validation record returned here:

```bash
terraform output acm_validation_records
```

Wait for the certificate to become `ISSUED` before installing the chart:

```bash
aws acm describe-certificate \
  --certificate-arn "$(terraform output -raw acm_certificate_arn)" \
  --query 'Certificate.Status'
```

When `route53_zone_id` is set, Terraform creates the validation record and the
apply waits for the certificate.

### 2. Register workload identity and re-apply

Send these values to Pontem:

```bash
terraform output -raw aws_account_id
terraform output -raw cp_runtime_assumed_role_arn
```

Set the returned audience as `wif_audience` in the root module, then update the
rendered Helm values:

```bash
terraform apply
```

The default `REPLACE_ME_PONTEM_SUPPLIED` value allows installation, but managed
package pulls fail until it is replaced.

### 3. Configure kubeconfig

```bash
$(terraform output -raw update_kubeconfig_command)
kubectl get namespaces
```

`Unauthorized` means the current AWS identity is absent from
`cluster_admin_principal_arns`.

### 4. Install the pinned chart release

```bash
terraform output -raw helm_values > values.yaml

helm upgrade --install pontem-control \
  oci://415039713698.dkr.ecr.us-east-1.amazonaws.com/pontem/charts/pontem-control \
  --version "<version-from-pontem>" \
  --namespace "$(terraform output -raw namespace)" \
  --create-namespace \
  --values values.yaml \
  --wait --timeout 10m
```

The chart version selects the matching control-plane and admin image tags.
`--wait` covers controller and application workload readiness. ALB provisioning,
DNS propagation, HTTP health, and browser sign-in complete afterward.

### 5. Verify the deployment

```bash
kubectl get externalsecret pontem-control \
  --namespace "$(terraform output -raw namespace)"
kubectl get ingress \
  --namespace "$(terraform output -raw namespace)"
```

The ExternalSecret should report `SecretSynced`. Wait for the Ingress to show an
address.

When `route53_zone_id` is set, ExternalDNS creates the application record and its
TXT ownership record. When `route53_zone_id = null`, create a DNS record for
`app_domain_name` pointing to the Ingress address.

After DNS resolves:

```bash
curl "$(terraform output -raw app_url)/health"
```

Open `app_url` in a browser to verify the admin sign-in flow; the API health
endpoint does not exercise the admin container or OIDC configuration.

## Day two

**Kubernetes upgrades.** Raise `kubernetes_version` and apply. EKS may
automatically move a cluster beyond the configured version after standard support
ends. Check the running version with:

```bash
aws eks describe-cluster --name "$(terraform output -raw cluster_name)" \
  --query 'cluster.version'
```

**Changing the hostname.** Change `app_domain_name`, apply Terraform, regenerate
`values.yaml`, and run the pinned Helm command again. If
`route53_zone_id = null`, update both manual DNS records.

**Inputs that replace data-bearing resources.** Changing `name_prefix` replaces
the cluster and database. Changing `db_name` or `db_user` replaces the database.
Changing `vpc_cidr` replaces the VPC and its contents.

**Device JWT signing key.** Replacing it invalidates enrolled-device JWTs; those
devices must re-enroll.

## Troubleshooting

**`terraform apply` reports `ResourceInUseException` for
`aws_eks_access_entry.auto_node`.** Import the access resources created by EKS:

```bash
terraform import 'aws_eks_access_entry.auto_node' \
  '<cluster-name>:<node-role-arn>'
terraform import 'aws_eks_access_policy_association.auto_node' \
  '<cluster-name>#<node-role-arn>#arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy'
```

**The ExternalSecret does not report `SecretSynced`.** Confirm the release uses
the namespace from `terraform output -raw namespace`; the External Secrets
Operator Pod Identity association is bound to that namespace and the
`external-secrets` ServiceAccount.

**The Ingress never gets an address.** Confirm the ACM certificate is `ISSUED`.

**The admin UI is blank.** Inspect the browser console and the rendered config:

```bash
kubectl exec --namespace "$(terraform output -raw namespace)" \
  deploy/pontem-control-admin -- \
  cat /usr/share/nginx/html/admin/config.js
```

**The site returns 502 while pods are ready.** The ALB target groups use `/health`
for the API and `/healthz` for the admin service.

**Tenant secret operations return 500 with `AccessDenied`.** The chart namespace
must match the Pod Identity associations in `namespace`; the API and worker use
ServiceAccounts named `api` and `worker`.

**Pods cannot reach the database.** The database admits connections only from the
EKS cluster security group.

## Destroy

Delete the Ingress while ExternalDNS is still running:

```bash
kubectl delete ingress pontem-control \
  --namespace "$(terraform output -raw namespace)"
```

When `route53_zone_id` is set, wait until both the application record and its TXT
ownership record are gone from Route53. When it is null, remove the manual DNS
record. Then uninstall Helm:

```bash
helm uninstall pontem-control \
  --namespace "$(terraform output -raw namespace)" \
  --wait
```

Set `db_deletion_protection = false`, apply that change, then destroy Terraform:

```bash
terraform apply
terraform destroy
```

RDS takes a final snapshot named `<name_prefix>-final`. A later destroy using the
same name fails until that snapshot is renamed or deleted. Secrets Manager keeps
deleted names reserved for `secret_recovery_window_days`; use `0` for stacks that
must be recreated immediately.

## Development

```bash
make check   # fmt, validate, tflint, terraform-docs drift, tests
make test    # terraform test only
make docs    # regenerate the input/output tables in these READMEs
```

Contributing requires Terraform 1.8 or newer because the tests use provider mocks
and `strcontains`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6.0 |
| aws | ~> 6.0 |
| random | ~> 3.6 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.57.1 |
| random | 3.9.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_cloudwatch_log_group.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_db_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_eks_access_entry.admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_entry.auto_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_eks_access_policy_association.auto_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_eks_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_pod_identity_association.cp_runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.eso](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.external_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.auto_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cp_runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.eso](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.external_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cp_runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.eso](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.external_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.auto_node_ecr_pull](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.auto_node_minimal](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.cluster_block_storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.cluster_compute](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.cluster_eks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.cluster_load_balancing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.cluster_networking](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route53_record.acm_validation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_secretsmanager_secret.db_password](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.device_jwt_signing_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.db_password](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_secretsmanager_secret_version.device_jwt_signing_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.db](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [random_id.device_jwt_signing_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_password.db](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.cluster_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cp_runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.node_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.pod_identity_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| app\_domain\_name | Hostname the control plane is served at, e.g. "pontem.example.com". The ACM certificate covers exactly this name, and it becomes the chart's ingress.domain. Changing it replaces the certificate and nothing else; the old certificate stays attached until the new one is issued. | `string` | n/a | yes |
| cluster\_admin\_principal\_arns | IAM principal ARNs granted cluster-admin on the EKS cluster. This is the ONLY path to the Kubernetes API: a principal absent from this list cannot run kubectl no matter what IAM permissions it holds, including the one that created the cluster. Include the principal that will run the install steps, or the install cannot proceed. | `list(string)` | n/a | yes |
| cluster\_endpoint\_public\_access\_cidrs | CIDRs allowed to reach the public EKS API endpoint. Anything outside them cannot reach the Kubernetes API at all; the endpoint is also IAM-gated independently of this list. ["0.0.0.0/0"] allows every source. | `list(string)` | n/a | yes |
| oidc\_audience | OIDC API audience the control plane validates access tokens against, and that the admin app requests tokens for. These must be the same value or the API rejects every token the UI sends. | `string` | n/a | yes |
| oidc\_client\_id | Client ID of the public single-page-app client the admin UI signs in with. Used only by the browser; the API never sees it. Without it the admin UI renders a blank page while every pod reports healthy. | `string` | n/a | yes |
| oidc\_issuer | OIDC issuer URL, e.g. "https://your-tenant.us.auth0.com/". Must be a bare https origin with no path: the admin app is configured with the host on its own, which this module derives by stripping the scheme, so an issuer with a path cannot be expressed there. | `string` | n/a | yes |
| availability\_zone\_count | How many availability zones to spread subnets across. Two is the floor: EKS requires its control-plane subnets in at least two AZs, and so does the RDS subnet group even for a single-AZ instance. Raising it appends a subnet, NAT gateway, and route table per new zone and leaves the existing ones alone; lowering it destroys the highest-numbered zone's subnets and anything running in them. | `number` | `2` | no |
| cloudwatch\_log\_retention\_days | Retention for the EKS control-plane log group, which collects the api, audit, and authenticator logs. 0 keeps them forever. | `number` | `90` | no |
| db\_allocated\_storage | Initial RDS storage in GiB. Storage autoscaling is on (see db\_max\_allocated\_storage), so this is a starting point, not a ceiling. | `number` | `20` | no |
| db\_backup\_retention\_period | Days of automated RDS backups. Also the window for point-in-time recovery, which is the only thing that recovers from a bad migration or a mistaken delete. Zero disables backups entirely. | `number` | `14` | no |
| db\_deletion\_protection | Refuse to delete the database instance. While true, `terraform destroy` fails until it is set false and applied. | `bool` | `true` | no |
| db\_engine\_version | RDS Postgres MAJOR version. Major-only on purpose: RDS then owns the minor and patches it, whereas pinning a minor fights auto\_minor\_version\_upgrade and eventually plans an impossible downgrade. | `string` | `"18"` | no |
| db\_instance\_class | RDS instance class. Changing it is an in-place modification with a short failover, not a replacement. | `string` | `"db.t4g.medium"` | no |
| db\_max\_allocated\_storage | Ceiling for RDS storage autoscaling, in GiB. Must exceed db\_allocated\_storage or autoscaling is effectively off. | `number` | `200` | no |
| db\_multi\_az | Run the database as a Multi-AZ deployment with a synchronous standby. Roughly doubles the instance cost. False turns an AZ failure into an outage plus a restore from backup; the database is the control plane's only durable store. | `bool` | `true` | no |
| db\_name | Application database name inside the instance. CHANGING THIS REPLACES THE DATABASE INSTANCE and destroys its data. | `string` | `"pontem"` | no |
| db\_user | Postgres user the application authenticates as. This is the instance's master user, so it is created with the instance; CHANGING IT REPLACES THE DATABASE. | `string` | `"app"` | no |
| kubernetes\_version | EKS Kubernetes version. Must be >= 1.30: the pontem-control chart uses the native preStop sleep action, which does not exist before 1.30. The cluster's upgrade policy is STANDARD, so AWS auto-upgrades a version once it leaves standard support — after that happens, this must be raised to the version the cluster is actually on or every apply fails proposing a downgrade. | `string` | `"1.36"` | no |
| name\_prefix | Prefix for every resource name this module creates. CHANGING THIS REPLACES THE CLUSTER AND THE DATABASE, destroying the data in them. Two stacks in one account need different prefixes. | `string` | `"pontem-control"` | no |
| namespace | Kubernetes namespace the chart is installed into. The Pod Identity associations bind service accounts in this namespace, so it must match the namespace you pass to `helm install`; if they drift, the pods start but get no AWS credentials. | `string` | `"pontem-control"` | no |
| pod\_identity\_service\_accounts | Service accounts in `namespace` bound to the control-plane runtime role. The chart's api and worker pods both need AWS credentials for tenant-secret storage. Add "mcp" only if you enable the mcp deployment (it is off unless you set mcp.host in the chart). | `list(string)` | <pre>[<br/>  "api",<br/>  "worker"<br/>]</pre> | no |
| route53\_zone\_id | Route53 hosted zone ID for app\_domain\_name. Set it to automate ACM validation and enable ExternalDNS with a Pod Identity role scoped to this zone and hostname. Leave it null to disable ExternalDNS and emit acm\_validation\_records for you to create wherever your DNS lives. | `string` | `null` | no |
| secret\_recovery\_window\_days | Days a deleted secret stays recoverable. AWS keeps the deleted secret's NAME reserved for this long and rejects re-creating it, so `terraform destroy` followed by a fresh apply fails with "already scheduled for deletion" until the window expires. 0 deletes immediately, which makes repeated build-and-tear-down cycles work. | `number` | `30` | no |
| single\_nat\_gateway | Route all private-subnet egress through one NAT gateway instead of one per AZ. True saves roughly $33/month per AZ dropped, and makes outbound traffic from every AZ depend on the one NAT gateway's AZ staying up. | `bool` | `false` | no |
| tags | Extra tags merged onto every resource this module creates, on top of its own Project/ManagedBy tags. | `map(string)` | `{}` | no |
| vpc\_cidr | CIDR block for the dedicated VPC. It is carved into one public and one private subnet per availability zone, each four bits narrower than this block — /20 subnets out of the default /16. CHANGING THIS REPLACES THE VPC and everything inside it, including the cluster and the database. | `string` | `"10.0.0.0/16"` | no |
| wif\_audience | GCP Workload Identity Federation audience, which Pontem issues once it has your account id and the control-plane runtime role ARN (both are outputs of this module). Until you set it, the rendered chart values carry the placeholder below; the chart rejects only an EMPTY audience, so an install that keeps the placeholder succeeds and then fails the first time a managed agent package is pulled. | `string` | `"REPLACE_ME_PONTEM_SUPPLIED"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| acm\_certificate\_arn | ACM certificate ARN for app\_domain\_name. When route53\_zone\_id is set, reading this output implies the certificate is ISSUED. |
| acm\_validation\_records | DNS validation records to create when route53\_zone\_id is null, keyed by domain name. The certificate stays PENDING\_VALIDATION — and the ALB will never finish attaching it — until these resolve. Empty when the module created them itself. |
| app\_url | Where the control plane will answer once the chart is installed and DNS points app\_domain\_name at the ALB. |
| aws\_account\_id | Account these resources were created in. Pontem pins the federation to this account as well as to the role below, so send both. |
| aws\_region | Region these resources were created in, read from the provider. Needed by the External Secrets Operator store, which names its region explicitly. |
| cluster\_name | EKS cluster name, which aws eks commands take and which equals name\_prefix. |
| cp\_runtime\_assumed\_role\_arn | Send this to Pontem with aws\_account\_id to get your wif\_audience. It is the session-stripped assumed-role form (arn:aws:sts::<account>:assumed-role/<role>), which is what GCP Workload Identity Federation exposes as the role attribute and what its trust condition matches; the arn:aws:iam::...:role/... form of the same role does not match, and the federation denies without saying why. |
| db\_endpoint | RDS endpoint hostname, without the port. |
| db\_password\_secret\_name | Secrets Manager name of the database password rendered into helm\_values. |
| device\_jwt\_signing\_key\_secret\_name | Secrets Manager name of the device-JWT signing key rendered into helm\_values. |
| helm\_values | Rendered pontem-control chart values for this deployment. Write it to a file with `terraform output -raw helm_values > values.yaml` and pass it to helm. |
| namespace | Namespace to install the chart into. The Pod Identity associations bind service accounts in this namespace, so `helm install -n` must match it. |
| private\_subnet\_ids | Private subnet IDs. Nodes run here and the RDS subnet group spans them. |
| update\_kubeconfig\_command | Command that points kubectl at this cluster. Only principals listed in cluster\_admin\_principal\_arns can use the resulting context. |
| vpc\_id | ID of the dedicated VPC. The join point for anything else you run in the same network. |
<!-- END_TF_DOCS -->
