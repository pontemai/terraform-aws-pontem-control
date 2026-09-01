import pulumi
from chart_values import ChartValues
from typing import Any
import json
import pulumi_aws as aws
import pulumi_random as random
import pulumi_std as std


def not_implemented(msg):
    raise NotImplementedError(msg)

config = pulumi.Config()
# Hostname the control plane is served at, e.g. "pontem.example.com". The ACM certificate covers exactly this name, and it becomes the chart's ingress.domain. Changing it replaces the certificate and nothing else; the old certificate stays attached until the new one is issued.
app_domain_name = config.require("appDomainName")
# IAM principal ARNs granted cluster-admin on the EKS cluster. This is the ONLY path to the Kubernetes API: a principal absent from this list cannot run kubectl no matter what IAM permissions it holds, including the one that created the cluster. Include the principal that will run the install steps, or the install cannot proceed.
cluster_admin_principal_arns = config.require_object("clusterAdminPrincipalArns")
# CIDRs allowed to reach the public EKS API endpoint. Anything outside them cannot reach the Kubernetes API at all; the endpoint is also IAM-gated independently of this list. ["0.0.0.0/0"] allows every source.
cluster_endpoint_public_access_cidrs = config.require_object("clusterEndpointPublicAccessCidrs")
# Prefix for every resource name this module creates. CHANGING THIS REPLACES THE CLUSTER AND THE DATABASE, destroying the data in them. Two stacks in one account need different prefixes.
name_prefix = config.get("namePrefix")
if name_prefix is None:
    name_prefix = "pontem-control"
# Extra tags merged onto every resource this module creates, on top of its own Project/ManagedBy tags.
tags = config.get_object("tags")
if tags is None:
    tags = {}
# CIDR block for the dedicated VPC. It is carved into one public and one private subnet per availability zone, each four bits narrower than this block — /20 subnets out of the default /16. CHANGING THIS REPLACES THE VPC and everything inside it, including the cluster and the database.
vpc_cidr = config.get("vpcCidr")
if vpc_cidr is None:
    vpc_cidr = "10.0.0.0/16"
# How many availability zones to spread subnets across. Two is the floor: EKS requires its control-plane subnets in at least two AZs, and so does the RDS subnet group even for a single-AZ instance. Raising it appends a subnet, NAT gateway, and route table per new zone and leaves the existing ones alone; lowering it destroys the highest-numbered zone's subnets and anything running in them.
availability_zone_count = config.get_float("availabilityZoneCount")
if availability_zone_count is None:
    availability_zone_count = 2
# Route all private-subnet egress through one NAT gateway instead of one per AZ. True saves roughly $33/month per AZ dropped, and makes outbound traffic from every AZ depend on the one NAT gateway's AZ staying up.
single_nat_gateway = config.get_bool("singleNatGateway")
if single_nat_gateway is None:
    single_nat_gateway = False
# Capture all VPC traffic metadata in CloudWatch. This adds CloudWatch ingestion and storage costs.
enable_vpc_flow_logs = config.get_bool("enableVpcFlowLogs")
if enable_vpc_flow_logs is None:
    enable_vpc_flow_logs = True
# EKS Kubernetes version. Must be >= 1.30: the pontem-control chart uses the native preStop sleep action, which does not exist before 1.30. The cluster's upgrade policy is STANDARD, so AWS auto-upgrades a version once it leaves standard support — after that happens, this must be raised to the version the cluster is actually on or every apply fails proposing a downgrade.
kubernetes_version = config.get("kubernetesVersion")
if kubernetes_version is None:
    kubernetes_version = "1.36"
# Refuse to delete the EKS cluster. While true, `terraform destroy` fails until it is set false and applied.
cluster_deletion_protection = config.get_bool("clusterDeletionProtection")
if cluster_deletion_protection is None:
    cluster_deletion_protection = True
# Retention for the module's device, EKS, RDS, and VPC Flow Log groups. 0 keeps them forever.
cloudwatch_log_retention_days = config.get_float("cloudwatchLogRetentionDays")
if cloudwatch_log_retention_days is None:
    cloudwatch_log_retention_days = 90
# RDS Postgres MAJOR version. Major-only on purpose: RDS then owns the minor and patches it, whereas pinning a minor fights auto_minor_version_upgrade and eventually plans an impossible downgrade.
db_engine_version = config.get("dbEngineVersion")
if db_engine_version is None:
    db_engine_version = "18"
# RDS instance class. Changing it is an in-place modification with a short failover, not a replacement.
db_instance_class = config.get("dbInstanceClass")
if db_instance_class is None:
    db_instance_class = "db.t4g.medium"
# Initial RDS storage in GiB. Storage autoscaling is on (see db_max_allocated_storage), so this is a starting point, not a ceiling.
db_allocated_storage = config.get_float("dbAllocatedStorage")
if db_allocated_storage is None:
    db_allocated_storage = 20
# Ceiling for RDS storage autoscaling, in GiB. Must be at least db_allocated_storage.
db_max_allocated_storage = config.get_float("dbMaxAllocatedStorage")
if db_max_allocated_storage is None:
    db_max_allocated_storage = 200
# Application database name inside the instance. CHANGING THIS REPLACES THE DATABASE INSTANCE and destroys its data.
db_name = config.get("dbName")
if db_name is None:
    db_name = "pontem"
# Postgres user the application authenticates as. This is the instance's master user, so it is created with the instance; CHANGING IT REPLACES THE DATABASE.
db_user = config.get("dbUser")
if db_user is None:
    db_user = "app"
# Run the database as a Multi-AZ deployment with a synchronous standby. Roughly doubles the instance cost. False turns an AZ failure into an outage plus a restore from backup; the database is the control plane's only durable store.
db_multi_az = config.get_bool("dbMultiAz")
if db_multi_az is None:
    db_multi_az = True
