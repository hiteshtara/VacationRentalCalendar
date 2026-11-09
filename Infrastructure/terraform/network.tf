# Aurora lives in a VPC even though nothing else does: a DB subnet group must
# span at least two availability zones. These subnets are private and have no
# route to the internet -- no internet gateway, no NAT gateway, no VPC
# endpoints. That is deliberate and is what keeps the bill at zero here: the
# Lambdas never join this VPC, they reach the database through the RDS Data
# API, which is a regional AWS endpoint rather than a network path.
#
# A NAT gateway would be about $32/month, more than every other line item in
# this system combined.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "db" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "vrc-db" }
}

resource "aws_subnet" "db" {
  count             = 3
  vpc_id            = aws_vpc.db.id
  cidr_block        = cidrsubnet(aws_vpc.db.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "vrc-db-${count.index}" }
}

resource "aws_db_subnet_group" "db" {
  name       = "vrc-db"
  subnet_ids = aws_subnet.db[*].id
}

# No ingress at all. The Data API does not connect through the VPC, so nothing
# needs to reach the cluster over the network. An empty ingress list is the
# point, not an omission.
resource "aws_security_group" "db" {
  name        = "vrc-db"
  description = "Aurora cluster. No ingress: access is via the RDS Data API only."
  vpc_id      = aws_vpc.db.id

  egress {
    description = "Cluster-internal only."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.db.cidr_block]
  }
}
