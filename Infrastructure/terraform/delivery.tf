
data "aws_route53_zone" "feeds" {
  name         = "${var.feed_zone_name}."
  private_zone = false
}

# Certificates are validated by DNS records added to zones that already exist.
# Nothing else in either zone is touched: the live website's records are not
# read, modified or referenced.

resource "aws_acm_certificate" "feeds" {
  domain_name       = var.feed_domain
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}


resource "aws_route53_record" "feeds_validation" {
  for_each = {
    for d in aws_acm_certificate.feeds.domain_validation_options : d.domain_name => d
  }
  zone_id = data.aws_route53_zone.feeds.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
}

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "vrc-s3"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# A stale cache is dangerous in one direction only. Serving an old feed when a
# block was ADDED is harmless, because those nights were already on sale.
# Serving an old feed after dates were REOPENED keeps them off sale. Hence a
# short TTL plus an explicit invalidation on every publish, and a publication
# that is not counted as complete until the invalidation confirms.
resource "aws_cloudfront_distribution" "feeds" {
  enabled         = true
  comment         = "VRC filtered iCal feeds"
  aliases         = [var.feed_domain]
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    domain_name              = aws_s3_bucket.main["feeds"].bucket_regional_domain_name
    origin_id                = "feeds"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  default_cache_behavior {
    target_origin_id       = "feeds"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.short.id
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.feeds.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }
}

resource "aws_cloudfront_cache_policy" "short" {
  name        = "vrc-short"
  default_ttl = 60
  min_ttl     = 0
  max_ttl     = 300

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