# Days of automated RDS backups. Also the window for point-in-time recovery, which is the only thing that recovers from a bad migration or a mistaken delete. Zero disables backups entirely.
db_backup_retention_period = config.get_float("dbBackupRetentionPeriod")
if db_backup_retention_period is None:
    db_backup_retention_period = 14
# Refuse to delete the database instance. While true, `terraform destroy` fails until it is set false and applied.
db_deletion_protection = config.get_bool("dbDeletionProtection")
if db_deletion_protection is None:
    db_deletion_protection = True
# Version of the generated database password. Raising it changes the secret and RDS password, but running pods keep the old value until restarted.
db_password_version = config.get_float("dbPasswordVersion")
if db_password_version is None:
    db_password_version = 1
# Version of the generated device JWT signing key. Raising this value invalidates every enrolled device's JWT.
device_jwt_signing_key_version = config.get_float("deviceJwtSigningKeyVersion")
if device_jwt_signing_key_version is None:
    device_jwt_signing_key_version = 1
# Days a deleted secret stays recoverable. AWS keeps the deleted secret's NAME reserved for this long and rejects re-creating it, so `terraform destroy` followed by a fresh apply fails with "already scheduled for deletion" until the window expires. 0 deletes immediately, which makes repeated build-and-tear-down cycles work.
secret_recovery_window_days = config.get_float("secretRecoveryWindowDays")
if secret_recovery_window_days is None:
    secret_recovery_window_days = 30
# ID of an existing Route53 hosted zone for app_domain_name. Set this or create_route53_zone to automate ACM validation and application DNS. Leave both unset to create the returned acm_validation_records yourself.
route53_zone_id = config.get_object("route53ZoneId")
if route53_zone_id is None:
    route53_zone_id = None
# Create a Route53 hosted zone for app_domain_name. Cannot be used with route53_zone_id. Delegate the hostname to route53_name_servers before the full apply; see the README.
create_route53_zone = config.get_bool("createRoute53Zone")
if create_route53_zone is None:
    create_route53_zone = False
# Kubernetes namespace the chart is installed into. The Pod Identity associations bind service accounts in this namespace, so it must match the namespace you pass to `helm install`; if they drift, the pods start but get no AWS credentials.
namespace = config.get("namespace")
if namespace is None:
    namespace = "pontem-control"
# Optional AWS Organizations ID (for example, o-abc123def456). When set, Pod Identity roles also require their source to belong to this organization.
aws_organization_id = config.get_object("awsOrganizationId")
if aws_organization_id is None:
    aws_organization_id = None
# Service accounts in `namespace` bound to the control-plane runtime role. The chart's api and worker pods both need AWS credentials for tenant-secret storage. Add "mcp" only if you enable the mcp deployment (it is off unless you set mcp.host in the chart).
pod_identity_service_accounts = config.get_object("podIdentityServiceAccounts")
if pod_identity_service_accounts is None:
    pod_identity_service_accounts = [
        "api",
        "worker",
    ]
# OIDC issuer URL, e.g. "https://your-tenant.us.auth0.com/" or "https://your-org.okta.com/oauth2/default".
oidc_issuer = config.require("oidcIssuer")
# OIDC API audience the control plane validates access tokens against, and that the admin app requests tokens for. These must be the same value or the API rejects every token the UI sends.
oidc_audience = config.require("oidcAudience")
# GCP Workload Identity Federation audience, which Pontem issues once it has your account id and the control-plane runtime role ARN (both are outputs of this module). Until you set it, the rendered chart values carry the placeholder below; the chart rejects only an EMPTY audience, so an install that keeps the placeholder succeeds and then fails the first time a managed agent package is pulled.
wif_audience = config.get("wifAudience")
if wif_audience is None:
    wif_audience = "REPLACE_ME_PONTEM_SUPPLIED"
# Client ID of the public single-page-app client the admin UI signs in with. Used only by the browser; the API never sees it. Without it the admin UI renders a blank page while every pod reports healthy.
oidc_client_id = config.require("oidcClientId")
current = aws.get_region_output()
current_get_caller_identity = aws.get_caller_identity_output()
region = current.region
account_id = current_get_caller_identity.account_id
# Modules cannot set provider default_tags, so each resource gets this map.
my_tags = std.merge_output(input=[
    {
        "project": "pontem-control",
        "managedBy": "terraform",
    },
    tags,
]).result
# name_prefix validation keeps boot secrets outside these runtime-role grants.
tenant_secret_arns = [
    pulumi.Output.all(
        region=region,
        account_id=account_id
).apply(lambda resolved_outputs: f"arn:aws:secretsmanager:{resolved_outputs['region']}:{resolved_outputs['account_id']}:secret:tenant-*")
,
    pulumi.Output.all(
        region=region,
        account_id=account_id
).apply(lambda resolved_outputs: f"arn:aws:secretsmanager:{resolved_outputs['region']}:{resolved_outputs['account_id']}:secret:registry-tenant-*")
,
]
# Resource counts need a plan-time value; a new zone's ID stays unknown until apply.
has_route53_zone = create_route53_zone or route53_zone_id is not None
# The chart uses this ACM certificate at the ALB. With a Route53 zone, the module
# writes the validation record and waits for issuance; otherwise it returns the
# record for the caller to create.
this: list[aws.route53.Zone] = []
for this_range in [{"value": i} for i in range(0, 1 if create_route53_zone else 0)]:
    this.append(aws.route53.Zone(f"this-{this_range['value']}",
        name=app_domain_name,
        tags=my_tags))
# Callers use this only as a value, where an unknown ID is safe during planning.
my_route53_zone_id = this[0].zone_id if create_route53_zone else route53_zone_id
app = aws.acm.Certificate("app",
    domain_name=app_domain_name,
    validation_method="DNS",
    tags=my_tags)
