# The 15-minute cadence approved as decision 5. Only the fetcher runs on a
# schedule; it wakes the processor, and therefore the database, only when a
# feed's semantic hash has actually changed.
resource "aws_scheduler_schedule" "import" {
  count               = 1
  name                = "${local.prefix}-import"
  schedule_expression = "rate(${var.import_interval_minutes} minutes)"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_lambda_function.functions["fetch"].arn
    role_arn = aws_iam_role.scheduler.arn
  }

  # Created disabled. Deployment step 8 enables it deliberately, after the
  # Lambdas exist and have been exercised by hand.
  state = "DISABLED"
}

resource "aws_scheduler_schedule" "sweeper" {
  name                = "${local.prefix}-hold-sweeper"
  schedule_expression = "rate(5 minutes)"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_lambda_function.functions["sweeper"].arn
    role_arn = aws_iam_role.scheduler.arn
  }

  state = "DISABLED"
}

resource "aws_iam_role" "scheduler" {
  name = "${local.prefix}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [
        aws_lambda_function.functions["fetch"].arn,
        aws_lambda_function.functions["sweeper"].arn,
      ]
    }]
  })
}
