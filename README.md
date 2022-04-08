
# Static website hosting using S3 bucket,Cloudfront,ACM with terraform

By the time you finish reading this article, you will know how to get your static websites up and running securely on AWS using Terraform.


## Diagram


- S3 — for storing the static site
- CloudFront — for serving the static site over SSL
- AWS Certificate Manager — for generating the SSL certificates
- Route53 — for routing the domain name s3.example.com to the correct location
## Prerequisites

- An IAM user on your AWS account with  that has "Access key - Programmatic access" and the policy permission of the required resource.

- Download and Install the [Terraform](https://www.terraform.io/downloads)

- Purchased [Domain name](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/domain-register.html)

Then create a project directory and keep static aweb site's content on here and a file for declaring the variables(variable.tf).  I'm passing the declared variable values through the variable.tfvars file.

**Create a file for declaring the variables**

```bash
variable "region" {}
variable "access_key" {}
variable "secret_key" {}
variable "acm_region" {}
variable "project" {}
variable "bucket_name" {} 
variable "domain_name" {} 
variable "mime_types" {}

```

**Create the provider file**

```bash
provider "aws" {
  region     = var.region
  access_key = var.access_key
  secret_key = var.secret_key
 }

```

**Create a terraform.tfvars**

The bucket name should be the same as the domain name. In this code, please use bucket names like as: "s3.example.com" and domain names like as: "example.com"

```bash
region      = "Desired region"
access_key  = "IAM user access_key"
secret_key  = "IAM user secret_key"
acm_region  = "us-east-1"
project     = "Your project name"
bucket_name = "s3.example.com" # Please use bucket names like as: "s3.example.com" and domain names like as: "example.com"
domain_name = "example.com"
mime_types  = {
      htm   = "text/html"
      html  = "text/html"
      css   = "text/css"
      ttf   = "font/ttf"
      json  = "application/json"
      png   = "image/png"
      jpg   = "image/jpeg"
      woff2 = "font/woff2"
      woff  = "font/woff"
      eot   = "application/vnd.ms-fontobject"
      js    = "text/javascript"
      otf   = "font/otf"
      svg   = "image/svg+xml"
      txt   = "text/plain"
      config = "application/xml"
  }

```


The Basic configuration for terraform aws is completed.Now we need to initialize the terraform using the loaded values.

```bash
$ terraform init

```


## Create the s3 bucket and Host the content

Once you’ve got a website, you need it to be accessible on the internet. I used S3 for this because it’s dirt cheap and it integrates well with all the other necessary components. 

Assuming we’ve generated our site content already, we need to create an S3 bucket to host the content.

**Create bucket**

```bash
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

```

**Upload website content to s3 bucket**

Here,  I simply upload my website file to the S3 bucket. I have added the "mime_types" in the variable.tf file. (Please refer to the variable.tf file for clarification.)

```bash
resource "aws_s3_object" "object" {
  bucket = aws_s3_bucket.bucket.id
  for_each = fileset("/path/to/file", "**")  #eg: My file location is "/root/2124_vertex"
  key    = each.value
  source = "/path/to/file/${each.value}"


  etag = filemd5("/path/to/file/${each.value}")
 content_type  = lookup(var.mime_types, split(".", each.value)[length(split(".", each.value)) - 1])
}
```

**Set up bucket policy**

```bash
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
```

**Generate an SSL Certificate**

We needed to generate an SSL certificate for https://www.example.com. I used the AWS Certificate Manager for this because it’s free and is easily integrated with the rest of the system.

I have gone with the DNS validation method on here.DNS validation requires the domain nameservers to already be pointing to AWS. However, you won’t know the nameservers you need until after the NS Route 53 record has been created.

```bash

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
```
You can see in the above script that I am using the acm_provider as we need the certificate to be created in us-east-1 for Cloudfront to be able to use it.

**ACM certificate validation**

DNS validation can take 30 minutes or more during which the Terraform script will still be running.
```bash

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
```
**Host with CloudFront**

Now that we have done the S3 and SSL certificate we can look at creating the Cloudfront distributions.
CloudFront supports using our own SSL cert and will just pull its data from the S3 bucket.

```bash
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
```
> Note: CloudFront distributions take about 15 minutes to reach a deployed state after creation or modification. During this time, deletes to resources will be blocked. If you need to delete a distribution that is enabled and you do not want to wait, you need to use the retain_on_delete flag.

**Set up DNS**

Creata an alias record for the cloud front

```bash
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

```


**Terraform Validation**

This will check for any errors on the source code
```bash
terrafom validate
```
**Terraform Plan**

Creates an execution plan, which lets you preview the changes that Terraform plans to make to your infrastructure.
```bash
terraform plan -var-file="variable.tfvars"
```
**Terraform apply**

Executes the actions proposed in a Terraform plan.
```bash
terraform apply -var-file="variable.tfvars"
```
## Conclusion

In this tutorial, we have discussed how to host a static website on a secured mode using terraform. Please let me know when you encounter any difficult errors while using this terraform code. 
Thanks!!!


 ### ⚙️ Connect with Me

<p align="center">
<a href="https://www.linkedin.com/in/radin-lawrence-8b3270102/"><img src="https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white"/></a>
<a href="mailto:radin.lawrence@gmail.com"><img src="https://img.shields.io/badge/Gmail-D14836?style=for-the-badge&logo=gmail&logoColor=white"/></a>
