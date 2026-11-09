variable "region" {
  description = "AWS region. Both Route 53 zones and the PriyankaHomes tables are already here."
  type        = string
  default     = "us-east-1"
}

variable "app_domain" {
  description = "Hostname for the dashboard."
  type        = string
  default     = "calendar.bostonfurnishedstays.com"
}

variable "feed_domain" {
  description = "Hostname serving the filtered iCal feeds."
  type        = string
  default     = "feeds.39gstboston.com"
}

variable "app_zone_name" {
  type    = string
  default = "bostonfurnishedstays.com"
}

variable "feed_zone_name" {
  type    = string
  default = "39gstboston.com"
}

variable "db_min_capacity" {
  description = <<-EOT
    Aurora Serverless v2 minimum ACU. 0 lets the cluster pause, which is the
    whole cost model: see docs/PHASE2-PLAN.md section 1. Raising this to 0.5
    buys constant warmth for about $43.80/month and is the documented lever if
    measured latency ever justifies it.
  EOT
  type        = number
  default     = 0
}

variable "db_max_capacity" {
  type    = number
  default = 4
}

variable "seconds_until_auto_pause" {
  description = "300 is the minimum AWS permits. Lower is not possible."
  type        = number
  default     = 300

  validation {
    condition     = var.seconds_until_auto_pause >= 300
    error_message = "AWS enforces a 300-second floor on the auto-pause delay."
  }
}

variable "import_interval_minutes" {
  description = "Approved at 15. Change detection keeps this cheap by not waking the database on an unchanged feed."
  type        = number
  default     = 15
}

variable "monthly_budget_usd" {
  description = "Budget alarm threshold. The expected bill is about $7; the worst case if change detection fails is about $21."
  type        = number
  default     = 15
}

variable "budget_notification_email" {
  description = "Where budget alarms go. Left empty so a review plan needs no personal data; the budget is only created when set."
  type        = string
  default     = ""
}

variable "priyankahomes_table_arns" {
  description = "Read-only source tables. Never written."
  type        = list(string)
  default = [
    "arn:aws:dynamodb:us-east-1:*:table/priyankahomes-south-boston-calendar",
    "arn:aws:dynamodb:us-east-1:*:table/priyankahomes-south-boston-bookings",
  ]
}