# Terraform must know for_each keys during planning. app_domain_name is known
# even when the new zone ID and ACM validation values are not.
acm_validation: list[aws.route53.Record] = []
def create_acm_validation(range_body):
    for acm_validation_range in [{"key": k, "value": v} for [k, v] in enumerate(range_body)]:
        acm_validation.append(aws.route53.Record(f"acm_validation-{acm_validation_range['key']}",
            zone_id=my_route53_zone_id,
            name=not_implemented("one([fordvoinaws_acm_certificate.app.domain_validation_options:dvo.resource_record_nameifdvo.domain_name==each.value])"),
            type=aws.route53.RecordType(not_implemented("one([fordvoinaws_acm_certificate.app.domain_validation_options:dvo.resource_record_typeifdvo.domain_name==each.value])")),
            records=[not_implemented("one([fordvoinaws_acm_certificate.app.domain_validation_options:dvo.resource_record_valueifdvo.domain_name==each.value])")],
            ttl=60,
            allow_overwrite=True))

std.toset_output(input=[app_domain_name]).result if has_route53_zone else std.toset_output(input=[]).result.apply(create_acm_validation)
app_certificate_validation: list[aws.acm.CertificateValidation] = []
for app_certificate_validation_range in [{"value": i} for i in range(0, 1 if has_route53_zone else 0)]:
    app_certificate_validation.append(aws.acm.CertificateValidation(f"app-{app_certificate_validation_range['value']}",
        certificate_arn=app.arn,
        validation_record_fqdns=acm_validation.apply(lambda acm_validation: [record.fqdn for record in acm_validation])))
# Make helm_values wait for validation when the module manages DNS.
acm_certificate_arn = app_certificate_validation[0].certificate_arn if has_route53_zone else app.arn
# Exactly two secrets in Secrets Manager: the database password and the device
# JWT signing key. These random resources are converter-compatible, but their
# values are stored in Terraform state. The write-only AWS arguments below keep
# the values out of the AWS resource state.
#
# Per-tenant secrets are not created here; the application creates those at runtime
# under the tenant-* prefixes that identity.tf grants.
# The API signs device JWTs with this. The control plane's Ed25519 device
# identity provider requires DEVICE_JWT_SIGNING_KEY to be the standard base64
# encoding of EXACTLY 32 bytes and fails at startup on anything else, which is
# why this is 32 random bytes rendered as standard base64 rather than a password
# of some length.
#
# Rotation invalidates every enrolled device's JWT.
# There is deliberately no prevent_destroy lifecycle block — that would make
# `terraform destroy` fail outright, which is hostile when someone is tearing
# down an evaluation. The Secrets Manager recovery window
# (secret_recovery_window_days) is the real protection.
db_random_password = random.RandomPassword("db",
    length=32,
    special=False,
    keepers={
        "version": str(db_password_version),
    })
device_jwt_signing_key = random.RandomBytes("device_jwt_signing_key",
    length=32,
    keepers={
        "version": str(device_jwt_signing_key_version),
    })
db_password = aws.secretsmanager.Secret("db_password",
    name=f"{name_prefix}-db-password",
    description="RDS Postgres password for pontem-control (DATABASE_PASSWORD).",
    recovery_window_in_days=int(secret_recovery_window_days),
    tags=my_tags)
db_password_secret_version = aws.secretsmanager.SecretVersion("db_password",
    secret_id=db_password.id,
    secret_string_wo=db_random_password.result,
    secret_string_wo_version=int(db_password_version))
device_jwt_signing_key_secret = aws.secretsmanager.Secret("device_jwt_signing_key",
    name=f"{name_prefix}-device-jwt-signing-key",
    description="Ed25519 device-JWT signing key for pontem-control (DEVICE_JWT_SIGNING_KEY): standard base64 of exactly 32 bytes. Rotating it invalidates every enrolled device's JWT.",
    recovery_window_in_days=int(secret_recovery_window_days),
    tags=my_tags)
device_jwt_signing_key_secret_version = aws.secretsmanager.SecretVersion("device_jwt_signing_key",
    secret_id=device_jwt_signing_key_secret.id,
    secret_string_wo=device_jwt_signing_key.base64,
    secret_string_wo_version=int(device_jwt_signing_key_version))
# Dedicated VPC: one public and one private subnet per availability zone, an
# internet gateway, and NAT. The cluster's nodes, its load balancers, and the
# database all land in these subnets. Nothing here is shared with anything else
# in the account.
available = aws.get_availability_zones_output(filters=[{
        "name": "opt-in-status",
        "values": ["opt-in-not-required"],
    }],
    state="available")
azs = std.slice_output(list=available.names,
    from_=0,
    to=availability_zone_count).result
# Subnets four bits narrower than the VPC block (/20 out of the default /16):
# public subnets from the bottom, private starting half-way up, so the two
# ranges never interleave and adding an AZ appends a subnet instead of
# renumbering — renumbering would replace an existing subnet, and with it
# everything running in that subnet.
public_subnet_cidrs = pulumi.Output.all(
    invoke=std.range_output(limit=availability_zone_count),
    invoke1=std.cidrsubnet_output(input=vpc_cidr,
        newbits=4,
        netnum=int(i))
).apply(lambda resolved_outputs: [resolved_outputs['invoke1'].result for i in resolved_outputs['invoke'].result])

private_subnet_cidrs = pulumi.Output.all(
    invoke=std.range_output(limit=availability_zone_count),
    invoke1=std.cidrsubnet_output(input=vpc_cidr,
        newbits=4,
        netnum=int(i + float(8)))
).apply(lambda resolved_outputs: [resolved_outputs['invoke1'].result for i in resolved_outputs['invoke'].result])

nat_gateway_count = float(1) if single_nat_gateway else availability_zone_count
this_vpc = aws.ec2.Vpc("this",
    cidr_block=vpc_cidr,
    enable_dns_support=True,
    enable_dns_hostnames=True,
    tags=std.merge_output(input=[
        my_tags,
        {
            "name": name_prefix,
        },
    ]).result)
this_default_security_group = aws.ec2.DefaultSecurityGroup("this",
    vpc_id=this_vpc.id,
    ingress=[],
    egress=[],
    tags=std.merge_output(input=[
        my_tags,
        {
            "name": f"{name_prefix}-default",
        },
    ]).result)
