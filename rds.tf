# RDS Postgres: the control plane's only durable store. Everything else in this
# module can be rebuilt from scratch; this cannot.

# RDS requires a subnet group spanning at least two AZs even for a single-AZ
# instance. The instance itself sits in one AZ unless db_multi_az is set.
resource "aws_db_subnet_group" "this" {
  name       = var.name_prefix
  subnet_ids = aws_subnet.private[*].id

  tags = local.tags
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name_prefix}-db-"
  description = "RDS Postgres for pontem-control - admits only the EKS cluster security group."
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres from the EKS cluster and its nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }

  # No egress rule on purpose: RDS opens no outbound connections, and security
  # groups are stateful, so replies to admitted traffic flow without one.

  # An SG's name and description are both ForceNew, and AWS refuses to delete a
  # security group still attached to the RDS network interfaces — so a
  # destroy-first replacement deadlocks on DependencyViolation and the apply
  # hangs until it times out. name_prefix plus create_before_destroy lets the
  # replacement exist before the old group is released.
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-db"
  })
}

# The keepers tie this password's lifetime to the instance's stable identity, so
# it rotates only if the instance is renamed or moves region — never as a side
# effect of an unrelated change elsewhere in the module.
#
# RDS engines disagree on allowed punctuation; 32 alphanumeric characters avoid
# that compatibility surface while retaining about 190 bits of entropy.
resource "random_password" "db" {
  length  = 32
  special = false

  keepers = {
    identifier = var.name_prefix
    region     = local.region
  }
}

resource "aws_db_instance" "this" {
  identifier = var.name_prefix

  # Major-only pins the family and lets RDS pick and patch the minor
  # (auto_minor_version_upgrade defaults to true).
  engine         = "postgres"
  engine_version = var.db_engine_version

  # Do not auto-enroll in paid RDS Extended Support when this major leaves
  # standard support — upgrade instead, matching the cluster's STANDARD upgrade
  # policy. The API only honors this at create/restore time, so it cannot be
  # retrofitted onto an existing instance.
  engine_lifecycle_support = "open-source-rds-extended-support-disabled"

  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_user
  password = random_password.db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  multi_az = var.db_multi_az

  # The database is reachable only from inside the VPC, via the security group
  # above. Nothing in this module gives it a public address.
  publicly_accessible = false

  backup_retention_period = var.db_backup_retention_period

  # Explicit rather than left to the provider default: the failure this prevents is
  # an instance that quietly stops taking security patches.
  auto_minor_version_upgrade = true

  deletion_protection = var.db_deletion_protection

  # Take a final snapshot on delete. Combined with deletion_protection this
  # means destroying the database is a two-step, deliberate act.
  #
  # The snapshot name is fixed rather than time-stamped, because a timestamp in
  # this attribute plans a diff on every single apply. The consequence is that a
  # second destroy in the same account fails: RDS rejects a final snapshot whose
  # identifier already exists. Deleting or renaming the old snapshot is the fix,
  # and the README says so.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-final"

  tags = local.tags

  # A precondition rather than a variable validation: validation blocks could not
  # reference a second variable until Terraform 1.9, and this module supports 1.6.
  # RDS rejects a non-zero autoscaling ceiling below the initial size, so without
  # this the apply fails at instance creation rather than at plan.
  lifecycle {
    precondition {
      condition     = var.db_max_allocated_storage >= var.db_allocated_storage
      error_message = "db_max_allocated_storage (${var.db_max_allocated_storage}) must be greater than or equal to db_allocated_storage (${var.db_allocated_storage}); RDS rejects a storage-autoscaling ceiling below the initial size."
    }
  }
}
