# Encryption uses AWS-managed keys throughout: aws/s3, aws/secretsmanager,
# aws/rds and aws/logs. All are free, all encrypt at rest, and none needs a key
# policy in a single-operator account where IAM already scopes every reader to
# one secret or one bucket prefix.
#
# If a customer-managed key is ever wanted -- for a key policy as a second
# layer of deny, or for an audit requirement -- it is one resource and $1/month
# per key version, and every encrypted resource below takes a kms_key_id.



locals {
  buckets = {
    feeds     = "Published iCal feeds. Served through CloudFront at the feed domain."
    raw       = "Raw fetched payloads, for forensics when an import is disputed."
    snapshots = "Versioned database snapshots and reconciliation reports."
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "main" {
  for_each = local.buckets
  bucket   = "${local.prefix}-${each.key}-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "main" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.main[each.key].id
  versioning_configuration {
    # Versioning on every bucket, including feeds: a published feed's previous
    # revision is the rollback target, and a feed overwritten by mistake must
    # be recoverable.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.main[each.key].id
  rule {
    apply_server_side_encryption_by_default {
      # The AWS-managed aws/s3 key. A customer-managed key is $1/month per
      # key version, and automatic rotation adds a version every year, so it
      # would grow to a sixth of this system's entire bill while adding a key
      # policy that one operator with least-privilege IAM does not need.
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# No bucket is public. The feed and dashboard buckets are reached only through
# CloudFront with Origin Access Control, so an unguessable object key is not
# the only thing standing between a bucket listing and the public.
resource "aws_s3_bucket_public_access_block" "main" {
  for_each                = local.buckets
  bucket                  = aws_s3_bucket.main[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Raw payloads are only useful while a dispute is live.
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.main["raw"].id

  rule {
    id     = "expire-raw-payloads"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "snapshots" {
  bucket = aws_s3_bucket.main["snapshots"].id

  rule {
    id     = "age-out-snapshots"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}