this_internet_gateway = aws.ec2.InternetGateway("this",
    vpc_id=this_vpc.id,
    tags=std.merge_output(input=[
        my_tags,
        {
            "name": name_prefix,
        },
    ]).result)
# The kubernetes.io/role/* tags below are load-bearing: EKS Auto Mode's built-in
# load balancer controller discovers which subnets to place internet-facing and
# internal load balancers in by reading them. Without them, an Ingress is
# created and then never gets an address.
public: list[aws.ec2.Subnet] = []
for public_range in [{"value": i} for i in range(0, availability_zone_count)]:
    public.append(aws.ec2.Subnet(f"public-{public_range['value']}",
        vpc_id=this_vpc.id,
        cidr_block=public_subnet_cidrs[public_range["value"]],
        availability_zone=azs[public_range["value"]],
        map_public_ip_on_launch=False,
        tags=std.merge_output(input=[
            my_tags,
            {
                "name": f"{name_prefix}-public-{azs[public_range['value']]}",
                "kubernetes.io/role/elb": "1",
            },
        ]).result))
private: list[aws.ec2.Subnet] = []
for private_range in [{"value": i} for i in range(0, availability_zone_count)]:
    private.append(aws.ec2.Subnet(f"private-{private_range['value']}",
        vpc_id=this_vpc.id,
        cidr_block=private_subnet_cidrs[private_range["value"]],
        availability_zone=azs[private_range["value"]],
        tags=std.merge_output(input=[
            my_tags,
            {
                "name": f"{name_prefix}-private-{azs[private_range['value']]}",
                "kubernetes.io/role/internal-elb": "1",
            },
        ]).result))
nat: list[aws.ec2.Eip] = []
for nat_range in [{"value": i} for i in range(0, nat_gateway_count)]:
    nat.append(aws.ec2.Eip(f"nat-{nat_range['value']}",
        domain="vpc",
        tags=std.merge_output(input=[
            my_tags,
            {
                "name": f"{name_prefix}-nat-{nat_range['value']}",
            },
        ]).result))
this_nat_gateway: list[aws.ec2.NatGateway] = []
for this_nat_gateway_range in [{"value": i} for i in range(0, nat_gateway_count)]:
    this_nat_gateway.append(aws.ec2.NatGateway(f"this-{this_nat_gateway_range['value']}",
        allocation_id=nat[this_nat_gateway_range["value"]].id,
        subnet_id=public[this_nat_gateway_range["value"]].id,
        tags=std.merge_output(input=[
            my_tags,
            {
                "name": f"{name_prefix}-{azs[this_nat_gateway_range['value']]}",
            },
        ]).result,
        opts = pulumi.ResourceOptions(depends_on=[this_internet_gateway])))
public_route_table = aws.ec2.RouteTable("public",
    routes=[{
        "cidr_block": "0.0.0.0/0",
        "gateway_id": this_internet_gateway.id,
    }],
    vpc_id=this_vpc.id,
    tags=std.merge_output(input=[
        my_tags,
        {
            "name": f"{name_prefix}-public",
        },
    ]).result)
public_route_table_association: list[aws.ec2.RouteTableAssociation] = []
for public_route_table_association_range in [{"value": i} for i in range(0, availability_zone_count)]:
    public_route_table_association.append(aws.ec2.RouteTableAssociation(f"public-{public_route_table_association_range['value']}",
        subnet_id=public[public_route_table_association_range["value"]].id,
        route_table_id=public_route_table.id))
# One private route table per AZ even when sharing a single NAT gateway: the
# tables are free, and it means flipping single_nat_gateway later re-points
# routes instead of restructuring the tables.
private_route_table: list[aws.ec2.RouteTable] = []
for private_route_table_range in [{"value": i} for i in range(0, availability_zone_count)]:
    private_route_table.append(aws.ec2.RouteTable(f"private-{private_route_table_range['value']}",
        routes=[{
            "cidr_block": "0.0.0.0/0",
            "nat_gateway_id": this_nat_gateway[0 if single_nat_gateway else private_route_table_range["value"]].id,
        }],
        vpc_id=this_vpc.id,
        tags=std.merge_output(input=[
            my_tags,
            {
                "name": f"{name_prefix}-private-{azs[private_route_table_range['value']]}",
            },
        ]).result))
private_route_table_association: list[aws.ec2.RouteTableAssociation] = []
for private_route_table_association_range in [{"value": i} for i in range(0, availability_zone_count)]:
    private_route_table_association.append(aws.ec2.RouteTableAssociation(f"private-{private_route_table_association_range['value']}",
        subnet_id=private[private_route_table_association_range["value"]].id,
        route_table_id=private_route_table[private_route_table_association_range["value"]].id))
# EKS in Auto Mode: AWS runs the data plane — nodes from the built-in
# general-purpose and system pools, ALB ingress, EBS storage, and the core
# add-ons including the Pod Identity agent. There is no managed node group, no
# self-managed load balancer controller, and no add-on resources here, because
# Auto Mode owns all of it.
# ----- Cluster IAM role -----
cluster_assume = aws.iam.get_policy_document_output(statements=[{
    "principals": [{
        "type": "Service",
        "identifiers": ["eks.amazonaws.com"],
    }],
    "effect": "Allow",
    "actions": [
        "sts:AssumeRole",
        "sts:TagSession",
    ],
}])
cluster = aws.iam.Role("cluster",
    name=f"{name_prefix}-eks-cluster",
    description=f"Control-plane role for the {name_prefix} EKS cluster.",
    assume_role_policy=cluster_assume.json,
    tags=my_tags)
cluster_eks = aws.iam.RolePolicyAttachment("cluster_eks",
    role=cluster.name,
    policy_arn="arn:aws:iam::aws:policy/AmazonEKSClusterPolicy")
