# The four scheduled processes and one small API that are the entire reason
# this service exists: to keep importing and publishing while the Mac is off.
#
# Every one of them runs the SAME VRCCore business logic the Mac application
# runs. VRCCore is proved to compile for aarch64 Linux and to produce
# byte-identical classifications, availability decisions, conflict outcomes and
# filtered iCal output on both platforms (see vrc-parity). Nothing here
# reimplements a rule.
#
# Runtime is provided.al2023 on arm64: a statically linked Swift binary named
# `bootstrap`, built by Scripts/build-lambda.sh with the Static Linux SDK --
# no Docker and no Xcode needed.

data "archive_file" "placeholder" {
  type        = "zip"
  source_dir  = "${path.module}/placeholder"
  output_path = "${path.module}/.terraform/placeholder.zip"
}

locals {
  # fetch needs the internet and holds no database credential.
  # process, publish, sweeper and api reach the database over the Data API.
  functions = {
    fetch = {
      role        = aws_iam_role.fetcher.arn
      timeout     = 60
      memory      = 512
      description = "Fetches each source feed, hashes the normalised event set, wakes nothing if unchanged."
    }
    process = {
      role        = aws_iam_role.processor.arn
      timeout     = 120
      memory      = 1024
      description = "Parses a changed payload and reconciles it into Postgres."
    }
    publish = {
      role        = aws_iam_role.publisher.arn
      timeout     = 120
      memory      = 512
      description = "Regenerates destination feeds from approved decisions and publishes them."
    }
    sweeper = {
      role        = aws_iam_role.processor.arn
      timeout     = 30
      memory      = 512
      description = "Releases expired holds. Idempotent."
    }
    api = {
      role        = aws_iam_role.api.arn
      timeout     = 30
      memory      = 1024
      description = "Sync API for the Mac application. SigV4 only."
    }
  }
}

resource "aws_cloudwatch_log_group" "functions" {
  for_each = local.functions
  name     = "/aws/lambda/vrc-${each.key}"
  # Logs are the second-largest idle cost after Secrets Manager, and nothing
  # here is worth keeping for a month.
  retention_in_days = 14
}

resource "aws_lambda_function" "functions" {
  for_each = local.functions

  function_name = "vrc-${each.key}"
  description   = each.value.description
  role          = each.value.role
  architectures = ["arm64"]
  runtime       = "provided.al2023"
  handler       = "bootstrap"
  timeout       = each.value.timeout
  memory_size   = each.value.memory

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  environment {
    variables = {
      VRC_CLUSTER_ARN     = aws_rds_cluster.main.arn
      VRC_DB_SECRET_ARN   = aws_secretsmanager_secret.db_runtime.arn
      VRC_DB_NAME         = aws_rds_cluster.main.database_name
      VRC_RAW_BUCKET      = aws_s3_bucket.main["raw"].bucket
      VRC_FEEDS_BUCKET    = aws_s3_bucket.main["feeds"].bucket
      VRC_SNAPSHOT_BUCKET = aws_s3_bucket.main["snapshots"].bucket
      VRC_FEED_DOMAIN     = var.feed_domain
      VRC_FEEDS_DIST_ID   = aws_cloudfront_distribution.feeds.id
      # Outbound publication stays off in the deployed service too, not just
      # in the Mac application. Flipping it is a reviewed change here as well.
      VRC_OUTBOUND_ENABLED = "false"
    }
  }

  lifecycle {
    # The real binary is deployed by Scripts/build-lambda.sh, which updates
    # the function code directly. Terraform must not then revert it to the
    # placeholder on the next apply.
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_cloudwatch_log_group.functions]
}

# --------------------------------------------------------------------- the API
#
# One HTTP API, IAM-authorised. No Cognito, no user pool, no hosted login, no
# token to refresh: the Mac application signs each request with SigV4 using an
# IAM credential from its Keychain, and VRCCore already contains the SigV4
# signer it needs. That is the smallest authenticated path that exists on AWS,
# and it reuses code that is already tested.

resource "aws_apigatewayv2_api" "sync" {
  name          = "vrc-sync"
  protocol_type = "HTTP"
  description   = "Sync API for the VacationRentalCalendar Mac application."
}

resource "aws_apigatewayv2_integration" "sync" {
  api_id                 = aws_apigatewayv2_api.sync.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.functions["api"].invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

resource "aws_apigatewayv2_route" "sync" {
  api_id    = aws_apigatewayv2_api.sync.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.sync.id}"

  # Every route requires a signed request. There is no public route and no
  # unauthenticated health check, because an unauthenticated endpoint on this
  # API would disclose occupancy.
  authorization_type = "AWS_IAM"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.sync.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    # Deliberately omits the query string and request body: a sync request can
    # carry availability detail, and an access log is the wrong place for it.
    format = jsonencode({
      requestId       = "$context.requestId"
      routeKey        = "$context.routeKey"
      status          = "$context.status"
      responseLength  = "$context.responseLength"
      errorMessage    = "$context.error.message"
      callerPrincipal = "$context.identity.caller"
    })
  }
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/vrc-sync"
  retention_in_days = 14
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.functions["api"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.sync.execution_arn}/*/*"
}

# The IAM identity the Mac application assumes. Nothing else may call the API.
resource "aws_iam_user" "mac_client" {
  name = "vrc-mac-client"
}

resource "aws_iam_user_policy" "mac_client" {
  name = "invoke-sync-api"
  user = aws_iam_user.mac_client.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeSyncApiOnly"
      Effect   = "Allow"
      Action   = ["execute-api:Invoke"]
      Resource = ["${aws_apigatewayv2_api.sync.execution_arn}/*/*"]
    }]
  })
}

# No aws_iam_access_key resource: an access key created by Terraform is stored
# in Terraform state. The key is created once, by hand, and put straight into
# the Mac Keychain.

output "sync_api_endpoint" {
  value       = aws_apigatewayv2_api.sync.api_endpoint
  description = "Base URL for the Mac application's sync requests."
}

output "feed_base_url" {
  value       = "https://${var.feed_domain}"
  description = "Destination feeds are served from here, continuously."
}
