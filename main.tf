resource "aws_s3_bucket" "bucket" {
  bucket = var.bucket_name

  tags = {
    Name   = "${var.project}-bucket"
  }
}

resource "aws_s3_bucket_acl" "acl" {
  bucket = aws_s3_bucket.bucket.id
  acl    = "public-read"
}


resource "aws_s3_object" "object" {
  bucket = aws_s3_bucket.bucket.id
  for_each = fileset("/path/to/file", "**")  #eg: My file location is "/root/2124_vertex"
  key    = each.value
  source = "/path/to/file/${each.value}"


  etag = filemd5("/path/to/file/${each.value}")
 content_type  = lookup(var.mime_types, split(".", each.value)[length(split(".", each.value)) - 1])
}


resource "aws_s3_bucket_policy" "s3_policy" {
  bucket = aws_s3_bucket.bucket.id
  policy = data.aws_iam_policy_document.policy.json
}

data "aws_iam_policy_document" "policy" {
  statement {
    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.oai.iam_arn]
    }
    effect = "Allow"
    actions = [
      "s3:GetObject",
   
    ]

    resources = [
      aws_s3_bucket.bucket.arn,
      "${aws_s3_bucket.bucket.arn}/*",
    ]
  }
}


resource "aws_acm_certificate" "cert" {
  domain_name   = var.domain_name
   subject_alternative_names = [ "*.${var.domain_name}"]
   provider = aws.acm_provider
  validation_method = "DNS"

  tags = {
    Project = var.project
  }

  lifecycle {
    create_before_destroy = true
  }
}



data "aws_route53_zone" "mydomain" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "example" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.mydomain.zone_id
}

resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn         = aws_acm_certificate.cert.arn
  provider = aws.acm_provider
  validation_record_fqdns = [for record in aws_route53_record.example : record.fqdn]
}



resource "aws_cloudfront_origin_access_identity" "oai" {
  comment = "cloudfront oai"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.bucket.bucket_regional_domain_name  

    origin_id   = "local.${var.bucket_name}"

      s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

 

  aliases = ["s3.${var.domain_name}"]

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "local.${var.bucket_name}"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Environment = "production"
  }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate_validation.cert_validation.certificate_arn
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1.1_2016"
  }

}


resource "aws_route53_record" "alias" {
  zone_id = data.aws_route53_zone.mydomain.zone_id
  name    = "s3.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}
