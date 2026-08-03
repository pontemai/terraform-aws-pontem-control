# Dedicated VPC: one public and one private subnet per availability zone, an
# internet gateway, and NAT. The cluster's nodes, its load balancers, and the
# database all land in these subnets. Nothing here is shared with anything else
# in the account.

data "aws_availability_zones" "available" {
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
  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # Subnets four bits narrower than the VPC block (/20 out of the default /16):
  # public subnets from the bottom, private starting half-way up, so the two
  # ranges never interleave and adding an AZ appends a subnet instead of
  # renumbering — renumbering would replace an existing subnet, and with it
  # everything running in that subnet.
  public_subnet_cidrs  = [for i in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  nat_gateway_count = var.single_nat_gateway ? 1 : var.availability_zone_count
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both required for EKS: nodes and pods resolve the cluster endpoint and the
  # RDS endpoint by DNS name.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = var.name_prefix
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = var.name_prefix
  })
}

# The kubernetes.io/role/* tags below are load-bearing: EKS Auto Mode's built-in
# load balancer controller discovers which subnets to place internet-facing and
# internal load balancers in by reading them. Without them, an Ingress is
# created and then never gets an address.

resource "aws_subnet" "public" {
  count = var.availability_zone_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                     = "${var.name_prefix}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count = var.availability_zone_count

  vpc_id            = aws_vpc.this.id
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
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_route_table_association" "public" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ even when sharing a single NAT gateway: the
# tables are free, and it means flipping single_nat_gateway later re-points
# routes instead of restructuring the tables.
resource "aws_route_table" "private" {
  count = var.availability_zone_count

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
  })
}

resource "aws_route_table_association" "private" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
