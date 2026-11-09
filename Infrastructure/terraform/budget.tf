# The cost model has a known failure mode: if feed volatility defeats change
# detection, the database stays awake and the bill goes from about $7 to about
# $21. This is how that announces itself as a notification rather than as a
# surprise at the end of the month.
#
# Only created when an address is supplied, so a review plan needs no personal
# data in the repository.
resource "aws_budgets_budget" "monthly" {
  count = var.budget_notification_email == "" ? 0 : 1

  name         = "${local.prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$VacationRentalCalendar"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}
