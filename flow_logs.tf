# VPC Flow Logs record network metadata, not packet contents, in CloudWatch with
# the module's retention setting.

resource "aws_cloudwatch_log_group" "vpc_flow" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = local.tags
}

resource "aws_iam_role" "vpc_flow" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name        = "${var.name_prefix}-vpc-flow-logs"
  description = "Lets VPC Flow Logs publish network metadata to this module's CloudWatch log group."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:ec2:${local.region}:${local.account_id}:vpc-flow-log/*"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "vpc_flow" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name = "${var.name_prefix}-vpc-flow-logs"
  role = aws_iam_role.vpc_flow[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.vpc_flow[0].arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      },
    ]
  })
}

resource "aws_flow_log" "vpc" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  iam_role_arn    = aws_iam_role.vpc_flow[0].arn
  log_destination = aws_cloudwatch_log_group.vpc_flow[0].arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.this.id

  tags = local.tags

  depends_on = [aws_iam_role_policy.vpc_flow]
}
