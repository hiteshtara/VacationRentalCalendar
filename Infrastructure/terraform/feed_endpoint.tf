# The public, read-only calendar endpoint.
#
# Kept in its own file because it is the only thing in this stack reachable
# without AWS credentials. Everything about it is deliberately narrow:
#
#   * its own Lambda, not the publish handler, which can write to S3 and
#     invalidate a CDN — the public surface must not inherit those rights;
#   * its own IAM role that can read ONE prefix of ONE bucket and ONE secret,
#     and cannot reach the database at all;
#   * its own environment, without the cluster ARN or database secret that
#     every other function receives;
#   * no bucket is made public — the object stays private and is read by this
#     function's role, so listing the bucket is impossible for an outsider.
#
# Set create_feed_endpoint = false and apply to remove it entirely. That is the
# rollback: the URL stops resolving immediately and nothing else is touched.

# The AWS-managed key the feeds bucket encrypts with.
data "aws_kms_key" "s3" {
  key_id = "alias/aws/s3"
}

resource "aws_cloudwatch_log_group" "feed" {
  count             = var.create_feed_endpoint ? 1 : 0
  name              = "/aws/lambda/${local.prefix}-feed"
  retention_in_days = 14
}

resource "aws_iam_role" "feed_reader" {
  count              = var.create_feed_endpoint ? 1 : 0
  name               = "${local.prefix}-lambda-feed"
  assume_role_policy = local.lambda_assume
}

resource "aws_iam_role_policy" "feed_reader" {
  count = var.create_feed_endpoint ? 1 : 0
  name  = "feed"
  role  = aws_iam_role.feed_reader[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetObject only, and only under ical/. Deliberately NOT ListBucket:
        # if an outsider could list the bucket the object keys would be
        # enumerable, and the whole scheme rests on them staying unknown.
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.main["feeds"].arn}/ical/*"]
      },
      {
        # The feeds bucket is SSE-KMS, so GetObject alone is not enough: S3
        # must be able to decrypt on this role's behalf. ViaService confines
        # the grant to decryption performed BY S3 — the role cannot use the
        # key to decrypt anything else.
        Effect    = "Allow"
        Action    = ["kms:Decrypt"]
        Resource  = [data.aws_kms_key.s3.arn]
        Condition = { StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com" } }
      },
      {
        # The grant table: sha256(token) -> object key. No token material.
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.outbound_feed_tokens.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-feed:*"]
      },
    ]
  })
}

resource "aws_lambda_function" "feed" {
  count = var.create_feed_endpoint ? 1 : 0

  function_name = "${local.prefix}-feed"
  description   = "Read-only iCalendar endpoint. Serves one private S3 object per valid token. No database access."
  role          = aws_iam_role.feed_reader[0].arn
  architectures = ["arm64"]
  runtime       = "provided.al2023"
  handler       = "bootstrap"
  timeout       = 10
  memory_size   = 256

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  # Note what is absent: VRC_CLUSTER_ARN, VRC_DB_SECRET_ARN, VRC_DB_NAME. This
  # function has no business knowing the database exists, and its role could
  # not reach it even if it did.
  environment {
    variables = {
      VRC_FEEDS_BUCKET       = aws_s3_bucket.main["feeds"].bucket
      VRC_FEED_TOKENS_SECRET = aws_secretsmanager_secret.outbound_feed_tokens.arn
      VRC_OUTBOUND_ENABLED   = tostring(var.outbound_enabled)
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]

    precondition {
      condition     = var.environment == "staging"
      error_message = "REFUSED: the public feed endpoint is staging-only."
    }
    precondition {
      condition     = !var.outbound_enabled
      error_message = "REFUSED: the feed endpoint must not be created while outbound publication is enabled. Serving a calendar and publishing to a platform are separate decisions and must not be taken together."
    }
  }

  depends_on = [aws_cloudwatch_log_group.feed]
}

# Authorisation NONE is the point: Booking.com cannot sign a SigV4 request.
# The token in the path is the only credential, which is why the handler
# treats a wrong token, a revoked token and a malformed path identically.
#
# This is a separate hostname from the management API, which keeps its single
# AWS_IAM route untouched. Nothing here can reach it.
resource "aws_lambda_function_url" "feed" {
  count              = var.create_feed_endpoint ? 1 : 0
  function_name      = aws_lambda_function.feed[0].function_name
  authorization_type = "NONE"
}

output "feed_endpoint_url" {
  description = "Base URL of the read-only calendar endpoint. The token path is not stored in Terraform."
  value       = var.create_feed_endpoint ? aws_lambda_function_url.feed[0].function_url : ""
}
