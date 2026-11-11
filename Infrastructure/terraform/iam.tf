# One runtime role per Lambda, each able to do only its own job. The point of
# the split is the fetcher: it is the component that parses untrusted
# third-party feed content, and it holds no database credential and no
# outbound token.

data "aws_caller_identity" "current" {}

locals {
  lambda_assume = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  data_api_actions = [
    "rds-data:ExecuteStatement",
    "rds-data:BatchExecuteStatement",
    "rds-data:BeginTransaction",
    "rds-data:CommitTransaction",
    "rds-data:RollbackTransaction",
  ]
}

resource "aws_iam_role" "fetcher" {
  name               = "${local.prefix}-lambda-fetcher"
  assume_role_policy = local.lambda_assume
}

resource "aws_iam_role_policy" "fetcher" {
  name = "fetcher"
  role = aws_iam_role.fetcher.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ReadSourceCredentialsOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.source_feed_urls.arn]
      },
      {
        Sid      = "WriteRawPayloadsAndReadPriorHashes"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["${aws_s3_bucket.main["raw"].arn}/*"]
      },
      ], var.allow_priyankahomes_read ? [
      {
        # Read-only, and only these two tables. No PutItem, no UpdateItem,
        # no DeleteItem, no wildcard. The website's data is observed, never
        # participated in -- and in staging this grant does not exist at all,
        # so staging cannot reach production booking data even to read it.
        Sid      = "ReadPriyankaHomesSourceTables"
        Effect   = "Allow"
        Action   = ["dynamodb:BatchGetItem", "dynamodb:GetItem", "dynamodb:DescribeTable"]
        Resource = var.priyankahomes_table_arns
      },
      ] : [], [
      {
        # The one write the fetcher may perform, and it is not a data write:
        # waking the processor when a feed has genuinely changed. Scoped to
        # that single function.
        Sid      = "WakeTheProcessorOnChange"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = ["arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${local.prefix}-process"]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-fetch:*"]
      },
    ])
  })
}

resource "aws_iam_role" "processor" {
  name               = "${local.prefix}-lambda-processor"
  assume_role_policy = local.lambda_assume
}

resource "aws_iam_role_policy" "processor" {
  name = "processor"
  role = aws_iam_role.processor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteViaDataApi"
        Effect   = "Allow"
        Action   = local.data_api_actions
        Resource = [aws_rds_cluster.main.arn]
      },
      {
        Sid      = "ReadRestrictedDatabaseCredential"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_runtime.arn]
      },
      {
        Sid      = "ReadRawPayloads"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.main["raw"].arn}/*"]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-process:*"]
      },
    ]
  })
}

resource "aws_iam_role" "publisher" {
  name               = "${local.prefix}-lambda-publisher"
  assume_role_policy = local.lambda_assume
}

resource "aws_iam_role_policy" "publisher" {
  name = "publisher"
  role = aws_iam_role.publisher.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ReadApprovedDecisions"
        Effect   = "Allow"
        Action   = local.data_api_actions
        Resource = [aws_rds_cluster.main.arn]
      },
      {
        Sid    = "ReadSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.db_runtime.arn,
          aws_secretsmanager_secret.outbound_feed_tokens.arn,
        ]
      },
      {
        # Writes the feed and its last-known-good copy. Deliberately no
        # s3:DeleteObject: a feed is replaced by a new version, never removed,
        # so an accidental clearing is not expressible.
        Sid    = "PublishFeeds"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject"]
        Resource = [
          "${aws_s3_bucket.main["feeds"].arn}/*",
          "${aws_s3_bucket.main["snapshots"].arn}/*",
        ]
      },
      ], var.create_cdn ? [
      {
        Sid      = "PurgeCache"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = [aws_cloudfront_distribution.feeds[0].arn]
      },
      ] : [], [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-publish:*"]
      },
    ])
  })
}

resource "aws_iam_role" "api" {
  name               = "${local.prefix}-lambda-api"
  assume_role_policy = local.lambda_assume
}

resource "aws_iam_role_policy" "api" {
  name = "api"
  role = aws_iam_role.api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = local.data_api_actions
        Resource = [aws_rds_cluster.main.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_runtime.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-api:*"]
      },
    ]
  })
}
