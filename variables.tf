# Region and account ID come from the provider so callers have one source of truth.

# ----- Required: no defaults, because a wrong default here is dangerous -----

variable "app_domain_name" {
  description = "Hostname the control plane is served at, e.g. \"pontem.example.com\". The ACM certificate covers exactly this name, and it becomes the chart's ingress.domain. Changing it replaces the certificate and nothing else; the old certificate stays attached until the new one is issued."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.app_domain_name))
    error_message = "app_domain_name must be a bare lowercase hostname with at least one dot (e.g. \"pontem.example.com\") — no scheme, port, or trailing dot."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs granted cluster-admin on the EKS cluster. This is the ONLY path to the Kubernetes API: a principal absent from this list cannot run kubectl no matter what IAM permissions it holds, including the one that created the cluster. Include the principal that will run the install steps, or the install cannot proceed."
  type        = list(string)

  validation {
    condition     = length(var.cluster_admin_principal_arns) > 0
    error_message = "cluster_admin_principal_arns must list at least one principal — with the cluster-creator bootstrap flag off, an empty list leaves nobody able to reach the Kubernetes API."
  }

  validation {
    condition     = alltrue([for arn in var.cluster_admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/", arn))])
    error_message = "Each entry must be an IAM role or user ARN (arn:aws:iam::<account>:role/... or :user/...). EKS access entries reject the assumed-role/sts form — use the role's own ARN."
  }
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Anything outside them cannot reach the Kubernetes API at all; the endpoint is also IAM-gated independently of this list. [\"0.0.0.0/0\"] allows every source."
  type        = list(string)

  validation {
    condition     = length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "cluster_endpoint_public_access_cidrs must list at least one CIDR — the private endpoint alone would leave the API reachable only from inside the VPC, which this module gives you no bastion for."
  }

  validation {
    condition     = alltrue([for cidr in var.cluster_endpoint_public_access_cidrs : can(cidrnetmask(cidr))])
    error_message = "Each entry must be a valid IPv4 CIDR block (e.g. \"203.0.113.0/24\")."
  }
}

# ----- Naming -----

variable "name_prefix" {
  description = "Prefix for every resource name this module creates. CHANGING THIS REPLACES THE CLUSTER AND THE DATABASE, destroying the data in them. Two stacks in one account need different prefixes."
  type        = string
  default     = "pontem-control"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-32 lowercase alphanumeric-or-hyphen characters starting with a letter (it seeds RDS and EKS names, which are stricter than most)."
  }

  # Keep the RDS-specific error separate so it is clear and arrives before creation.
  validation {
    condition     = !can(regex("--", var.name_prefix))
    error_message = "name_prefix must not contain two consecutive hyphens — RDS rejects them in a database identifier."
  }

  # Keep boot-secret names outside the tenant-secret grants in locals.tf.
  validation {
    condition     = !can(regex("^(registry-)?tenant", var.name_prefix))
    error_message = "name_prefix must not begin with \"tenant\" or \"registry-tenant\": those prefixes name the per-tenant secrets the application pods can already read, so the module's own database password and signing key would fall inside that grant."
  }
}

variable "tags" {
  description = "Extra tags merged onto every resource this module creates, on top of its own Project/ManagedBy tags."
  type        = map(string)
  default     = {}
}

# ----- Networking -----

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC. It is carved into one public and one private subnet per availability zone, each four bits narrower than this block — /20 subnets out of the default /16. CHANGING THIS REPLACES THE VPC and everything inside it, including the cluster and the database."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR of /20 or larger (a smaller block cannot be carved into the per-AZ subnets this module creates)."
  }
}

variable "availability_zone_count" {
  description = "How many availability zones to spread subnets across. Two is the floor: EKS requires its control-plane subnets in at least two AZs, and so does the RDS subnet group even for a single-AZ instance. Raising it appends a subnet, NAT gateway, and route table per new zone and leaves the existing ones alone; lowering it destroys the highest-numbered zone's subnets and anything running in them."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4 && floor(var.availability_zone_count) == var.availability_zone_count
    error_message = "availability_zone_count must be a whole number between 2 and 4 (EKS and the RDS subnet group both require at least two AZs)."
  }
}

variable "single_nat_gateway" {
  description = "Route all private-subnet egress through one NAT gateway instead of one per AZ. True saves roughly $33/month per AZ dropped, and makes outbound traffic from every AZ depend on the one NAT gateway's AZ staying up."
  type        = bool
  default     = false
}

variable "enable_vpc_flow_logs" {
  description = "Capture all VPC traffic metadata in CloudWatch. This adds CloudWatch ingestion and storage costs."
  type        = bool
  default     = true
}

