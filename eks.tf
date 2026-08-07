# EKS in Auto Mode: AWS runs the data plane — nodes from the built-in
# general-purpose and system pools, ALB ingress, EBS storage, and the core
# add-ons including the Pod Identity agent. There is no managed node group, no
# self-managed load balancer controller, and no add-on resources here, because
# Auto Mode owns all of it.

# ----- Cluster IAM role -----

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect = "Allow"
    # TagSession alongside AssumeRole: Auto Mode tags the session it assumes this
    # role with, and AssumeRole alone is rejected.
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name_prefix}-eks-cluster"
  description        = "Control-plane role for the ${var.name_prefix} EKS cluster."
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster_eks" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# The four Auto Mode managed policies — compute, block storage, load balancing,
# networking. Auto Mode acts through the CLUSTER role, not the node role, which
# is why the node role below is so small.
resource "aws_iam_role_policy_attachment" "cluster_compute" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSComputePolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_block_storage" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_load_balancing" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_networking" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
}

# ----- Cluster -----

# Created ahead of the cluster so retention is ours to set. EKS would otherwise
# auto-create this exact log group on first log delivery, with never-expire
# retention, and bill for it indefinitely.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name_prefix}/cluster"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = local.tags
}

resource "aws_eks_cluster" "this" {
  name                = var.name_prefix
  version             = var.kubernetes_version
  role_arn            = aws_iam_role.cluster.arn
  deletion_protection = var.cluster_deletion_protection

  # The security-relevant control-plane logs. `audit` is the one that matters
  # for after-the-fact questions about who changed what; controllerManager and
  # scheduler are operational noise — add them to this list if a scheduling problem
  # needs them.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Auto-upgrade off standard support rather than paying the extended-support
  # control-plane premium (roughly 6x) when a Kubernetes version ages out.
  upgrade_policy {
    support_type = "STANDARD"
  }

  # CreateCluster rejects Auto Mode with the self-managed add-on bootstrap enabled,
  # since Auto Mode ships its own core components.
  bootstrap_self_managed_addons = false

  # Authorization is EKS access entries only; there is no aws-auth ConfigMap to
  # edit. The creator bootstrap flag stays OFF: it silently mints an access
  # entry for whichever principal ran the apply, which then collides with the
  # explicit entry below (ResourceInUseException) whenever that principal is
  # also in cluster_admin_principal_arns — which it should be. Declaring every
  # admin explicitly is the predictable version.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    # Control-plane ENIs go in the private subnets. The public endpoint stays
    # on, restricted to cluster_endpoint_public_access_cidrs, so kubectl works
    # without standing up a bastion or a VPN first; the private endpoint is on
    # too so in-cluster traffic never leaves the VPC to reach the API.
    subnet_ids              = aws_subnet.private[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  # Auto Mode: these three blocks toggle together — enabling compute without
  # elastic load balancing and block storage is rejected.
  # EKS creates the node role's access entry and policy association.
  compute_config {
    enabled       = true
    node_pools    = ["general-purpose", "system"]
    node_role_arn = aws_iam_role.auto_node.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster_eks,
    aws_iam_role_policy_attachment.cluster_compute,
    aws_iam_role_policy_attachment.cluster_block_storage,
    aws_iam_role_policy_attachment.cluster_load_balancing,
    aws_iam_role_policy_attachment.cluster_networking,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ----- Node IAM role -----

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "auto_node" {
  name               = "${var.name_prefix}-eks-auto-node"
  description        = "Node role for Auto Mode-launched nodes in the ${var.name_prefix} cluster."
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  tags = local.tags
}

# Auto Mode nodes get their networking permissions from the cluster role, so the
# node role only needs the minimal worker policy plus image pull.
resource "aws_iam_role_policy_attachment" "auto_node_minimal" {
  role       = aws_iam_role.auto_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy"
}

# PullOnly, not ReadOnly: PullOnly's ecr:BatchImportUpstreamImage covers pulling
# from a registry in another AWS account, which is what these nodes do, and it
# grants nothing beyond pull. Getting this wrong presents as images that never
# pull, and it reads as a registry-policy problem.
resource "aws_iam_role_policy_attachment" "auto_node_ecr_pull" {
  role       = aws_iam_role.auto_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

# ----- Access entries -----

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value

  tags = local.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
