# The chart uses this ACM certificate at the ALB. With a Route53 zone, the module
# writes the validation record and waits for issuance; otherwise it returns the
# record for the caller to create.
resource "aws_route53_zone" "this" {
  count = var.create_route53_zone ? 1 : 0

  name = var.app_domain_name
  tags = local.tags

  lifecycle {
    precondition {
      condition     = var.route53_zone_id == null
      error_message = "Set only one of create_route53_zone or route53_zone_id: the first provisions a new hosted zone, the second brings one you already have."
    }
  }
}

resource "aws_acm_certificate" "app" {
  domain_name       = var.app_domain_name
  validation_method = "DNS"

  # Keep the old certificate until its replacement is ready for the ALB.
  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

# Terraform must know for_each keys during planning. app_domain_name is known
# even when the new zone ID and ACM validation values are not.
resource "aws_route53_record" "acm_validation" {
  for_each = local.has_route53_zone ? toset([var.app_domain_name]) : toset([])

  zone_id = local.route53_zone_id
  name    = one([for dvo in aws_acm_certificate.app.domain_validation_options : dvo.resource_record_name if dvo.domain_name == each.value])
  type    = one([for dvo in aws_acm_certificate.app.domain_validation_options : dvo.resource_record_type if dvo.domain_name == each.value])
  records = [one([for dvo in aws_acm_certificate.app.domain_validation_options : dvo.resource_record_value if dvo.domain_name == each.value])]
  ttl     = 60

  # ACM can reuse a validation record name when replacing a certificate.
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  count = local.has_route53_zone ? 1 : 0

  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

locals {
  # Make helm_values wait for validation when the module manages DNS.
  acm_certificate_arn = local.has_route53_zone ? aws_acm_certificate_validation.app[0].certificate_arn : aws_acm_certificate.app.arn
}
