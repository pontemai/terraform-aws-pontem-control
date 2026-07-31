# The chart contract, asserted. This is the one behavioural check available
# before a live apply: the rendering is pure, so `command = plan` resolves both
# outputs fully with no provider, no credentials, and no network.
#
# What is being guarded is the seam between this module and the pontem-control
# chart. Every assertion below corresponds to something that fails at install
# time, or worse fails silently at runtime, if the rendering drifts.

variables {
  app_domain_name     = "pontem.example.com"
  aws_region          = "us-east-1"
  acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
  namespace           = "pontem-control"

  db_host = "pontem-control.abcdefghijkl.us-east-1.rds.amazonaws.com"
  db_port = 5432
  db_name = "pontem"
  db_user = "app"

  oidc_issuer   = "https://example.us.auth0.com/"
  oidc_audience = "https://api.example.com"
}

run "values_satisfy_the_chart_contract" {
  command = plan

  assert {
    condition     = yamldecode(output.helm_values).cloudProvider == "aws"
    error_message = "cloudProvider must be aws; the chart rejects secretsBackend.type=aws without it."
  }

  assert {
    condition     = yamldecode(output.helm_values).aws.region == "us-east-1"
    error_message = "aws.region must be the region the resources were created in — the secrets backend and the GCP federation both read it."
  }

  assert {
    condition     = yamldecode(output.helm_values).secretsBackend.type == "aws"
    error_message = "secretsBackend.type must be aws so tenant secrets go to Secrets Manager."
  }

  # The chart's schema has no s3 blob backend, so "none" is the only honest
  # answer here, not a placeholder to be filled in later.
  assert {
    condition     = yamldecode(output.helm_values).blobStorage.type == "none"
    error_message = "blobStorage.type must be none; the chart's enum is gcs|none and there is no AWS object-storage backend."
  }

  # The application rejects a DSN with an embedded password and reads
  # DATABASE_PASSWORD from the Secret. Asserting the whole string rather than
  # just "no password" also pins the driver, which a psycopg2/psycopg3 slip would
  # otherwise break at startup.
  assert {
    condition     = yamldecode(output.helm_values).externalDatabase.url == "postgresql+psycopg://app@pontem-control.abcdefghijkl.us-east-1.rds.amazonaws.com:5432/pontem"
    error_message = "externalDatabase.url must be the password-less postgresql+psycopg DSN built from the RDS endpoint."
  }

  assert {
    condition     = yamldecode(output.helm_values).externalDatabase.cloudsqlProxy.enabled == false
    error_message = "The Cloud SQL proxy sidecar must stay off; RDS is reached by DNS name."
  }

  assert {
    condition     = yamldecode(output.helm_values).ingress.domain == "pontem.example.com"
    error_message = "ingress.domain must be app_domain_name — it must match the name on the ACM certificate or TLS fails."
  }

  assert {
    condition     = yamldecode(output.helm_values).ingress.className == "alb"
    error_message = "ingress.className must be alb to select the IngressClass the ingress_class_manifest output creates."
  }

  assert {
    condition     = yamldecode(output.helm_values).ingress.managedCertificate == false
    error_message = "managedCertificate is a GKE-only feature; leaving it true emits a ManagedCertificate resource that does not exist on EKS."
  }

  # scheme and certificate-arn belong to IngressClassParams. Setting either here
  # as well conflicts, and the ALB controller's complaint does not make it
  # obvious that two sources are fighting.
  assert {
    condition     = !contains(keys(yamldecode(output.helm_values).ingress.annotations), "alb.ingress.kubernetes.io/scheme")
    error_message = "ingress.annotations must not set scheme — it lives in IngressClassParams and conflicts if set in both."
  }

  assert {
    condition     = !contains(keys(yamldecode(output.helm_values).ingress.annotations), "alb.ingress.kubernetes.io/certificate-arn")
    error_message = "ingress.annotations must not set certificate-arn — it lives in IngressClassParams and conflicts if set in both."
  }

  assert {
    condition     = yamldecode(output.helm_values).ingress.annotations["alb.ingress.kubernetes.io/target-type"] == "ip"
    error_message = "target-type must be ip: Auto Mode's ALB controller targets pod IPs, not node ports."
  }

  # Unlike the GCE Ingress, the ALB controller does not derive the health check
  # from the readinessProbe. Miss these and the target groups never go healthy,
  # which presents as a 502 from a deployment that looks entirely fine.
  assert {
    condition     = yamldecode(output.helm_values).api.service.annotations["alb.ingress.kubernetes.io/healthcheck-path"] == "/health"
    error_message = "The api service must set the ALB healthcheck-path to /health; the default `/` is not served."
  }

  assert {
    condition     = yamldecode(output.helm_values).admin.service.annotations["alb.ingress.kubernetes.io/healthcheck-path"] == "/healthz"
    error_message = "The admin service must set the ALB healthcheck-path to /healthz; the default `/` is not served."
  }

  assert {
    condition     = yamldecode(output.helm_values).credentials.existingSecret.name == "pontem-control"
    error_message = "credentials.existingSecret.name must match the Secret the install creates."
  }

  assert {
    condition     = yamldecode(output.helm_values).auth.oidc.issuer == "https://example.us.auth0.com/"
    error_message = "auth.oidc.issuer must pass through as a plain value."
  }

  assert {
    condition     = yamldecode(output.helm_values).auth.oidc.audience == "https://api.example.com"
    error_message = "auth.oidc.audience must pass through as a plain value."
  }

  # The chart refuses to install with wifAudience empty, so the default must be a
  # visible sentinel rather than "" — an empty string reads as "nothing to do".
  assert {
    condition     = yamldecode(output.helm_values).gcp.wifAudience == "REPLACE_ME_PONTEM_SUPPLIED"
    error_message = "gcp.wifAudience must default to the loud placeholder so an un-substituted value is obvious."
  }

  # No key the chart's schema does not define: it sets additionalProperties
  # false at every level, so one stray top-level key fails the whole install.
  assert {
    condition = length(setsubtract(keys(yamldecode(output.helm_values)), [
      "image", "version", "credentials", "cloudProvider", "aws", "gcp", "auth",
      "externalDatabase", "blobStorage", "agentCatalog", "secretsBackend",
      "observability", "tracing", "managedSync", "devicePurge", "serviceAccount",
      "api", "worker", "mcp", "admin", "ingress",
    ])) == 0
    error_message = "helm_values contains a top-level key the chart's values.schema.json does not define; the schema sets additionalProperties=false, so the install would be rejected."
  }

  # The assertions above pin the keys that matter. This one pins the whole file,
  # so that a change to the template — including to its comments, which are the
  # customer's explanation of why each key is set — shows up as a reviewable diff
  # of tests/golden_values.yaml in the pull request rather than passing silently.
  # Regenerate with `make goldens` when the change is intended.
  assert {
    condition     = output.helm_values == file("${path.module}/tests/golden_values.yaml")
    error_message = "The rendered values no longer match tests/golden_values.yaml. If the change is intended, run `make goldens` and review the diff."
  }
}

