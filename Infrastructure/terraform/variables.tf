variable "region" {
  description = "AWS region. Both Route 53 zones and the PriyankaHomes tables are already here."
  type        = string
  default     = "us-east-1"
}


variable "feed_domain" {
  description = "Hostname serving the filtered iCal feeds."
  type        = string
  default     = "feeds.39gstboston.com"
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

# ---------------------------------------------------------------- environment

variable "environment" {
  description = <<-EOT
    "staging" or "production".

    Staging is deliberately smaller than production, not a copy of it:
      * no Route 53 records and no ACM certificates, so it cannot touch any
        DNS zone -- including the one serving the live website;
      * no CloudFront distributions, so the API is reached on its default
        execute-api hostname and feeds are never publicly served;
      * no access to the PriyankaHomes DynamoDB tables at all, so it cannot
        read production booking data, let alone write it;
      * deletion protection off and a destroyable cluster, because a staging
        environment that cannot be torn down is a liability.
  EOT
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be \"staging\" or \"production\"."
  }
}

variable "create_dns" {
  description = "Route 53 records and ACM certificates. Off in staging so no DNS zone is touched."
  type        = bool
  default     = false
}

variable "create_cdn" {
  description = "CloudFront distributions. Off in staging: nothing is publicly served."
  type        = bool
  default     = false
}

variable "allow_priyankahomes_read" {
  description = <<-EOT
    Whether the fetcher may read the two PriyankaHomes DynamoDB tables.
    Off in staging: staging must not be able to reach production booking data
    even read-only, so the grant simply does not exist there.
  EOT
  type        = bool
  default     = false
}

locals {
  prefix        = var.environment == "production" ? "vrc" : "vrc-staging"
  is_production = var.environment == "production"
}

variable "outbound_enabled" {
  description = <<-EOT
    Whether the deployed service may publish to a booking platform.

    Off, and the `check` block below refuses any plan that turns it on in
    staging. Turning it on in production is a deliberate, reviewed change that
    also requires flipping OutboundSyncGate.isEnabled in Swift -- two
    independent gates, neither of which can be tripped by a stray tfvars file.
  EOT
  type        = bool
  default     = false
}

variable "create_feed_endpoint" {
  description = "Create the public read-only iCalendar endpoint (Lambda Function URL). Setting this false and applying removes it entirely, which is the rollback."
  type        = bool
  default     = false
}