# The four Auto Mode managed policies — compute, block storage, load balancing,
# networking. Auto Mode acts through the CLUSTER role, not the node role, which
# is why the node role below is so small.
cluster_compute = aws.iam.RolePolicyAttachment("cluster_compute",
    role=cluster.name,
    policy_arn="arn:aws:iam::aws:policy/AmazonEKSComputePolicy")
cluster_block_storage = aws.iam.RolePolicyAttachment("cluster_block_storage",
    role=cluster.name,
    policy_arn="arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy")
cluster_load_balancing = aws.iam.RolePolicyAttachment("cluster_load_balancing",
    role=cluster.name,
    policy_arn="arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy")
cluster_networking = aws.iam.RolePolicyAttachment("cluster_networking",
    role=cluster.name,
    policy_arn="arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy")
# ----- Cluster -----
# Created ahead of the cluster so retention is ours to set. EKS would otherwise
# auto-create this exact log group on first log delivery, with never-expire
# retention, and bill for it indefinitely.
cluster_log_group = aws.cloudwatch.LogGroup("cluster",
    name=f"/aws/eks/{name_prefix}/cluster",
    retention_in_days=int(cloudwatch_log_retention_days),
    tags=my_tags)
# ----- Node IAM role -----
node_assume = aws.iam.get_policy_document_output(statements=[{
    "principals": [{
        "type": "Service",
        "identifiers": ["ec2.amazonaws.com"],
    }],
    "effect": "Allow",
    "actions": ["sts:AssumeRole"],
}])
auto_node = aws.iam.Role("auto_node",
    name=f"{name_prefix}-eks-auto-node",
    description=f"Node role for Auto Mode-launched nodes in the {name_prefix} cluster.",
    assume_role_policy=node_assume.json,
    tags=my_tags)
this_cluster = aws.eks.Cluster("this",
    upgrade_policy={
        "support_type": "STANDARD",
    },
    access_config={
        "authentication_mode": "API",
        "bootstrap_cluster_creator_admin_permissions": False,
    },
    vpc_config={
        "subnet_ids": [__item.id for __item in private],
        "endpoint_public_access": True,
        "endpoint_private_access": True,
        "public_access_cidrs": cluster_endpoint_public_access_cidrs,
    },
    compute_config={
        "enabled": True,
        "node_pools": [
            "general-purpose",
            "system",
        ],
        "node_role_arn": auto_node.arn,
    },
    kubernetes_network_config={
        "elastic_load_balancing": {
            "enabled": True,
        },
    },
    storage_config={
        "block_storage": {
            "enabled": True,
        },
    },
    name=name_prefix,
    version=kubernetes_version,
    role_arn=cluster.arn,
    deletion_protection=cluster_deletion_protection,
    enabled_cluster_log_types=[
        "api",
        "audit",
        "authenticator",
    ],
    bootstrap_self_managed_addons=False,
    tags=my_tags,
    opts = pulumi.ResourceOptions(depends_on=[
            cluster_eks,
            cluster_compute,
            cluster_block_storage,
            cluster_load_balancing,
            cluster_networking,
            cluster_log_group,
        ]))
# Auto Mode nodes get their networking permissions from the cluster role, so the
# node role only needs the minimal worker policy plus image pull.
auto_node_minimal = aws.iam.RolePolicyAttachment("auto_node_minimal",
    role=auto_node.name,
    policy_arn="arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy")
# PullOnly, not ReadOnly: PullOnly's ecr:BatchImportUpstreamImage covers pulling
# from a registry in another AWS account, which is what these nodes do, and it
# grants nothing beyond pull. Getting this wrong presents as images that never
# pull, and it reads as a registry-policy problem.
auto_node_ecr_pull = aws.iam.RolePolicyAttachment("auto_node_ecr_pull",
    role=auto_node.name,
    policy_arn="arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly")
# ----- Access entries -----
admin: dict[str, aws.eks.AccessEntry] = {}
for admin_range in [{"key": k, "value": v} for [k, v] in sorted(({entry: entry for entry in cluster_admin_principal_arns}).items())]:
    admin[admin_range['key']] = aws.eks.AccessEntry(f"admin-{admin_range['key']}",
        cluster_name=this_cluster.name,
        principal_arn=admin_range["value"],
        tags=my_tags)
admin_access_policy_association: dict[str, aws.eks.AccessPolicyAssociation] = {}
for admin_access_policy_association_range in [{"key": k, "value": v} for [k, v] in sorted(({entry: entry for entry in cluster_admin_principal_arns}).items())]:
    admin_access_policy_association[admin_access_policy_association_range['key']] = aws.eks.AccessPolicyAssociation(f"admin-{admin_access_policy_association_range['key']}",
        access_scope={
            "type": "cluster",
        },
        cluster_name=this_cluster.name,
        principal_arn=admin_access_policy_association_range["value"],
        policy_arn="arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy",
        opts = pulumi.ResourceOptions(depends_on=[admin]))
# VPC Flow Logs record network metadata, not packet contents, in CloudWatch with
# the module's retention setting.
vpc_flow: list[aws.cloudwatch.LogGroup] = []
for vpc_flow_range in [{"value": i} for i in range(0, 1 if enable_vpc_flow_logs else 0)]:
    vpc_flow.append(aws.cloudwatch.LogGroup(f"vpc_flow-{vpc_flow_range['value']}",
        name=f"/aws/vpc/{name_prefix}/flow-logs",
        retention_in_days=int(cloudwatch_log_retention_days),
        tags=my_tags))
