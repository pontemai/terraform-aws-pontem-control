# terraform-aws-pontem-control

Terraform for running the Pontem control plane in your own AWS account.

> **Pontem-internal note — this repo is not customer-readable yet.** It is
> private, and `terraform init` against a source a customer cannot read fails.
> Do not send anyone here until the repo is public and licensed.

One module creates everything the control plane needs and emits the chart values
and manifests to install onto it. It does not share a VPC, cluster, or database
with anything else in the account.

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

Terraform stops at the edge of the cluster. The two in-cluster objects — the
application's Secret and the `alb` IngressClass — are emitted as outputs you
apply with `kubectl`, so this stack never needs Kubernetes credentials.

## Requirements

- Terraform >= 1.6.
- AWS credentials for an account where you can create IAM roles, VPCs, EKS
  clusters, and RDS instances.
- `kubectl` and `helm` 3.
- The AWS CLI, which `kubectl` calls to get a cluster token.
- A region that offers EKS Auto Mode. Not every region does, and the cluster
  create fails if yours doesn't.
- From Pontem: a `gcp.wifAudience` value, and access to the container images and
  the chart. Steps 3 and 6 cover when you need each.

## Cost

At the defaults, in `us-east-1`, expect roughly **$400/month** before data
transfer: the EKS control plane (~$73), two nodes with the Auto Mode management
fee (~$135), two NAT gateways (~$66), Multi-AZ RDS on `db.t4g.medium` (~$100), a
load balancer (~$16), and small change for secrets and logs. Other regions
differ; the [AWS pricing calculator](https://calculator.aws) gives exact numbers.

Two inputs account for most of it. `single_nat_gateway = true` drops one NAT
gateway (~$33/month) and makes both AZs' outbound traffic depend on one AZ.
`db_multi_az = false` roughly halves the database cost and turns an AZ failure
into an outage plus a restore from backup.

## Install

### 1. Write your root module

Copy [`examples/complete`](examples/complete), which lists what to change. The
required inputs:

| Input | What it is |
|---|---|
| `app_domain_name` | Hostname the control plane is served at. The certificate covers exactly this name. |
| `cluster_admin_principal_arns` | IAM roles or users that may reach the Kubernetes API. |
| `cluster_endpoint_public_access_cidrs` | Where those principals connect from. |
| `oidc_issuer` / `oidc_audience` | Your identity provider, for admin UI logins. |

`cluster_admin_principal_arns` is the only path to the Kubernetes API — a
principal not in this list cannot run `kubectl` regardless of its IAM
permissions. Include the identity you will run steps 4–7 as. Use the role or user
ARN; EKS rejects the `arn:aws:sts::…:assumed-role/…` form that
`aws sts get-caller-identity` prints.

There is no backend configuration in this repo. State for this stack contains the
database password and the device JWT signing key. The usual answer is an S3
bucket with versioning and a DynamoDB lock table:

```hcl
terraform {
  backend "s3" {
    bucket         = "your-terraform-state"
    key            = "pontem-control/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "your-terraform-locks"
    encrypt        = true
  }
}
```

### 2. Apply

```bash
terraform init
terraform apply
```

This takes 20–30 minutes; the EKS cluster and the RDS instance are most of it.

### 3. Send Pontem two values

```bash
terraform output aws_account_id
terraform output cp_runtime_assumed_role_arn
```

Pontem returns a `gcp.wifAudience`, which authorizes these pods to pull published
agent packages. The chart refuses to install until you have it.

### 4. Point kubectl at the cluster

```bash
$(terraform output -raw update_kubeconfig_command)
kubectl get nodes
```

`kubectl get nodes` returns nothing until the first pod is scheduled — Auto Mode
launches nodes on demand. An error mentioning `Unauthorized` means the identity
you are using is not in `cluster_admin_principal_arns`.

### 5. Create the namespace, the Secret, and the IngressClass

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

### 6. Install the chart

```bash
terraform output -raw helm_values > values.yaml
```

Open `values.yaml` and replace `REPLACE_ME_PONTEM_SUPPLIED` with the
`gcp.wifAudience` from step 3. Everything else is filled in.

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

### 7. Validate the certificate and point DNS at the load balancer

Skip the first half if you set `route53_zone_id` — the apply already created the
validation record and waited for the certificate.

```bash
terraform output acm_validation_records
```

Create that record in your DNS. The certificate stays in `PENDING_VALIDATION`
until it resolves, and the load balancer will not finish starting without an
issued certificate.

Then point `app_domain_name` at the load balancer:

```bash
kubectl get ingress -n "$(terraform output -raw namespace)"
```

Create a CNAME from your hostname to the `ADDRESS` shown. If your DNS provider
proxies traffic — Cloudflare's orange cloud, for example — turn that off for this
record; TLS terminates at the load balancer with the ACM certificate.

```bash
curl "$(terraform output -raw app_url)/health"
```

## Delivering the secrets with ESO

External Secrets Operator reads the two secrets from Secrets Manager and keeps the
Kubernetes Secret in sync, instead of you creating it in step 5. The IAM role and
Pod Identity association it needs already exist unless you set
`enable_external_secrets_iam = false`.

Install the operator:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true \
  --set serviceAccount.name=external-secrets \
  --wait
```

The service account name and namespace must stay as above; the Pod Identity
association binds those exact names, and the controller gets no AWS credentials
under any others. It needs no role annotation — Pod Identity injects credentials
into the pod.

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
by AWS rather than billed at the extended-support rate.

**Changing the hostname.** Change `app_domain_name` and apply. A new certificate
is issued before the old one is removed. Re-run step 7 for the new name, and
re-render `values.yaml` so `ingress.domain` matches.

**Inputs that destroy data.** `name_prefix` replaces the cluster and the
database. `db_name` and `db_user` replace the database. `vpc_cidr` and
`availability_zone_count` replace the VPC and everything in it. Each input's
description says so.

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

**The Ingress never gets an `ADDRESS`.** Most often the certificate is not
`ISSUED` yet:

```bash
aws acm describe-certificate \
  --certificate-arn "$(terraform output -raw acm_certificate_arn)" \
  --query 'Certificate.Status'
```

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
make check     # fmt, validate, tflint, terraform-docs drift, tests
make test      # terraform test only
make goldens   # re-render the golden files after changing a template
make docs      # regenerate the input/output tables in these READMEs
```

The tests use a mocked AWS provider and need no credentials.
[`modules/chart_values`](modules/chart_values) holds the chart values and manifest
rendering, split out so its tests can plan without a provider at all; its tests
assert the rendered output against committed golden files, so a change to the
values shape shows up as a reviewable diff.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6.0 |
| aws | ~> 5.70 |
| random | ~> 3.6 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 5.100.0 |
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
| app\_domain\_name | Hostname the control plane is served at, e.g. "pontem.example.com". The ACM certificate covers exactly this name, and it becomes the chart's ingress.domain. Changing it replaces the certificate only — safe, and the old one stays attached until the new one is issued. | `string` | n/a | yes |
| cluster\_admin\_principal\_arns | IAM principal ARNs granted cluster-admin on the EKS cluster via access entries. This is the ONLY path to the Kubernetes API: the cluster-creator bootstrap flag is off deliberately (see eks.tf), so a principal absent from this list cannot run kubectl no matter what IAM permissions it holds. Include the principal that will run the install steps, or the install cannot proceed. | `list(string)` | n/a | yes |
| cluster\_endpoint\_public\_access\_cidrs | CIDRs allowed to reach the public EKS API endpoint. There is no default on purpose: the internal Pontem stack this is distilled from leaves the endpoint world-open with a "tighten before prod" note, which is not a posture to ship to someone else. Use ["0.0.0.0/0"] only if you have decided that deliberately; the API is still IAM-gated, but so is everything an attacker would try against it. | `list(string)` | n/a | yes |
| availability\_zone\_count | How many availability zones to spread subnets across. Two is the floor: EKS requires its control-plane subnets in at least two AZs, and so does the RDS subnet group even for a single-AZ instance. CHANGING THIS REPLACES THE VPC's subnets. | `number` | `2` | no |
| cloudwatch\_log\_retention\_days | Retention for the EKS control-plane log group. The log group is created here rather than left to EKS, which would create it with never-expire retention and bill for it forever. | `number` | `90` | no |
| db\_allocated\_storage | Initial RDS storage in GiB. Storage autoscaling is on (see db\_max\_allocated\_storage), so this is a starting point, not a ceiling. | `number` | `20` | no |
| db\_backup\_retention\_period | Days of automated RDS backups. Also the window for point-in-time recovery, which is the only thing that recovers from a bad migration or a mistaken delete. Zero disables backups entirely. | `number` | `14` | no |
| db\_deletion\_protection | Refuse to delete the database instance. Default true, which means a `terraform destroy` fails until you set this false and apply — deliberate friction on the one resource whose loss is unrecoverable. | `bool` | `true` | no |
| db\_engine\_version | RDS Postgres MAJOR version. Major-only on purpose: RDS then owns the minor and patches it, whereas pinning a minor fights auto\_minor\_version\_upgrade and eventually plans an impossible downgrade. | `string` | `"18"` | no |
| db\_instance\_class | RDS instance class. db.t4g.medium (2 vCPU / 4 GiB) is a sane starting point for a small fleet; the control plane's connection budget is modest but its query pattern is chatty. Changing this is an in-place modification with a short failover, not a replacement. | `string` | `"db.t4g.medium"` | no |
| db\_max\_allocated\_storage | Ceiling for RDS storage autoscaling, in GiB. Must exceed db\_allocated\_storage or autoscaling is effectively off. | `number` | `200` | no |
| db\_multi\_az | Run the database as a Multi-AZ deployment with a synchronous standby. Default true: this is the control plane's only durable store, and a single-AZ instance turns an AZ event into a full outage plus a restore. Roughly doubles the instance cost — the honest knob to turn down for an evaluation. | `bool` | `true` | no |
| db\_name | Application database name inside the instance. CHANGING THIS REPLACES THE DATABASE INSTANCE and destroys its data. | `string` | `"pontem"` | no |
| db\_user | Postgres user the application authenticates as. This is the instance's master user, so it is created with the instance; CHANGING IT REPLACES THE DATABASE. | `string` | `"app"` | no |
| enable\_external\_secrets\_iam | Create the IAM role and Pod Identity association for External Secrets Operator, so ESO can read the two boot secrets instead of you copying them into a Kubernetes Secret by hand (README covers both paths). Harmless if you never install ESO: an association binds by service-account name and does nothing until a matching pod runs. | `bool` | `true` | no |
| external\_secrets\_namespace | Namespace the External Secrets Operator controller runs in. Only used when enable\_external\_secrets\_iam is true; matches the ESO chart's own default. | `string` | `"external-secrets"` | no |
| external\_secrets\_service\_account | Service account the External Secrets Operator controller runs as. Only used when enable\_external\_secrets\_iam is true; matches the ESO chart's own default. | `string` | `"external-secrets"` | no |
| kubernetes\_version | EKS Kubernetes version. Must be >= 1.30: the pontem-control chart uses the native preStop sleep action, which does not exist before 1.30. Keep this near the newest version EKS offers — the cluster's upgrade policy is STANDARD, so a version that leaves standard support gets auto-upgraded rather than billed at the extended-support premium. | `string` | `"1.36"` | no |
| name\_prefix | Prefix for every resource name this module creates. CHANGING THIS REPLACES THE CLUSTER AND THE DATABASE — the names are the resources' identity, so a new prefix means new resources and the old data is destroyed. Pick it once, before the first apply. | `string` | `"pontem-control"` | no |
| namespace | Kubernetes namespace the chart is installed into. The Pod Identity associations bind service accounts in this namespace, so it must match the namespace you pass to `helm install`; if they drift, the pods start but get no AWS credentials. | `string` | `"pontem-control"` | no |
| oidc\_audience | OIDC API audience the control plane validates access tokens against. Rendered into the chart values as auth.oidc.audience. Not a secret. Leave empty to supply it through the application Secret instead. | `string` | `""` | no |
| oidc\_issuer | OIDC issuer URL for user authentication, e.g. "https://your-tenant.us.auth0.com/". Rendered into the chart values as auth.oidc.issuer. Not a secret — it is public metadata your users' browsers fetch. Leave empty to supply it through the application Secret instead. | `string` | `""` | no |
| pod\_identity\_service\_accounts | Service accounts in `namespace` bound to the control-plane runtime role. The chart's api and worker pods both need AWS credentials for tenant-secret storage. Add "mcp" only if you enable the mcp deployment (it is off unless you set mcp.host in the chart). | `list(string)` | <pre>[<br/>  "api",<br/>  "worker"<br/>]</pre> | no |
| route53\_zone\_id | Route53 hosted zone ID for app\_domain\_name. Set it and the module creates the ACM validation records and waits for the certificate to be issued. Leave it null and the records are emitted as the acm\_validation\_records output for you to create wherever your DNS lives; no waiter is added in that case, because a waiter would block every future apply on a manual step. | `string` | `null` | no |
| secret\_recovery\_window\_days | Secrets Manager recovery window for the secrets this module creates. AWS keeps a deleted secret NAME reserved for this long and rejects re-creating it, so `terraform destroy` followed by a fresh apply fails with an "already scheduled for deletion" error until the window expires. That is the trade for being able to recover a secret you deleted by mistake; set it to 0 if you are repeatedly building and tearing down a trial stack. | `number` | `30` | no |
| single\_nat\_gateway | Route all private-subnet egress through one NAT gateway instead of one per AZ. Default false (one per AZ) because a shared NAT makes every AZ's egress depend on the NAT's AZ staying up. Setting it true saves roughly $33/month per AZ you drop and is a reasonable trade for an evaluation, not for production. | `bool` | `false` | no |
| tags | Extra tags merged onto every resource this module creates, on top of its own Project/ManagedBy tags. | `map(string)` | `{}` | no |
| vpc\_cidr | CIDR block for the dedicated VPC. Needs room for /20 subnets per AZ (public + private), so /16 is the comfortable choice. CHANGING THIS REPLACES THE VPC and everything inside it, including the cluster and the database. | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| acm\_certificate\_arn | ACM certificate ARN for app\_domain\_name. When route53\_zone\_id is set, reading this output implies the certificate is ISSUED. |
| acm\_validation\_records | DNS validation records to create when route53\_zone\_id is null, keyed by domain name. The certificate stays PENDING\_VALIDATION — and the ALB will never finish attaching it — until these resolve. Empty when the module created them itself. |
| app\_url | Where the control plane will answer once the chart is installed and DNS points app\_domain\_name at the ALB. |
| aws\_account\_id | Account these resources were created in. Pontem pins the federation to this account as well as to the role below, so send both. |
| aws\_region | Region these resources were created in, read from the provider. Needed by the External Secrets Operator store, which names its region explicitly. |
| cluster\_endpoint | EKS API server endpoint. |
| cluster\_name | EKS cluster name. |
| cp\_runtime\_assumed\_role\_arn | SEND THIS ONE TO PONTEM, together with aws\_account\_id, to get your gcp.wifAudience. It is the session-stripped assumed-role form (arn:aws:sts::<account>:assumed-role/<role>), which is what GCP Workload Identity Federation exposes as the role attribute and what its trust condition must match. The iam::...:role/... form above will not match and the federation will silently deny. |
| cp\_runtime\_role\_arn | IAM role ARN the api and worker pods assume via EKS Pod Identity. This is the role's own ARN — the form you use for IAM policies referring to it. |
| db\_endpoint | RDS endpoint hostname, without the port. |
| db\_name | Application database name. |
| db\_password | Generated RDS password. Also stored in Secrets Manager (db\_password\_secret\_arn); this output exists so the install can create the Kubernetes Secret without a round trip through the AWS console. |
| db\_password\_secret\_arn | Secrets Manager ARN of the database password, for the External Secrets Operator path. |
| db\_password\_secret\_name | Secrets Manager name of the database password. External Secrets refers to secrets by name, not ARN. |
| db\_port | RDS Postgres port. |
| db\_user | Application database user. |
| device\_jwt\_signing\_key | Generated device-JWT signing key, standard base64 of 32 bytes. ROTATING THIS INVALIDATES EVERY ENROLLED DEVICE'S JWT. |
| device\_jwt\_signing\_key\_secret\_arn | Secrets Manager ARN of the device-JWT signing key, for the External Secrets Operator path. |
| device\_jwt\_signing\_key\_secret\_name | Secrets Manager name of the device-JWT signing key. External Secrets refers to secrets by name, not ARN. |
| external\_secrets\_role\_arn | IAM role ARN for the External Secrets Operator controller, or null when enable\_external\_secrets\_iam is false. Nothing needs it at install time — Pod Identity binds it server-side — but it is here for auditing which role reads the boot secrets. |
| helm\_values | Rendered pontem-control chart values for this deployment. Write it to a file with `terraform output -raw helm_values > values.yaml` and pass it to helm. |
| ingress\_class\_manifest | The `alb` IngressClass and its IngressClassParams. Apply with `terraform output -raw ingress_class_manifest | kubectl apply -f -`. |
| namespace | Namespace to install the chart into. The Pod Identity associations bind service accounts in this namespace, so `helm install -n` must match it. |
| private\_subnet\_ids | Private subnet IDs. Nodes run here and the RDS subnet group spans them. |
| public\_subnet\_ids | Public subnet IDs. Internet-facing load balancers land here, discovered by their kubernetes.io/role/elb tag. |
| update\_kubeconfig\_command | Command that points kubectl at this cluster. Only principals listed in cluster\_admin\_principal\_arns can use the resulting context. |
| vpc\_id | ID of the VPC this module created. |
<!-- END_TF_DOCS -->