run "wif_audience_is_substitutable" {
  command = plan

  variables {
    wif_audience = "//iam.googleapis.com/projects/1234/locations/global/workloadIdentityPools/aws-customer/providers/aws-eks"
  }

  assert {
    condition     = yamldecode(output.helm_values).gcp.wifAudience == "//iam.googleapis.com/projects/1234/locations/global/workloadIdentityPools/aws-customer/providers/aws-eks"
    error_message = "wif_audience must render verbatim — the chart matches it against what GCP issued."
  }
}

run "oidc_may_come_from_the_secret_instead" {
  command = plan

  variables {
    oidc_issuer   = ""
    oidc_audience = ""
  }

  # Empty is a legitimate configuration, not a broken one: the chart falls back
  # to OIDC_ISSUER / OIDC_AUDIENCE from the Secret. It must render as an empty
  # string rather than being omitted or rendering as the literal "null".
  assert {
    condition     = yamldecode(output.helm_values).auth.oidc.issuer == ""
    error_message = "An unset oidc_issuer must render as an empty string, which the chart reads as `comes from the Secret`."
  }

  assert {
    condition     = yamldecode(output.helm_values).auth.oidc.audience == ""
    error_message = "An unset oidc_audience must render as an empty string."
  }
}

run "ingress_class_manifest_wires_the_alb_controller" {
  command = plan

  assert {
    condition     = strcontains(output.ingress_class_manifest, "controller: eks.amazonaws.com/alb")
    error_message = "The IngressClass must name Auto Mode's built-in ALB controller."
  }

  assert {
    condition     = strcontains(output.ingress_class_manifest, "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555")
    error_message = "The IngressClassParams must carry the ACM certificate ARN; TLS terminates at the ALB with it."
  }

  assert {
    condition     = strcontains(output.ingress_class_manifest, "scheme: internet-facing")
    error_message = "The ALB must be internet-facing; an internal scheme gives a load balancer no user can reach."
  }

  # Both documents must be present and separated, or `kubectl apply -f -` gets
  # one object and the IngressClass references parameters that do not exist.
  assert {
    condition     = length([for doc in split("\n---\n", output.ingress_class_manifest) : doc if strcontains(doc, "kind: ")]) == 2
    error_message = "The manifest must contain exactly two YAML documents: IngressClassParams and IngressClass."
  }

  assert {
    condition     = output.ingress_class_manifest == file("${path.module}/tests/golden_ingressclass.yaml")
    error_message = "The rendered IngressClass manifest no longer matches tests/golden_ingressclass.yaml. If the change is intended, run `make goldens` and review the diff."
  }
}
