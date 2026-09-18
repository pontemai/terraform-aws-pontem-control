# Without vpc_id this module owns the network. Supplied networks are read only;
# their DNS and subnet checks must pass before workload resources can use them.

data "aws_availability_zones" "available" {
  count = local.create_vpc ? 1 : 0

  state = "available"

  # Standard AZs only. Local and Wavelength Zone names sort BEFORE plain AZs
  # ("us-east-1-atl-1a" < "us-east-1a"), so if the account has opted into one,
  # it would win the slice below — and EKS control-plane subnets cannot live in
  # a Local Zone. The failure is a cluster create that rejects its own subnets,
  # with nothing in the message pointing at Local Zones.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  create_vpc = var.vpc_id == null
  azs        = local.create_vpc ? slice(data.aws_availability_zones.available[0].names, 0, var.availability_zone_count) : []

  vpc_id             = local.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id
  private_subnet_ids = local.create_vpc ? aws_subnet.private[*].id : data.aws_subnet.private[*].id
  public_subnet_ids  = local.create_vpc ? aws_subnet.public[*].id : data.aws_subnet.public[*].id
  alb_subnet_ids     = local.create_vpc ? [] : (var.alb_scheme == "internal" ? local.private_subnet_ids : local.public_subnet_ids)

  # Subnets four bits narrower than the VPC block (/20 out of the default /16):
  # public subnets from the bottom, private starting half-way up, so the two
  # ranges never interleave and adding an AZ appends a subnet instead of
  # renumbering — renumbering would replace an existing subnet, and with it
  # everything running in that subnet.
  public_subnet_cidrs  = [for i in range(local.create_vpc ? var.availability_zone_count : 0) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(local.create_vpc ? var.availability_zone_count : 0) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  nat_gateway_count = local.create_vpc ? (var.single_nat_gateway ? 1 : var.availability_zone_count) : 0
}

resource "aws_vpc" "this" {
  count = local.create_vpc ? 1 : 0

  cidr_block = var.vpc_cidr

  # Both required for EKS: nodes and pods resolve the cluster endpoint and the
  # RDS endpoint by DNS name.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = var.name_prefix
  })
}

resource "aws_default_security_group" "this" {
  count = local.create_vpc ? 1 : 0

  vpc_id  = aws_vpc.this[0].id
  ingress = []
  egress  = []

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-default"
  })
}

resource "aws_internet_gateway" "this" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(local.tags, {
    Name = var.name_prefix
  })
}

# The kubernetes.io/role/* tags below are load-bearing: EKS Auto Mode's built-in
# load balancer controller discovers which subnets to place internet-facing and
# internal load balancers in by reading them. Without them, an Ingress is
# created and then never gets an address.

resource "aws_subnet" "public" {
  count = local.create_vpc ? var.availability_zone_count : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name                     = "${var.name_prefix}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count = local.create_vpc ? var.availability_zone_count : 0

  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name                              = "${var.name_prefix}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-nat-${count.index}"
  })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-${local.azs[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_route_table_association" "public" {
  count = local.create_vpc ? var.availability_zone_count : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# One private route table per AZ even when sharing a single NAT gateway: the
# tables are free, and it means flipping single_nat_gateway later re-points
# routes instead of restructuring the tables.
resource "aws_route_table" "private" {
  count = local.create_vpc ? var.availability_zone_count : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
  })
}

resource "aws_route_table_association" "private" {
  count = local.create_vpc ? var.availability_zone_count : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

moved {
  from = aws_vpc.this
  to   = aws_vpc.this[0]
}

moved {
  from = aws_default_security_group.this
  to   = aws_default_security_group.this[0]
}

moved {
  from = aws_internet_gateway.this
  to   = aws_internet_gateway.this[0]
}

moved {
  from = aws_route_table.public
  to   = aws_route_table.public[0]
}

# List indices let subnet IDs be unknown until apply, as long as the list lengths
# and VPC mode are known during planning.
data "aws_subnet" "private" {
  count = local.create_vpc ? 0 : length(var.private_subnet_ids)
  id    = var.private_subnet_ids[count.index]
}

data "aws_subnet" "public" {
  count = local.create_vpc ? 0 : length(var.public_subnet_ids)
  id    = var.public_subnet_ids[count.index]
}

data "aws_availability_zones" "existing" {
  count = local.create_vpc ? 0 : 1
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

data "aws_vpc" "existing" {
  count = local.create_vpc ? 0 : 1
  id    = var.vpc_id

  lifecycle {
    postcondition {
      condition     = self.enable_dns_support && self.enable_dns_hostnames
      error_message = "The supplied VPC must enable DNS support and DNS hostnames."
    }

    postcondition {
      condition     = alltrue([for subnet in concat(data.aws_subnet.private, data.aws_subnet.public) : subnet.vpc_id == self.id])
      error_message = "All supplied subnets must belong to vpc_id."
    }

    postcondition {
      condition     = alltrue([for subnet in concat(data.aws_subnet.private, data.aws_subnet.public) : contains(data.aws_availability_zones.existing[0].names, subnet.availability_zone)])
      error_message = "All supplied subnets must be in available standard availability zones in the provider's region."
    }

    postcondition {
      condition     = length(distinct(data.aws_subnet.private[*].availability_zone)) >= 2
      error_message = "Private subnets must span at least two availability zones for EKS and RDS."
    }

    postcondition {
      condition = var.alb_scheme == "internal" ? (
        length(distinct(data.aws_subnet.private[*].availability_zone)) == length(var.private_subnet_ids)
        ) : (
        length(distinct(data.aws_subnet.public[*].availability_zone)) >= 2 &&
        length(distinct(data.aws_subnet.public[*].availability_zone)) == length(var.public_subnet_ids)
      )
      error_message = "ALB subnets must include exactly one subnet per AZ in at least two AZs (private for internal, public for internet-facing)."
    }
  }
}
