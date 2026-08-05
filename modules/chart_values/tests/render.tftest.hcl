# The chart contract, asserted. This is the one behavioural check available before
# a live apply: the rendering is pure, so `command = plan` fully resolves the
# `helm_values` output.
#
# What is being guarded is the seam between this module and the pontem-control
# chart. Every assertion below corresponds to something that fails at install
# time, or worse fails silently at runtime, if the rendering drifts.

variables {
  app_domain_name     = "pontem.example.com"
  aws_region          = "us-east-1"
  acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
  cluster_name        = "pontem-control"
  route53_zone_id     = "Z0123456789ABCDEFGHIJ"

  db_password_secret_name            = "pontem-control-db-password"
  device_jwt_signing_key_secret_name = "pontem-control-device-jwt-signing-key"

  db_host = "pontem-control.abcdefghijkl.us-east-1.rds.amazonaws.com"
  db_port = 5432
  db_name = "pontem"
  db_user = "app"

  oidc_issuer    = "https://example.us.auth0.com/"
  oidc_audience  = "https://api.example.com"
  oidc_client_id = "ExampleSpaClientId"
  wif_audience   = "REPLACE_ME_PONTEM_SUPPLIED"
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
    condition = try(yamldecode(output.helm_values).awsTurnkey == {
      enabled                       = true
      certificateArn                = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
      dbPasswordSecretName          = "pontem-control-db-password"
      deviceJwtSigningKeySecretName = "pontem-control-device-jwt-signing-key"
    }, false)
    error_message = "awsTurnkey must enable the chart-owned AWS resources and identify the ACM certificate and both boot secrets."
  }

  assert {
    condition = try(yamldecode(output.helm_values)["external-secrets"] == {
      enabled = true
      serviceAccount = {
        create = true
        name   = "external-secrets"
      }
    }, false)
    error_message = "The bundled External Secrets Operator must be enabled and use the external-secrets ServiceAccount."
  }

  assert {
    condition = try(yamldecode(output.helm_values).externalDns == {
      enabled       = true
      provider      = { name = "aws" }
      sources       = ["ingress"]
      domainFilters = ["pontem.example.com"]
      zoneIdFilters = ["Z0123456789ABCDEFGHIJ"]
      extraArgs     = { "zone-id-filter" = "Z0123456789ABCDEFGHIJ" }
      policy        = "sync"
      registry      = "txt"
      txtOwnerId    = "pontem-control"
      txtPrefix     = "external-dns-%%{record_type}."
      serviceAccount = {
        create = true
        name   = "external-dns"
      }
    }, false)
    error_message = "The bundled ExternalDNS values must be limited to this ingress hostname and Route53 zone with stable TXT ownership."
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
    error_message = "ingress.className must be alb to select the IngressClass the turnkey chart creates."
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

  assert {
    condition     = yamldecode(output.helm_values).admin.auth0.clientId == "ExampleSpaClientId"
    error_message = "admin.auth0.clientId must be rendered; without it the admin UI is a blank page and no pod reports unhealthy."
  }

  # The host alone, with no scheme: the admin container builds "https://<host>/"
  # from it, so a scheme here yields "https://https://…" and a login redirect to
  # nowhere.
  assert {
    condition     = yamldecode(output.helm_values).admin.auth0.domain == "example.us.auth0.com"
    error_message = "admin.auth0.domain must be the bare host with no scheme or trailing slash."
  }

  # Same audience the API validates against. If these diverge the UI signs in
  # successfully and then every API call it makes returns 401.
  assert {
    condition     = yamldecode(output.helm_values).admin.auth0.audience == yamldecode(output.helm_values).auth.oidc.audience
    error_message = "admin.auth0.audience must equal auth.oidc.audience, or the API rejects every token the UI obtains."
  }

  assert {
    condition     = yamldecode(output.helm_values).admin.authMode == "auth0"
    error_message = "admin.authMode must be auth0; `local` is a development-only mode that bypasses authentication."
  }

  # The chart rejects an empty wifAudience but accepts any non-empty string, so
  # the un-substituted value has to be a visible sentinel: it is the only thing
  # that makes a forgotten substitution obvious in a diff or a rendered file.
  assert {
    condition     = yamldecode(output.helm_values).gcp.wifAudience == "REPLACE_ME_PONTEM_SUPPLIED"
    error_message = "An un-substituted wifAudience must render as the loud placeholder, not as an empty string."
  }

  # No key the chart's schema does not define: it sets additionalProperties
  # false at every level, so one stray top-level key fails the whole install.
  assert {
    condition = length(setsubtract(keys(yamldecode(output.helm_values)), [
      "image", "version", "credentials", "cloudProvider", "aws", "gcp", "auth",
      "externalDatabase", "blobStorage", "agentCatalog", "secretsBackend",
      "observability", "tracing", "managedSync", "devicePurge", "serviceAccount",
      "api", "worker", "mcp", "admin", "ingress", "awsTurnkey",
      "external-secrets", "externalDns",
    ])) == 0
    error_message = "helm_values contains a top-level key the chart's values.schema.json does not define; the schema sets additionalProperties=false, so the install would be rejected."
  }
}

run "route53_disabled_omits_external_dns_configuration" {
  command = plan

  variables {
    route53_zone_id = null
  }

  assert {
    condition = try(yamldecode(output.helm_values).externalDns == {
      enabled = false
      serviceAccount = {
        create = true
        name   = "external-dns"
      }
    }, false)
    error_message = "Without a Route53 zone, ExternalDNS must be disabled and no DNS settings may be rendered."
  }
}

run "issuer_host_is_lowercased_for_the_admin_app" {
  command = plan

  variables {
    oidc_issuer = "https://Example.US.auth0.com/"
  }

  # Hostnames are case-insensitive, so a mixed-case issuer is a legitimate thing to
  # be given. The admin app compares the host it holds against what the provider
  # returns, so it has to arrive lowercased and stripped of scheme and trailing
  # slash.
  assert {
    condition     = yamldecode(output.helm_values).admin.auth0.domain == "example.us.auth0.com"
    error_message = "A mixed-case issuer must reach admin.auth0.domain lowercased, with the scheme and any trailing slash removed."
  }

  # The issuer the API validates against is passed through untouched: it must match
  # the provider's own `iss` claim byte for byte, which lowercasing could break.
  assert {
    condition     = yamldecode(output.helm_values).auth.oidc.issuer == "https://Example.US.auth0.com/"
    error_message = "auth.oidc.issuer must be passed through verbatim, not normalised — it is compared against the token's iss claim."
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
