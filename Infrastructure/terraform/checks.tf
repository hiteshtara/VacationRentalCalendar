# Plan-time assertions.
#
# These exist because the Lambda environment is assembled with merge(), whose
# result is unknown until apply -- so `terraform show` on a plan cannot prove
# what VRC_OUTBOUND_ENABLED will be. A check block can.

check "staging_never_publishes" {
  assert {
    condition     = !(var.environment == "staging" && var.outbound_enabled)
    error_message = "outbound_enabled must be false in staging: a staging environment must never be able to publish to a booking platform."
  }
}

check "staging_touches_no_dns" {
  assert {
    condition     = !(var.environment == "staging" && var.create_dns)
    error_message = "create_dns must be false in staging: it would add records to a hosted zone that also serves the live website."
  }
}

check "staging_cannot_read_production_bookings" {
  assert {
    condition     = !(var.environment == "staging" && var.allow_priyankahomes_read)
    error_message = "allow_priyankahomes_read must be false in staging: staging must not reach production booking data, even read-only."
  }
}

check "imports_start_disabled" {
  assert {
    condition     = alltrue([for s in aws_scheduler_schedule.import[*].state : s == "DISABLED"])
    error_message = "the import schedule must be created DISABLED; enabling it is a deliberate post-deployment step."
  }
}

check "auto_pause_is_at_the_aws_floor" {
  assert {
    condition     = var.seconds_until_auto_pause >= 300
    error_message = "AWS enforces a 300-second floor on the auto-pause delay."
  }
}
