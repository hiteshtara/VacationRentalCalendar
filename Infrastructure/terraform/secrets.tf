# Three secrets, each with a distinct reader and a distinct blast radius.
# Consolidating them into one would save $0.80/month and give any component
# that can read its own credential the ability to read all of them.
#
#   1. vrc/database/master  -- in database.tf. Read by the Data API on behalf
#                              of the processor and the API. Never by the
#                              fetcher.
#   2. vrc/sources/feed-urls -- inbound platform export URLs. Read ONLY by the
#                              fetcher, which has no database access at all.
#   3. vrc/outbound/feed-tokens -- the 128-bit path secrets for published
#                              feeds. Read ONLY by the publisher. A leak here
#                              discloses our own occupancy; a leak of (2)
#                              discloses the platform credentials. Different
#                              consequences, so different secrets.
#
# The separation is what makes least privilege expressible: the component that
# parses untrusted third-party feed content is the one that can neither write
# to the system of record nor read the outbound tokens.

resource "aws_secretsmanager_secret" "source_feed_urls" {
  name                    = "vrc/sources/feed-urls"
  description             = "Inbound platform iCal export URLs. Read only by the fetcher."
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "outbound_feed_tokens" {
  name                    = "vrc/outbound/feed-tokens"
  description             = "Random object-key secrets for published feeds. Read only by the publisher."
  recovery_window_in_days = 30
}

# No aws_secretsmanager_secret_version for either: the values are the private
# calendar URLs and the outbound tokens. Putting them in Terraform would put
# them in state and in this repository. They are written once, out of band.
