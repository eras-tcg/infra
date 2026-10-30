import * as cdk from 'aws-cdk-lib';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Construct } from 'constructs';

export interface ZoneStackProps extends cdk.StackProps {
  domain: string;
}

/** The public hosted zone for the domain. The registrar (DonWeb) points its nameservers here. */
export class ZoneStack extends cdk.Stack {
  readonly zone: route53.PublicHostedZone;

  constructor(scope: Construct, id: string, props: ZoneStackProps) {
    super(scope, id, { ...props, terminationProtection: true });

    this.zone = new route53.PublicHostedZone(this, 'Zone', { zoneName: props.domain });
    this.zone.applyRemovalPolicy(cdk.RemovalPolicy.RETAIN);

    new cdk.CfnOutput(this, 'NameServers', {
      value: cdk.Fn.join(' ', this.zone.hostedZoneNameServers ?? []),
      description: 'Nameservers to set at the registrar',
    });
    new cdk.CfnOutput(this, 'HostedZoneId', { value: this.zone.hostedZoneId });
  }
}
