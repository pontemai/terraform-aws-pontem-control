# terraform-aws-pontem-control

Terraform for running the Pontem control plane in your own AWS account.

> **Pontem-internal note — this repo is not customer-readable yet.** It is
> private, and `terraform init` against a source a customer cannot read fails.
> Do not send anyone here until the repo is public and licensed.

One module creates everything the control plane needs and emits the chart values
and manifests to install onto it. It does not share a VPC, cluster, or database
with anything else in the account.

## What this deployment does not do

Three features are unavailable in a self-hosted AWS deployment:

- **No device metrics or logs.** The device metrics and logs endpoints, heartbeat
  publishing, and the device logging-token broker are all off. Devices enroll,
  receive configuration, and report status; their telemetry has nowhere to go.
- **No tenant file storage.** The file endpoints answer 503.
- **No membership invite emails**, unless you add a `RESEND_API_KEY` key to the
  application Secret yourself.

## What it creates

- A VPC with public and private subnets in two availability zones, an internet
  gateway, and one NAT gateway per AZ.
- An EKS cluster in Auto Mode. AWS runs the nodes, the ALB ingress controller,
  EBS storage, and the Pod Identity agent.
- An RDS Postgres instance, Multi-AZ, reachable only from the cluster.
- Two Secrets Manager secrets: the database password and the device JWT signing
  key.
- An ACM certificate for your hostname.
- Two IAM roles assumed through EKS Pod Identity: one for the control-plane pods,
  one for External Secrets Operator.