vpc_flow_role: list[aws.iam.Role] = []
for vpc_flow_role_range in [{"value": i} for i in range(0, 1 if enable_vpc_flow_logs else 0)]:
    vpc_flow_role.append(aws.iam.Role(f"vpc_flow-{vpc_flow_role_range['value']}",
        name=f"{name_prefix}-vpc-flow-logs",
        description="Lets VPC Flow Logs publish network metadata to this module's CloudWatch log group.",
        assume_role_policy=pulumi.Output.json_dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {
                    "Service": "vpc-flow-logs.amazonaws.com",
                },
                "Action": "sts:AssumeRole",
                "Condition": {
                    "StringEquals": {
                        "aws:SourceAccount": account_id,
                    },
                    "ArnLike": {
                        "aws:SourceArn": pulumi.Output.all(
                            region=region,
                            account_id=account_id
).apply(lambda resolved_outputs: f"arn:aws:ec2:{resolved_outputs['region']}:{resolved_outputs['account_id']}:vpc-flow-log/*")
,
                    },
                },
            }],
        }),
        tags=my_tags))
vpc_flow_role_policy: list[aws.iam.RolePolicy] = []
for vpc_flow_role_policy_range in [{"value": i} for i in range(0, 1 if enable_vpc_flow_logs else 0)]:
    vpc_flow_role_policy.append(aws.iam.RolePolicy(f"vpc_flow-{vpc_flow_role_policy_range['value']}",
        name=f"{name_prefix}-vpc-flow-logs",
        role=vpc_flow_role[0].id,
        policy=pulumi.Output.json_dumps({
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": [
                        "logs:CreateLogStream",
                        "logs:DescribeLogStreams",
                        "logs:PutLogEvents",
                    ],
                    "Resource": vpc_flow[0].arn.apply(lambda arn: f"{arn}:*"),
                },
                {
                    "Effect": "Allow",
                    "Action": "logs:DescribeLogGroups",
                    "Resource": "*",
                },
            ],
        })))
vpc: list[aws.ec2.FlowLog] = []
for vpc_range in [{"value": i} for i in range(0, 1 if enable_vpc_flow_logs else 0)]:
    vpc.append(aws.ec2.FlowLog(f"vpc-{vpc_range['value']}",
        iam_role_arn=vpc_flow_role[0].arn,
        log_destination=vpc_flow[0].arn,
        traffic_type="ALL",
        vpc_id=this_vpc.id,
        tags=my_tags,
        opts = pulumi.ResourceOptions(depends_on=[vpc_flow_role_policy])))
pod_identity_assume_role_policies = {role: pulumi.Output.json_dumps({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {
            "Service": "pods.eks.amazonaws.com",
        },
        "Action": [
            "sts:AssumeRole",
            "sts:TagSession",
        ],
        "Condition": {
            "StringEquals": std.merge_output(input=[
                {
                    "aws:RequestTag/eks-cluster-arn": [pulumi.Output.all(
                        region=region,
                        account_id=account_id
).apply(lambda resolved_outputs: f"arn:aws:eks:{resolved_outputs['region']}:{resolved_outputs['account_id']}:cluster/{name_prefix}")
],
                    "aws:RequestTag/kubernetes-namespace": [namespace],
                    "aws:RequestTag/kubernetes-service-account": service_accounts,
                    "aws:SourceAccount": [account_id],
                },
                {} if aws_organization_id is None else {
                    "aws:SourceOrgId": [aws_organization_id],
                },
            ]).result,
        },
    }],
}) for role, serviceAccounts in sorted({
    "cpRuntime": pod_identity_service_accounts,
    "eso": ["external-secrets"],
    "externalDns": ["external-dns"],
}.items())}
cp_runtime_role = aws.iam.Role("cp_runtime",
    name=f"{name_prefix}-cp-runtime",
    description=f"Runtime identity for the pontem-control api, worker, and optional mcp pods in {name_prefix}, assumed via EKS Pod Identity.",
    assume_role_policy=pod_identity_assume_role_policies["cpRuntime"],
    tags=my_tags)
device_telemetry = aws.cloudwatch.LogGroup("device_telemetry",
    name=f"/{name_prefix}/device",
    retention_in_days=int(cloudwatch_log_retention_days),
    tags=my_tags)
# ----- Device telemetry writer role -----
device_telemetry_writer_assume = aws.iam.get_policy_document_output(statements=[{
    "conditions": [{
        "test": "StringEquals",
        "variable": "aws:PrincipalTag/kubernetes-service-account",
        "values": ["api"],
    }],
    "principals": [{
        "type": "AWS",
        "identifiers": [cp_runtime_role.arn],
    }],
    "effect": "Allow",
    "actions": [
        "sts:AssumeRole",
        "sts:TagSession",
    ],
}])
device_telemetry_writer_role = aws.iam.Role("device_telemetry_writer",
    name=f"{name_prefix}-device-telemetry-writer",
    description=f"Short-lived device access to publish logs and metrics for {name_prefix}.",
    assume_role_policy=device_telemetry_writer_assume.json,
    tags=my_tags)
cp_runtime = aws.iam.get_policy_document_output(statements=[
    {
        "effect": "Allow",
        "actions": [
            "secretsmanager:CreateSecret",
            "secretsmanager:DeleteSecret",
            "secretsmanager:PutSecretValue",
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:ListSecretVersionIds",
            "secretsmanager:UpdateSecretVersionStage",
            "secretsmanager:TagResource",
        ],
        "resources": tenant_secret_arns,
    },
    {
        "conditions": [{
            "test": "StringEquals",
            "variable": "aws:PrincipalTag/kubernetes-service-account",
            "values": [
                "api",
                "mcp",
            ],
        }],
        "effect": "Allow",
        "actions": [
            "logs:StartQuery",
            "logs:GetQueryResults",
        ],
        "resources": [device_telemetry.arn],
    },
    {
        "conditions": [{
            "test": "StringEquals",
            "variable": "aws:PrincipalTag/kubernetes-service-account",
            "values": [
                "api",
                "mcp",
            ],
        }],
        "effect": "Allow",
        "actions": ["logs:StopQuery"],
        "resources": ["*"],
    },
    {
        "conditions": [{
            "test": "StringEquals",
            "variable": "aws:PrincipalTag/kubernetes-service-account",
            "values": ["api"],
        }],
        "effect": "Allow",
        "actions": ["logs:CreateLogStream"],
        "resources": [device_telemetry.arn.apply(lambda arn: f"{arn}:log-stream:*")],
    },
    {
        "conditions": [{
            "test": "StringEquals",
            "variable": "aws:PrincipalTag/kubernetes-service-account",
            "values": [
                "api",
                "worker",
                "mcp",
            ],
        }],
        "effect": "Allow",
        "actions": [
            "cloudwatch:GetMetricData",
            "cloudwatch:ListMetrics",
        ],
        "resources": ["*"],
    },
    {
        "conditions": [{
            "test": "StringEquals",
            "variable": "aws:PrincipalTag/kubernetes-service-account",
            "values": ["worker"],
        }],
        "effect": "Allow",
        "actions": ["cloudwatch:PutMetricData"],
        "resources": ["*"],
    },
    {
        "conditions": [{
            "test": "StringEquals",
            "variable": "aws:PrincipalTag/kubernetes-service-account",
            "values": ["api"],
        }],
        "effect": "Allow",
        "actions": ["sts:AssumeRole"],
        "resources": [device_telemetry_writer_role.arn],
    },
])
cp_runtime_role_policy = aws.iam.RolePolicy("cp_runtime",
    name=f"{name_prefix}-cp-runtime",
    role=cp_runtime_role.id,
    policy=cp_runtime.json)
