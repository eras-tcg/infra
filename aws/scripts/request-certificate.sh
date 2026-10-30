#!/bin/bash
# The HTTPS certificate of the CloudFront distributions. It must live in us-east-1, where the project's policies
# do not allow CloudFormation, so it is requested here and its ARN is passed to CDK:
#   npx cdk deploy ErasSiteProd ErasSiteStaging -c certificateArn=<ARN printed below>
# Its DNS validation records go to the Route 53 zone; ACM issues the certificate once the registrar points the
# domain's nameservers at that zone.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: keep /eras/... and /etc/... as they are for aws.exe and ssh.exe
PROFILE=${AWS_PROFILE_ERAS:-eras}
DOMAIN=erastcg.com

arn=$(aws acm list-certificates --profile "$PROFILE" --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn | [0]" --output text)
if [ "$arn" = None ] || [ -z "$arn" ]; then
  arn=$(aws acm request-certificate --profile "$PROFILE" --region us-east-1 --domain-name "$DOMAIN" \
    --subject-alternative-names "www.$DOMAIN" "staging.$DOMAIN" --validation-method DNS \
    --tags Key=project,Value=eras --query CertificateArn --output text)
  echo "requested $arn"
  sleep 10   # ACM fills in the validation records a few seconds after the request
fi

zone=$(aws route53 list-hosted-zones-by-name --profile "$PROFILE" --dns-name "$DOMAIN." \
  --query "HostedZones[?Name=='$DOMAIN.'].Id | [0]" --output text)
changes=$(aws acm describe-certificate --profile "$PROFILE" --region us-east-1 --certificate-arn "$arn" \
  --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output json |
  jq '{Changes: (unique_by(.Name) | map({Action: "UPSERT", ResourceRecordSet: {Name: .Name, Type: .Type, TTL: 300, ResourceRecords: [{Value: .Value}]}}))}')
aws route53 change-resource-record-sets --profile "$PROFILE" --hosted-zone-id "$zone" --change-batch "$changes" >/dev/null
echo "validation records in $zone"
aws acm describe-certificate --profile "$PROFILE" --region us-east-1 --certificate-arn "$arn" --query 'Certificate.Status' --output text
echo "certificateArn=$arn"
