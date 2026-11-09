# VacationRentalCalendar infrastructure.
#
# PLAN ONLY. Nothing here has been applied. `terraform apply` must not be run
# until the plan has been reviewed and approved.
#
# Deliberately separate from PriyankaHomes: its own state key, its own lock
# table, its own IAM roles. Nothing in this configuration reads or writes any
# PriyankaHomes resource, and the two DynamoDB tables are referenced only
# through a read-only IAM policy.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Aurora Serverless v2 min_capacity = 0 and seconds_until_auto_pause
      # both need a recent provider. Pinned to a major version so a provider
      # upgrade is a deliberate change.
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Production backend. Commented out so a review plan can run locally
  # without touching remote state, and so `apply` cannot be run by accident
  # against real state before the bucket exists.
  #
  # backend "s3" {
  #   bucket       = "vrc-terraform-state"
  #   key          = "vacation-rental-calendar/foundation.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "VacationRentalCalendar"
      ManagedBy = "terraform"
      Component = "foundation"
    }
  }
}
