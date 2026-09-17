import pulumi
from pulumi import Input
from typing import Optional, Dict, TypedDict, Any
from typing_extensions import NotRequired
import builtins as _builtins


def not_implemented(msg):
    raise NotImplementedError(msg)

class ChartValuesArgs(TypedDict):
    appDomainName: Input[_builtins.str]
    awsRegion: Input[_builtins.str]
    acmCertificateArn: Input[_builtins.str]
    clusterName: Input[_builtins.str]
    route53ZoneId: NotRequired[Input[_builtins.str]]
    dbPasswordSecretName: Input[_builtins.str]
    deviceJwtSigningKeySecretName: Input[_builtins.str]
    deviceTelemetryLogGroupName: Input[_builtins.str]
    deviceTelemetryWriterRoleArn: Input[_builtins.str]
    dbHost: Input[_builtins.str]
    dbPort: Input[_builtins.float]
    dbName: Input[_builtins.str]
    dbUser: Input[_builtins.str]
    oidcIssuer: Input[_builtins.str]
    oidcAudience: Input[_builtins.str]
    oidcClientId: Input[_builtins.str]
    wifAudience: Input[_builtins.str]

class ChartValues(pulumi.ComponentResource):
    def __init__(self, name: str, args: ChartValuesArgs, opts:Optional[pulumi.ResourceOptions] = None):
        super().__init__("components:index:ChartValues", name, args, opts)

        self.helm_values = not_implemented(templatefile("${path.module}/templates/values.yaml.tftpl",{
app_domain_name=var.app_domain_name
aws_region=var.aws_region
certificate_arn=var.acm_certificate_arn
cluster_name=var.cluster_name
route53_zone_id=var.route53_zone_id

db_password_secret_name=var.db_password_secret_name
device_jwt_signing_key_secret_name=var.device_jwt_signing_key_secret_name
device_telemetry_log_group_name=var.device_telemetry_log_group_name
device_telemetry_writer_role_arn=var.device_telemetry_writer_role_arn

db_host=var.db_host
db_name=var.db_name
db_port=var.db_port
db_user=var.db_user
oidc_audience=var.oidc_audience
oidc_client_id=var.oidc_client_id
oidc_issuer=var.oidc_issuer
wif_audience=var.wif_audience
}))
        self.register_outputs({
            'helmValues': not_implemented(templatefile("${path.module}/templates/values.yaml.tftpl",{
app_domain_name=var.app_domain_name
aws_region=var.aws_region
certificate_arn=var.acm_certificate_arn
cluster_name=var.cluster_name
route53_zone_id=var.route53_zone_id

db_password_secret_name=var.db_password_secret_name
device_jwt_signing_key_secret_name=var.device_jwt_signing_key_secret_name
device_telemetry_log_group_name=var.device_telemetry_log_group_name
device_telemetry_writer_role_arn=var.device_telemetry_writer_role_arn

db_host=var.db_host
db_name=var.db_name
db_port=var.db_port
db_user=var.db_user
oidc_audience=var.oidc_audience
oidc_client_id=var.oidc_client_id
oidc_issuer=var.oidc_issuer
wif_audience=var.wif_audience
}))
        })