Two objects inside the cluster are not created by Terraform: the application's
Secret and the `alb` IngressClass. Both come out as Terraform outputs that you
apply with `kubectl` in [the Kubernetes bootstrap
step](#4-create-the-namespace-the-secret-and-the-ingressclass).

## Requirements

- Terraform >= 1.6.
- AWS credentials for an account where you can create IAM roles, VPCs, EKS
  clusters, and RDS instances.
- `kubectl` and `helm` 3.
- The AWS CLI, which `kubectl` calls to get a cluster token.
- A region that offers EKS Auto Mode. The cluster create fails if yours does not.
- From Pontem: a `gcp.wifAudience` value, and access to the container images and
  the chart. See [Send Pontem two values](#2-send-pontem-two-values) and [Install
  the chart](#5-install-the-chart).

## Usage

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

  oidc_issuer    = "https://your-tenant.us.auth0.com/"
  oidc_audience  = "https://pontem.example.com"
  oidc_client_id = "YourAuth0SpaClientId"
}
```

`cluster_admin_principal_arns` is the only path to the Kubernetes API. Include
the IAM role or user that will run the post-apply steps. EKS rejects the
`arn:aws:sts::…:assumed-role/…` form printed by
`aws sts get-caller-identity`.

Terraform state contains the database password and device JWT signing key.

Creating the EKS cluster and RDS instance usually takes 20 to 30 minutes.

## After Terraform applies

### 1. Validate the certificate

Skip this if you set `route53_zone_id` — the apply already created the validation
record and waited for the certificate.

```bash
terraform output acm_validation_records
```

Create that record in your DNS. Do it now rather than later: the certificate stays
in `PENDING_VALIDATION` until the record resolves, and the load balancer in
[Install the chart](#5-install-the-chart) will not finish starting without an
issued certificate. Validation usually completes within minutes of the record
going live.

```bash
aws acm describe-certificate \
  --certificate-arn "$(terraform output -raw acm_certificate_arn)" \
  --query 'Certificate.Status'
```

### 2. Send Pontem two values

```bash
terraform output -raw aws_account_id
terraform output -raw cp_runtime_assumed_role_arn
```

Pontem returns an audience string that authorizes these pods to pull published
agent packages. Set it as `wif_audience` in your root module and apply again.

Nothing downstream checks that you did: the chart rejects only an *empty*
audience, so leaving the default placeholder in place installs cleanly and then
fails the first time a managed package is pulled.

### 3. Point kubectl at the cluster

```bash
$(terraform output -raw update_kubeconfig_command)
kubectl get namespaces
```

`Unauthorized` here means the identity you are using is not in
`cluster_admin_principal_arns`. Add it and apply.

### 4. Create the namespace, the Secret, and the IngressClass

```bash
kubectl create namespace "$(terraform output -raw namespace)"

kubectl create secret generic pontem-control \
  --namespace "$(terraform output -raw namespace)" \
  --from-literal=DATABASE_PASSWORD="$(terraform output -raw db_password)" \
  --from-literal=DEVICE_JWT_SIGNING_KEY="$(terraform output -raw device_jwt_signing_key)"

terraform output -raw ingress_class_manifest | kubectl apply -f -
```

To have External Secrets Operator maintain the Secret instead of creating it by
hand, see [Delivering the secrets with ESO](#delivering-the-secrets-with-eso).

### 5. Install the chart

```bash
terraform output -raw helm_values > values.yaml
```

Every value is filled in. If `gcp.wifAudience` still reads
`REPLACE_ME_PONTEM_SUPPLIED`, return to [Send Pontem two
values](#2-send-pontem-two-values).

```bash
helm upgrade --install pontem-control <chart-reference-from-pontem> \
  --namespace "$(terraform output -raw namespace)" \
  -f values.yaml \
  --set image.repository=<image-repository-from-pontem> \
  --set image.tag=<tag> \
  --set admin.image.repository=<admin-image-repository-from-pontem> \
  --set admin.image.tag=<tag> \
  --wait --timeout 10m
```

Pontem supplies the chart reference, the two image repositories, and the tag.

### 6. Point DNS at the load balancer

```bash
kubectl get ingress -n "$(terraform output -raw namespace)"
```

Create a CNAME from your hostname to the `ADDRESS` shown. If your DNS provider
proxies traffic — Cloudflare's orange cloud, for example — turn that off for this
record; TLS terminates at the load balancer with the ACM certificate.

```bash
curl "$(terraform output -raw app_url)/health"
```

Then open `$(terraform output -raw app_url)` and sign in. `/health` answering does
not prove the admin UI works — it is a separate container with its own
configuration, and a browser is the only thing that exercises it.

## Delivering the secrets with ESO

External Secrets Operator reads the two secrets from Secrets Manager and keeps the
Kubernetes Secret in sync, instead of [creating it
directly](#4-create-the-namespace-the-secret-and-the-ingressclass). The IAM role
and Pod Identity association it needs already exist unless you set
`enable_external_secrets_iam = false`.

Install the operator:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --version 2.8.0 \
  --set serviceAccount.name=external-secrets \
  --wait
```

The 2.x line serves the `external-secrets.io/v1` API the manifests below use.

Keep the service account name and namespace as above. The Pod Identity
association binds those exact names, and under any others the controller gets no
AWS credentials.

Then apply the store and the secret:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: $(terraform output -raw aws_region)
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: pontem-control
  namespace: $(terraform output -raw namespace)
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: pontem-control
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_PASSWORD
      remoteRef:
        key: $(terraform output -raw db_password_secret_name)
    - secretKey: DEVICE_JWT_SIGNING_KEY
      remoteRef:
        key: $(terraform output -raw device_jwt_signing_key_secret_name)
EOF
```

## Day two

**Kubernetes upgrades.** Raise `kubernetes_version` and apply. The cluster's
support type is `STANDARD`, so a version that leaves standard support is upgraded
by AWS rather than billed at the extended-support rate. When AWS does that, the
cluster is running a newer version than your configuration names, and the next
plan proposes a downgrade that the API rejects — every apply fails until you raise
`kubernetes_version` to what the cluster is actually on:

```bash
aws eks describe-cluster --name "$(terraform output -raw cluster_name)" \
  --query 'cluster.version'
```

**Changing the hostname.** Change `app_domain_name` and apply. A new certificate
is issued before the old one is removed. Re-run [Install the
chart](#5-install-the-chart) for the new name, and re-render `values.yaml` so
`ingress.domain` matches.

**Inputs that destroy data.** `name_prefix` replaces the cluster and the database.
`db_name` and `db_user` replace the database. `vpc_cidr` replaces the VPC and
everything in it. Raising `availability_zone_count` appends a subnet, NAT gateway,
and route table per new zone and leaves the existing ones alone; lowering it
destroys the highest-numbered zone's subnets.

**The device JWT signing key.** Every enrolled device holds a JWT signed with it.
Replacing the value in Secrets Manager invalidates all of them, and the devices
have to re-enroll.

## Troubleshooting

**`terraform apply` fails with `ResourceInUseException` on
`aws_eks_access_entry.auto_node`.** EKS created the node access entry itself while
enabling Auto Mode. Import it rather than retrying:

```bash
terraform import 'aws_eks_access_entry.auto_node' \
  '<cluster-name>:<node-role-arn>'
terraform import 'aws_eks_access_policy_association.auto_node' \
  '<cluster-name>#<node-role-arn>#arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy'
```

**`kubectl` returns `Unauthorized`.** The identity you are using is not in
`cluster_admin_principal_arns`. Add it and apply. Check what you are actually
using with `aws sts get-caller-identity`, and add the underlying role ARN, not the
`assumed-role` form it prints.

**The Ingress never gets an `ADDRESS`.** Most often the certificate from [Validate
the certificate](#1-validate-the-certificate) is not `ISSUED` yet — check it with
the command there.

**The admin UI loads a blank page.** Its configuration is missing or wrong. The
browser console shows `oidc mode requires ...`. Check what reached the container:

```bash
kubectl exec -n "$(terraform output -raw namespace)" deploy/pontem-control-admin \
  -- cat /usr/share/nginx/html/admin/config.js
```

Empty `oidcClientId` means `oidc_client_id` did not make it into `values.yaml`. A
doubled scheme in `oidcIssuer` means `oidc_issuer` carried something other than a
bare `https://host/`.

**Pods run but the site returns 502.** The load balancer's health checks are
failing. The chart values set `/health` for the api and `/healthz` for the admin
UI; the default `/` is not served by either. Confirm those survived any edits to
`values.yaml`.

**Tenant secret operations return 500 with `AccessDenied` in the logs.** The Pod
Identity association does not match where the chart is installed. The associations
bind the service accounts `api` and `worker` in the namespace given by
`namespace`; `helm install --namespace` must use the same one.

**Pods cannot reach the database.** The database admits only the cluster's
security group, so moving the pods to another cluster or VPC breaks it.

## Destroying

Delete the Ingress first:

```bash
kubectl delete ingress --all -n "$(terraform output -raw namespace)"
```

It creates a load balancer Terraform does not know about, and AWS will not delete
the VPC's subnets while that load balancer holds network interfaces in them.

Then set `db_deletion_protection = false` and apply, since `terraform destroy`
fails against a protected instance. A final snapshot named `<name_prefix>-final`
is taken on delete. Tearing the stack down a second time in the same account
fails until that snapshot is deleted or renamed, because RDS rejects a final
snapshot identifier that already exists.

Secrets Manager reserves a deleted secret's name for
`secret_recovery_window_days` (30 by default) and rejects re-creating it, so
applying again inside that window fails on the secret names. Set
`secret_recovery_window_days = 0` if you are building and tearing this down
repeatedly.

## Development

```bash
make check   # fmt, validate, tflint, terraform-docs drift, tests
make test    # terraform test only
make docs    # regenerate the input/output tables in these READMEs
```

Contributing needs Terraform 1.8 or newer, above the 1.6 the module itself
requires: the tests use `mock_provider` (1.7) and `strcontains` (1.8).

The tests use a mocked AWS provider and need no credentials.
[`modules/chart_values`](modules/chart_values) holds the chart values and manifest
rendering, split out so its tests can plan without a provider at all and assert on
the rendered output directly.

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
| [aws_iam_role.auto_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cp_runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.eso](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cp_runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.eso](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
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
| [aws_iam_policy_document.cp_runtime_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.eso](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.eso_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.node_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
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
| enable\_external\_secrets\_iam | Create the IAM role and Pod Identity association that let External Secrets Operator read the two secrets this module creates, as an alternative to creating the Kubernetes Secret by hand. Both paths are in the README. If ESO is never installed, the role and association have no effect. | `bool` | `true` | no |
| kubernetes\_version | EKS Kubernetes version. Must be >= 1.30: the pontem-control chart uses the native preStop sleep action, which does not exist before 1.30. The cluster's upgrade policy is STANDARD, so AWS auto-upgrades a version once it leaves standard support — after that happens, this must be raised to the version the cluster is actually on or every apply fails proposing a downgrade. | `string` | `"1.36"` | no |
| name\_prefix | Prefix for every resource name this module creates. CHANGING THIS REPLACES THE CLUSTER AND THE DATABASE, destroying the data in them. Two stacks in one account need different prefixes. | `string` | `"pontem-control"` | no |
| namespace | Kubernetes namespace the chart is installed into. The Pod Identity associations bind service accounts in this namespace, so it must match the namespace you pass to `helm install`; if they drift, the pods start but get no AWS credentials. | `string` | `"pontem-control"` | no |
| pod\_identity\_service\_accounts | Service accounts in `namespace` bound to the control-plane runtime role. The chart's api and worker pods both need AWS credentials for tenant-secret storage. Add "mcp" only if you enable the mcp deployment (it is off unless you set mcp.host in the chart). | `list(string)` | <pre>[<br/>  "api",<br/>  "worker"<br/>]</pre> | no |
| route53\_zone\_id | Route53 hosted zone ID for app\_domain\_name. Set it and the module creates the ACM validation records and waits for the certificate to be issued. Leave it null and the records are emitted as the acm\_validation\_records output for you to create wherever your DNS lives; no waiter is added in that case, because a waiter would block every future apply on a manual step. | `string` | `null` | no |
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
| db\_password | Generated RDS password, also stored in Secrets Manager under db\_password\_secret\_name. Emitted here so the install can create the Kubernetes Secret without a round trip through the AWS console. |
| db\_password\_secret\_name | Secrets Manager name of the database password. External Secrets refers to secrets by name, not ARN. |
| device\_jwt\_signing\_key | Generated device-JWT signing key, standard base64 of 32 bytes. ROTATING THIS INVALIDATES EVERY ENROLLED DEVICE'S JWT. |
| device\_jwt\_signing\_key\_secret\_name | Secrets Manager name of the device-JWT signing key. External Secrets refers to secrets by name, not ARN. |
| helm\_values | Rendered pontem-control chart values for this deployment. Write it to a file with `terraform output -raw helm_values > values.yaml` and pass it to helm. |
| ingress\_class\_manifest | The `alb` IngressClass and its IngressClassParams. Apply with `terraform output -raw ingress_class_manifest | kubectl apply -f -`. |
| namespace | Namespace to install the chart into. The Pod Identity associations bind service accounts in this namespace, so `helm install -n` must match it. |
| private\_subnet\_ids | Private subnet IDs. Nodes run here and the RDS subnet group spans them. |
| update\_kubeconfig\_command | Command that points kubectl at this cluster. Only principals listed in cluster\_admin\_principal\_arns can use the resulting context. |
| vpc\_id | ID of the dedicated VPC. The join point for anything else you run in the same network. |
<!-- END_TF_DOCS -->
