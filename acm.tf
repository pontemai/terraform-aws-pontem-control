# ACM certificate for the control-plane hostname, DNS-validated. TLS terminates
# at the ALB with this certificate, which the IngressClassParams manifest (see
# the ingress_class_manifest output) attaches.
#
# route53_zone_id decides whether this module validates the certificate itself or
# hands the records back as an output; its description explains both paths and why
# the null case deliberately adds no waiter.

resource "aws_acm_certificate" "app" {
  domain_name       = var.app_domain_name
  validation_method = "DNS"

  # Standard for certificates a load balancer references: on replacement (a
  # domain change), create the new certificate before destroying the one the
  # listener still points at.
  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

# Keyed on the domain name from the VARIABLE, not on the certificate's
# domain_validation_options. The obvious spelling — for_each over
# domain_validation_options directly — makes the map's KEYS depend on an attribute
# of a certificate that does not exist yet, and Terraform cannot plan a for_each
# whose keys are unknown: the first apply fails with "the for_each map cannot be
# determined until apply", and the workaround is a two-stage targeted apply.
# Unknown VALUES are fine, so looking each record up by a key we already know
# keeps this a single apply.
#
# The certificate covers exactly one name and has no subject alternative names,
# so this map has exactly one entry.
resource "aws_route53_record" "acm_validation" {
  for_each = var.route53_zone_id == null ? toset([]) : toset([var.app_domain_name])

  zone_id = var.route53_zone_id
  name    = one([for dvo in aws_acm_certificate.app.domain_validation_options : dvo.resource_record_name if dvo.domain_name == each.value])
  type    = one([for dvo in aws_acm_certificate.app.domain_validation_options : dvo.resource_record_type if dvo.domain_name == each.value])
  records = [one([for dvo in aws_acm_certificate.app.domain_validation_options : dvo.resource_record_value if dvo.domain_name == each.value])]
  ttl     = 60

  # ACM re-issues the same validation record name for a re-created certificate,
  # so allow_overwrite avoids failing on a record this module itself left behind.
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  count = var.route53_zone_id == null ? 0 : 1

  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

locals {
  # Read through the validation resource when there is one. It resolves to the
  # same ARN, but routing through it makes anything consuming the certificate —
  # most of all the IngressClassParams manifest — depend on the certificate
  # actually being ISSUED rather than merely existing.
  acm_certificate_arn = var.route53_zone_id == null ? aws_acm_certificate.app.arn : aws_acm_certificate_validation.app[0].certificate_arn
}
