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
  name               = "vrc-lambda-fetcher"
  assume_role_policy = local.lambda_assume
}

resource "aws_iam_role_policy" "fetcher" {
  name = "fetcher"
  role = aws_iam_role.fetcher.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSourceCredentialsOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.source_feed_urls.arn]
      },
      {
        Sid      = "DecryptWithProjectKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.main.arn]
      },
      {
        Sid      = "WriteRawPayloadsAndReadPriorHashes"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["${aws_s3_bucket.main["raw"].arn}/*"]
      },
      {
        # Read-only, and only these two tables. No PutItem, no UpdateItem,
        # no DeleteItem, no wildcard. The website's data is observed, never
        # participated in.
        Sid      = "ReadPriyankaHomesSourceTables"
        Effect   = "Allow"
        Action   = ["dynamodb:BatchGetItem", "dynamodb:GetItem", "dynamodb:DescribeTable"]
        Resource = var.priyankahomes_table_arns
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/vrc-fetch:*"]
      },
    ]
  })
}

resource "aws_iam_role" "processor" {
  name               = "vrc-lambda-processor"
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
        Sid      = "ReadDatabaseCredential"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_master.arn]
      },
      {
        Sid      = "DecryptWithProjectKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.main.arn]
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
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/vrc-process:*"]
      },
    ]
  })
}

resource "aws_iam_role" "publisher" {
  name               = "vrc-lambda-publisher"
  assume_role_policy = local.lambda_assume
}

resource "aws_iam_role_policy" "publisher" {
  name = "publisher"
  role = aws_iam_role.publisher.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
          aws_secretsmanager_secret.db_master.arn,
          aws_secretsmanager_secret.outbound_feed_tokens.arn,
        ]
      },
      {
        Sid      = "DecryptWithProjectKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.main.arn]
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
      {
        Sid      = "PurgeCache"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = [aws_cloudfront_distribution.feeds.arn]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/vrc-publish:*"]
      },
    ]
  })
}

resource "aws_iam_role" "api" {
  name               = "vrc-lambda-api"
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
        Resource = [aws_secretsmanager_secret.db_master.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.main.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/vrc-api:*"]
      },
    ]
  })
}
