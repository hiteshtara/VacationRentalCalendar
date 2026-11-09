# Enforcement of the staging invariants.
#
# IMPORTANT: the `check` blocks at the bottom of this file only WARN. Verified:
# a plan with `outbound_enabled=true` exits 0, reports zero errors, and still
# writes an applyable plan file. They are useful as named, readable reporting;
# they are NOT a gate, and an earlier revision of the documentation wrongly
# said they were.
#
# The gates are the `precondition` blocks below, which raise errors and stop
# both plan and apply, plus Scripts/staging-preflight.sh, which inspects the
# saved plan JSON independently of Terraform and exits non-zero.
#
# Three layers, deliberately: a variable validation catches a bad tfvars, a
# precondition catches a bad plan, and the preflight catches anything that got
# past both -- including a plan file edited or swapped after review.

# A resource that exists in every configuration, used to carry the invariants
# as hard preconditions. It creates nothing.
resource "terraform_data" "staging_invariants" {
  input = var.environment

  lifecycle {
    precondition {
      condition     = !(var.environment == "staging" && var.outbound_enabled)
      error_message = "REFUSED: outbound_enabled must be false in staging. A staging environment must never be able to publish to a booking platform."
    }
    precondition {
      condition     = !(var.environment == "staging" && var.create_dns)
      error_message = "REFUSED: create_dns must be false in staging. It would add records to a hosted zone that also serves the live website."
    }
    precondition {
      condition     = !(var.environment == "staging" && var.create_cdn)
      error_message = "REFUSED: create_cdn must be false in staging. Nothing in staging may be publicly served."
    }
    precondition {
      condition     = !(var.environment == "staging" && var.allow_priyankahomes_read)
      error_message = "REFUSED: allow_priyankahomes_read must be false in staging. Staging must not reach production booking data, even read-only."
    }
    precondition {
      condition     = var.seconds_until_auto_pause >= 300
      error_message = "REFUSED: AWS enforces a 300-second floor on the auto-pause delay."
    }
    precondition {
      condition     = var.region == "us-east-1"
      error_message = "REFUSED: this project is deployed only in us-east-1, where both hosted zones and the existing tables live."
    }
  }
}

# ---------------------------------------------------------------------------
# Reporting only. These produce WARNINGS, not errors. Kept because a named
# warning in the plan output is easier to read than a precondition failure,
# but they stop nothing on their own.
# ---------------------------------------------------------------------------

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