# Associations can be created before the chart creates its service accounts.
cp_runtime_pod_identity_association: dict[str, aws.eks.PodIdentityAssociation] = {}
for cp_runtime_pod_identity_association_range in [{"key": k, "value": v} for [k, v] in sorted(({entry: entry for entry in pod_identity_service_accounts}).items())]:
    cp_runtime_pod_identity_association[cp_runtime_pod_identity_association_range['key']] = aws.eks.PodIdentityAssociation(f"cp_runtime-{cp_runtime_pod_identity_association_range['key']}",
        cluster_name=this_cluster.name,
        namespace=namespace,
        service_account=cp_runtime_pod_identity_association_range["value"],
        role_arn=cp_runtime_role.arn,
        tags=my_tags)
device_telemetry_writer = aws.iam.get_policy_document_output(statements=[
    {
        "effect": "Allow",
        "actions": ["logs:PutLogEvents"],
        "resources": [device_telemetry.arn.apply(lambda arn: f"{arn}:log-stream:*")],
    },
    {
        "effect": "Allow",
        "actions": ["cloudwatch:PutMetricData"],
        "resources": ["*"],
    },
])
device_telemetry_writer_role_policy = aws.iam.RolePolicy("device_telemetry_writer",
    name=f"{name_prefix}-device-telemetry-writer",
    role=device_telemetry_writer_role.id,
    policy=device_telemetry_writer.json)
eso = aws.iam.Role("eso",
    name=f"{name_prefix}-external-secrets",
    description=f"External Secrets Operator controller in {name_prefix}, assumed via EKS Pod Identity. Read-only on this module's two boot secrets.",
    assume_role_policy=pod_identity_assume_role_policies["eso"],
    tags=my_tags)
eso_role_policy = aws.iam.RolePolicy("eso",
    name=f"{name_prefix}-external-secrets",
    role=eso.id,
    policy=pulumi.Output.json_dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue",
                "secretsmanager:DescribeSecret",
            ],
            "Resource": [
                db_password.arn,
                device_jwt_signing_key_secret.arn,
            ],
        }],
    }))
eso_pod_identity_association = aws.eks.PodIdentityAssociation("eso",
    cluster_name=this_cluster.name,
    namespace=namespace,
    service_account="external-secrets",
    role_arn=eso.arn,
    tags=my_tags)
# ----- ExternalDNS role -----
external_dns: list[aws.iam.Role] = []
for external_dns_range in [{"value": i} for i in range(0, 1 if has_route53_zone else 0)]:
    external_dns.append(aws.iam.Role(f"external_dns-{external_dns_range['value']}",
        name=f"{name_prefix}-external-dns",
        description=f"ExternalDNS controller in {name_prefix}, assumed via EKS Pod Identity. DNS changes are limited to {app_domain_name}.",
        assume_role_policy=pod_identity_assume_role_policies["externalDns"],
        tags=my_tags))
external_dns_role_policy: list[aws.iam.RolePolicy] = []
for external_dns_role_policy_range in [{"value": i} for i in range(0, 1 if has_route53_zone else 0)]:
    external_dns_role_policy.append(aws.iam.RolePolicy(f"external_dns-{external_dns_role_policy_range['value']}",
        name=f"{name_prefix}-external-dns",
        role=external_dns[0].id,
        policy=pulumi.Output.json_dumps({
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": ["route53:ChangeResourceRecordSets"],
                    "Resource": [my_route53_zone_id.apply(lambda my_route53_zone_id: f"arn:aws:route53:::hostedzone/{my_route53_zone_id}")],
                    "Condition": {
                        "ForAllValues:StringEquals": {
                            "route53:ChangeResourceRecordSetsActions": [
                                "CREATE",
                                "UPSERT",
                                "DELETE",
                            ],
                            "route53:ChangeResourceRecordSetsNormalizedRecordNames": [
                                app_domain_name,
                                f"external-dns-a.{app_domain_name}",
                                f"external-dns-aaaa.{app_domain_name}",
                                f"external-dns-cname.{app_domain_name}",
                            ],
                            "route53:ChangeResourceRecordSetsRecordTypes": [
                                "A",
                                "AAAA",
                                "CNAME",
                                "TXT",
                            ],
                        },
                    },
                },
                {
                    "Effect": "Allow",
                    "Action": ["route53:ListResourceRecordSets"],
                    "Resource": [my_route53_zone_id.apply(lambda my_route53_zone_id: f"arn:aws:route53:::hostedzone/{my_route53_zone_id}")],
                },
                {
                    "Effect": "Allow",
                    "Action": ["route53:ListHostedZones"],
                    "Resource": ["*"],
                },
            ],
        })))