# ----- EKS -----

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Must be >= 1.30: the pontem-control chart uses the native preStop sleep action, which does not exist before 1.30. The cluster's upgrade policy is STANDARD, so AWS auto-upgrades a version once it leaves standard support — after that happens, this must be raised to the version the cluster is actually on or every apply fails proposing a downgrade."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version)) && tonumber(split(".", var.kubernetes_version)[1]) >= 30
    error_message = "kubernetes_version must be >= 1.30, major.minor only (e.g. \"1.36\") — pontem-control uses the native preStop sleep action."
  }
}

variable "cluster_deletion_protection" {
  description = "Refuse to delete the EKS cluster. While true, `terraform destroy` fails until it is set false and applied."
  type        = bool
  default     = true
}

variable "cloudwatch_log_retention_days" {
  description = "Retention for the module's device, EKS, RDS, and VPC Flow Log groups. 0 keeps them forever."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653, 0], var.cloudwatch_log_retention_days)
    error_message = "cloudwatch_log_retention_days must be one of the values CloudWatch accepts (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653) or 0 for never expire."
  }
}

# ----- Database -----

variable "db_engine_version" {
  description = "RDS Postgres MAJOR version. Major-only on purpose: RDS then owns the minor and patches it, whereas pinning a minor fights auto_minor_version_upgrade and eventually plans an impossible downgrade."
  type        = string
  default     = "18"

  validation {
    condition     = can(regex("^[0-9]+$", var.db_engine_version))
    error_message = "db_engine_version must be a major version only (e.g. \"18\")."
  }
}

variable "db_instance_class" {
  description = "RDS instance class. Changing it is an in-place modification with a short failover, not a replacement."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GiB. Storage autoscaling is on (see db_max_allocated_storage), so this is a starting point, not a ceiling."
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20
    error_message = "db_allocated_storage must be at least 20 GiB (the RDS minimum for gp3 Postgres)."
  }
}

variable "db_max_allocated_storage" {
  description = "Ceiling for RDS storage autoscaling, in GiB. Must be at least db_allocated_storage."
  type        = number
  default     = 200

  validation {
    condition     = var.db_max_allocated_storage >= var.db_allocated_storage
    error_message = "db_max_allocated_storage must be greater than or equal to db_allocated_storage."
  }
}

variable "db_name" {
  description = "Application database name inside the instance. CHANGING THIS REPLACES THE DATABASE INSTANCE and destroys its data."
  type        = string
  default     = "pontem"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must start with a letter and contain only letters, digits, and underscores (Postgres identifier rules as RDS enforces them)."
  }
}

variable "db_user" {
  description = "Postgres user the application authenticates as. This is the instance's master user, so it is created with the instance; CHANGING IT REPLACES THE DATABASE."
  type        = string
  default     = "app"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.db_user))
    error_message = "db_user must start with a letter and contain only letters, digits, and underscores."
  }
}

variable "db_multi_az" {
  description = "Run the database as a Multi-AZ deployment with a synchronous standby. Roughly doubles the instance cost. False turns an AZ failure into an outage plus a restore from backup; the database is the control plane's only durable store."
  type        = bool
  default     = true
}

variable "db_backup_retention_period" {
  description = "Days of automated RDS backups. Also the window for point-in-time recovery, which is the only thing that recovers from a bad migration or a mistaken delete. Zero disables backups entirely."
  type        = number
  default     = 14

  validation {
    condition     = var.db_backup_retention_period >= 0 && var.db_backup_retention_period <= 35
    error_message = "db_backup_retention_period must be between 0 and 35 days (the RDS limit)."
  }
}

variable "db_deletion_protection" {
  description = "Refuse to delete the database instance. While true, `terraform destroy` fails until it is set false and applied."
  type        = bool
  default     = true
}

# ----- Secrets -----

variable "db_password_version" {
  description = "Version of the generated database password. Raising it changes the secret and RDS password, but running pods keep the old value until restarted."
  type        = number
  default     = 1

  validation {
    condition     = var.db_password_version >= 1 && floor(var.db_password_version) == var.db_password_version
    error_message = "db_password_version must be a positive whole number."
  }
}

variable "device_jwt_signing_key_version" {
  description = "Version of the generated device JWT signing key. Raising this value invalidates every enrolled device's JWT."
  type        = number
  default     = 1

  validation {
    condition     = var.device_jwt_signing_key_version >= 1 && floor(var.device_jwt_signing_key_version) == var.device_jwt_signing_key_version
    error_message = "device_jwt_signing_key_version must be a positive whole number."
  }
}

