# Region and account id are read from the provider (locals.tf) rather than taken
# as variables: a module should not second-guess the credentials and region its
# caller configured, and two sources of truth for the region is a way to build
# resources in one region and point the chart at another.

# ----- Required: no defaults, because a wrong default here is dangerous -----

variable "app_domain_name" {
  description = "Hostname the control plane is served at, e.g. \"pontem.example.com\". The ACM certificate covers exactly this name, and it becomes the chart's ingress.domain. Changing it replaces the certificate only — safe, and the old one stays attached until the new one is issued."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.app_domain_name))
    error_message = "app_domain_name must be a bare lowercase hostname with at least one dot (e.g. \"pontem.example.com\") — no scheme, port, or trailing dot."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs granted cluster-admin on the EKS cluster via access entries. This is the ONLY path to the Kubernetes API: the cluster-creator bootstrap flag is off deliberately (see eks.tf), so a principal absent from this list cannot run kubectl no matter what IAM permissions it holds. Include the principal that will run the install steps, or the install cannot proceed."
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
  description = "CIDRs allowed to reach the public EKS API endpoint. There is no default on purpose: the internal Pontem stack this is distilled from leaves the endpoint world-open with a \"tighten before prod\" note, which is not a posture to ship to someone else. Use [\"0.0.0.0/0\"] only if you have decided that deliberately; the API is still IAM-gated, but so is everything an attacker would try against it."
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
  description = "Prefix for every resource name this module creates. CHANGING THIS REPLACES THE CLUSTER AND THE DATABASE — the names are the resources' identity, so a new prefix means new resources and the old data is destroyed. Pick it once, before the first apply."
  type        = string
  default     = "pontem-control"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-32 lowercase alphanumeric-or-hyphen characters starting with a letter (it seeds RDS and EKS names, which are stricter than most)."
  }

  # Checked separately from the character-class rule above so the message can say
  # what is actually wrong. RDS rejects a doubled hyphen in an instance identifier,
  # and it rejects it at instance creation — after the VPC, the NAT gateways, and a
  # fifteen-minute cluster create have all succeeded.
  validation {
    condition     = !can(regex("--", var.name_prefix))
    error_message = "name_prefix must not contain two consecutive hyphens — RDS rejects them in a database identifier."
  }
}

variable "tags" {
  description = "Extra tags merged onto every resource this module creates, on top of its own Project/ManagedBy tags."
  type        = map(string)
  default     = {}
}

# ----- Networking -----

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC. Needs room for /20 subnets per AZ (public + private), so /16 is the comfortable choice. CHANGING THIS REPLACES THE VPC and everything inside it, including the cluster and the database."
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
  description = "Route all private-subnet egress through one NAT gateway instead of one per AZ. Default false (one per AZ) because a shared NAT makes every AZ's egress depend on the NAT's AZ staying up. Setting it true saves roughly $33/month per AZ you drop and is a reasonable trade for an evaluation, not for production."
  type        = bool
  default     = false
}

# ----- EKS -----

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Must be >= 1.30: the pontem-control chart uses the native preStop sleep action, which does not exist before 1.30. Keep this near the newest version EKS offers — the cluster's upgrade policy is STANDARD, so a version that leaves standard support gets auto-upgraded rather than billed at the extended-support premium."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version)) && tonumber(split(".", var.kubernetes_version)[1]) >= 30
    error_message = "kubernetes_version must be >= 1.30, major.minor only (e.g. \"1.36\") — pontem-control uses the native preStop sleep action."
  }
}

variable "cloudwatch_log_retention_days" {
  description = "Retention for the EKS control-plane log group. The log group is created here rather than left to EKS, which would create it with never-expire retention and bill for it forever."
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
  description = "RDS instance class. db.t4g.medium (2 vCPU / 4 GiB) is a sane starting point for a small fleet; the control plane's connection budget is modest but its query pattern is chatty. Changing this is an in-place modification with a short failover, not a replacement."
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
  description = "Ceiling for RDS storage autoscaling, in GiB. Must exceed db_allocated_storage or autoscaling is effectively off."
  type        = number
  default     = 200
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
  description = "Run the database as a Multi-AZ deployment with a synchronous standby. Default true: this is the control plane's only durable store, and a single-AZ instance turns an AZ event into a full outage plus a restore. Roughly doubles the instance cost — the honest knob to turn down for an evaluation."
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
  description = "Refuse to delete the database instance. Default true, which means a `terraform destroy` fails until you set this false and apply — deliberate friction on the one resource whose loss is unrecoverable."
  type        = bool
  default     = true
}

# ----- Secrets -----

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window for the secrets this module creates. AWS keeps a deleted secret NAME reserved for this long and rejects re-creating it, so `terraform destroy` followed by a fresh apply fails with an \"already scheduled for deletion\" error until the window expires. That is the trade for being able to recover a secret you deleted by mistake; set it to 0 if you are repeatedly building and tearing down a trial stack."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 (force-delete immediately) or between 7 and 30 — Secrets Manager rejects everything in between."
  }
}

# ----- DNS / TLS -----

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for app_domain_name. Set it and the module creates the ACM validation records and waits for the certificate to be issued. Leave it null and the records are emitted as the acm_validation_records output for you to create wherever your DNS lives; no waiter is added in that case, because a waiter would block every future apply on a manual step."
  type        = string
  default     = null
}

# ----- Kubernetes-side contract -----

variable "namespace" {
  description = "Kubernetes namespace the chart is installed into. The Pod Identity associations bind service accounts in this namespace, so it must match the namespace you pass to `helm install`; if they drift, the pods start but get no AWS credentials."
  type        = string
  default     = "pontem-control"
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

variable "enable_external_secrets_iam" {
  description = "Create the IAM role and Pod Identity association for External Secrets Operator, so ESO can read the two boot secrets instead of you copying them into a Kubernetes Secret by hand (README covers both paths). Harmless if you never install ESO: an association binds by service-account name and does nothing until a matching pod runs."
  type        = bool
  default     = true
}

variable "external_secrets_namespace" {
  description = "Namespace the External Secrets Operator controller runs in. Only used when enable_external_secrets_iam is true; matches the ESO chart's own default."
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_service_account" {
  description = "Service account the External Secrets Operator controller runs as. Only used when enable_external_secrets_iam is true; matches the ESO chart's own default."
  type        = string
  default     = "external-secrets"
}

# ----- Your identity provider -----
#
# All three are required, and all three are public metadata your users' browsers
# already fetch — none is a secret. Two consumers need them: the API validates
# bearer tokens against the issuer and audience, and the admin single-page app
# needs the issuer, audience, AND client id to start at all. Miss the client id
# and the API works while the admin UI serves a blank page, so there is no
# default for any of them.

variable "oidc_issuer" {
  description = "OIDC issuer URL, e.g. \"https://your-tenant.us.auth0.com/\". Must be a bare https origin with no path: the admin app is configured with the host on its own, which this module derives by stripping the scheme, so an issuer with a path cannot be expressed there."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+/?$", var.oidc_issuer))
    error_message = "oidc_issuer must be an https origin with no path, e.g. \"https://your-tenant.us.auth0.com/\". A provider whose issuer carries a path (some Okta and Keycloak setups) cannot drive the admin app, which takes the host alone."
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

variable "oidc_client_id" {
  description = "Client ID of the public single-page-app client the admin UI signs in with. Needed only by the browser; the API never sees it. Without it the admin UI renders a blank page while every pod reports healthy."
  type        = string

  validation {
    condition     = length(var.oidc_client_id) > 0
    error_message = "oidc_client_id must be set — the admin UI cannot start without it."
  }
}