external_dns_pod_identity_association: list[aws.eks.PodIdentityAssociation] = []
for external_dns_pod_identity_association_range in [{"value": i} for i in range(0, 1 if has_route53_zone else 0)]:
    external_dns_pod_identity_association.append(aws.eks.PodIdentityAssociation(f"external_dns-{external_dns_pod_identity_association_range['value']}",
        cluster_name=this_cluster.name,
        namespace=namespace,
        service_account="external-dns",
        role_arn=external_dns[0].arn,
        tags=my_tags))
# RDS Postgres: the control plane's only durable store. Everything else in this
# module can be rebuilt from scratch; this cannot.
# RDS requires a subnet group spanning at least two AZs even for a single-AZ
# instance. The instance itself sits in one AZ unless db_multi_az is set.
this_subnet_group = aws.rds.SubnetGroup("this",
    name=name_prefix,
    subnet_ids=[__item.id for __item in private],
    tags=my_tags)
db = aws.ec2.SecurityGroup("db",
    ingress=[{
        "description": "Postgres from the EKS cluster and its nodes",
        "from_port": 5432,
        "to_port": 5432,
        "protocol": "tcp",
        "security_groups": [this_cluster.vpc_config.cluster_security_group_id],
    }],
    name_prefix=f"{name_prefix}-db-",
    description="RDS Postgres for pontem-control - admits only the EKS cluster security group.",
    vpc_id=this_vpc.id,
    tags=std.merge_output(input=[
        my_tags,
        {
            "name": f"{name_prefix}-db",
        },
    ]).result)
rds: dict[str, aws.cloudwatch.LogGroup] = {}
for rds_range in [{"key": k, "value": v} for [k, v] in sorted(({entry: entry for entry in [
    postgresql,
    upgrade,
]}).items())]:
    rds[rds_range['key']] = aws.cloudwatch.LogGroup(f"rds-{rds_range['key']}",
        name=f"/aws/rds/instance/{name_prefix}/{rds_range['value']}",
        retention_in_days=int(cloudwatch_log_retention_days),
        tags=my_tags)
this_instance = aws.rds.Instance("this",
    identifier=name_prefix,
    engine="postgres",
    engine_version=db_engine_version,
    engine_lifecycle_support="open-source-rds-extended-support-disabled",
    instance_class=db_instance_class,
    allocated_storage=int(db_allocated_storage),
    max_allocated_storage=int(db_max_allocated_storage),
    storage_type=aws.rds.StorageType.GP3,
    storage_encrypted=True,
    db_name=db_name,
    username=db_user,
    password_wo=db_random_password.result,
    password_wo_version=int(db_password_version),
    port=5432,
    db_subnet_group_name=this_subnet_group.name,
    vpc_security_group_ids=[db.id],
    multi_az=db_multi_az,
    publicly_accessible=False,
    backup_retention_period=int(db_backup_retention_period),
    enabled_cloudwatch_logs_exports=[
        "postgresql",
        "upgrade",
    ],
    auto_minor_version_upgrade=True,
    deletion_protection=db_deletion_protection,
    skip_final_snapshot=False,
    final_snapshot_identifier=f"{name_prefix}-final",
    tags=my_tags,
    opts = pulumi.ResourceOptions(depends_on=[rds]))
# A pure rendering submodule lets chart-value tests run without AWS credentials.
chart_values = ChartValues("chartValues", {
    'appDomainName': app_domain_name,
    'awsRegion': region,
    'acmCertificateArn': acm_certificate_arn,
    'clusterName': this_cluster.name,
    'route53ZoneId': my_route53_zone_id,
    'dbPasswordSecretName': db_password.name,
    'deviceJwtSigningKeySecretName': device_jwt_signing_key_secret.name,
    'deviceTelemetryLogGroupName': device_telemetry.name,
    'deviceTelemetryWriterRoleArn': device_telemetry_writer_role.arn,
    'dbHost': this_instance.address,
    'dbPort': this_instance.port.apply(lambda x: float(x)),
    'dbName': this_instance.db_name,
    'dbUser': this_instance.username,
    'oidcIssuer': oidc_issuer,
    'oidcAudience': oidc_audience,
    'oidcClientId': oidc_client_id,
    'wifAudience': wif_audience})
pulumi.export("clusterName", this_cluster.name)
pulumi.export("updateKubeconfigCommand", pulumi.Output.all(
    name=this_cluster.name,
    region=region
).apply(lambda resolved_outputs: f"aws eks update-kubeconfig --name {resolved_outputs['name']} --region {resolved_outputs['region']}")
)
pulumi.export("vpcId", this_vpc.id)
pulumi.export("privateSubnetIds", [__item.id for __item in private])
pulumi.export("dbEndpoint", this_instance.address)
pulumi.export("dbPasswordSecretName", db_password.name)
pulumi.export("deviceJwtSigningKeySecretName", device_jwt_signing_key_secret.name)
pulumi.export("awsAccountId", account_id)
pulumi.export("awsRegion", region)
pulumi.export("cpRuntimeAssumedRoleArn", pulumi.Output.all(
    account_id=account_id,
    name=cp_runtime_role.name
).apply(lambda resolved_outputs: f"arn:aws:sts::{resolved_outputs['account_id']}:assumed-role/{resolved_outputs['name']}")
)
pulumi.export("acmCertificateArn", acm_certificate_arn)
pulumi.export("acmValidationRecords", {} if has_route53_zone else app.domain_validation_options.apply(lambda domain_validation_options: {dvo.domain_name: {
    "name": dvo.resource_record_name,
    "type": dvo.resource_record_type,
    "value": dvo.resource_record_value,
} for dvo in domain_validation_options}))
pulumi.export("route53NameServers", this[0].name_servers if create_route53_zone else None)
pulumi.export("appUrl", f"https://{app_domain_name}")
pulumi.export("helmValues", chart_values.helm_values)
pulumi.export("namespace", namespace)