variable "secret_recovery_window_days" {
  description = "Days a deleted secret stays recoverable. AWS keeps the deleted secret's NAME reserved for this long and rejects re-creating it, so `terraform destroy` followed by a fresh apply fails with \"already scheduled for deletion\" until the window expires. 0 deletes immediately, which makes repeated build-and-tear-down cycles work."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 (force-delete immediately) or between 7 and 30 — Secrets Manager rejects everything in between."
  }
}

# ----- DNS / TLS -----

variable "route53_zone_id" {
  description = "ID of an existing Route53 hosted zone for app_domain_name. Set this or create_route53_zone to automate ACM validation and application DNS. Leave both unset to create the returned acm_validation_records yourself."
  type        = string
  default     = null

  validation {
    condition     = var.route53_zone_id == null || can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must be null or a Route53 hosted zone ID beginning with Z."
  }

  validation {
    condition     = var.route53_zone_id == null || !var.create_route53_zone
    error_message = "Set only one of route53_zone_id or create_route53_zone."
  }
}

variable "create_route53_zone" {
  description = "Create a Route53 hosted zone for app_domain_name. Cannot be used with route53_zone_id. Delegate the hostname to route53_name_servers before the full apply; see the README."
  type        = bool
  default     = false
}

# ----- Kubernetes-side contract -----

variable "namespace" {
  description = "Kubernetes namespace the chart is installed into. The Pod Identity associations bind service accounts in this namespace, so it must match the namespace you pass to `helm install`; if they drift, the pods start but get no AWS credentials."
  type        = string
  default     = "pontem-control"
}

variable "aws_organization_id" {
  description = "Optional AWS Organizations ID (for example, o-abc123def456). When set, Pod Identity roles also require their source to belong to this organization."
  type        = string
  default     = null

  validation {
    condition     = var.aws_organization_id == null || can(regex("^o-[a-z0-9]{10,32}$", var.aws_organization_id))
    error_message = "aws_organization_id must be null or an AWS Organizations ID such as o-abc123def456."
  }
}

variable "pod_identity_service_accounts" {
  description = "Service accounts in `namespace` bound to the control-plane runtime role. The chart's api and worker pods both need AWS credentials for tenant-secret storage. Add \"mcp\" only if you enable the mcp deployment (it is off unless you set mcp.host in the chart)."
  type        = list(string)
  default     = ["api", "worker"]

  validation {
    condition     = length(var.pod_identity_service_accounts) > 0
    error_message = "pod_identity_service_accounts must not be empty — with no association the pods get no AWS credentials and tenant-secret operations fail with AccessDenied."
  }
}

# ----- Your identity provider -----
#
# The OIDC issuer, audience, and client ID are public and have no defaults.

variable "oidc_issuer" {
  description = "OIDC issuer URL, e.g. \"https://your-tenant.us.auth0.com/\". Must be a bare https origin with no path: the admin app is configured with the host on its own, which this module derives by stripping the scheme, so an issuer with a path cannot be expressed there."
  type        = string

  # The chart-values module lowercases this host for the admin app.
  validation {
    condition     = can(regex("^https://[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+/?$", var.oidc_issuer))
    error_message = "oidc_issuer must be an https origin with no path or port, e.g. \"https://your-tenant.us.auth0.com/\". A provider whose issuer carries a path (some Okta and Keycloak setups) cannot drive the admin app, which takes the host alone."
  }
}

variable "oidc_audience" {
  description = "OIDC API audience the control plane validates access tokens against, and that the admin app requests tokens for. These must be the same value or the API rejects every token the UI sends."
  type        = string

  validation {
    condition     = length(var.oidc_audience) > 0
    error_message = "oidc_audience must be set."
  }
}

variable "wif_audience" {
  description = "GCP Workload Identity Federation audience, which Pontem issues once it has your account id and the control-plane runtime role ARN (both are outputs of this module). Until you set it, the rendered chart values carry the placeholder below; the chart rejects only an EMPTY audience, so an install that keeps the placeholder succeeds and then fails the first time a managed agent package is pulled."
  type        = string
  default     = "REPLACE_ME_PONTEM_SUPPLIED"
}

variable "oidc_client_id" {
  description = "Client ID of the public single-page-app client the admin UI signs in with. Used only by the browser; the API never sees it. Without it the admin UI renders a blank page while every pod reports healthy."
  type        = string

  validation {
    condition     = length(var.oidc_client_id) > 0
    error_message = "oidc_client_id must be set — the admin UI cannot start without it."
  }
}
