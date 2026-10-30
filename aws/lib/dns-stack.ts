import * as cdk from 'aws-cdk-lib';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import { Construct } from 'constructs';

export interface DnsStackProps extends cdk.StackProps {
  zone: route53.IHostedZone;
  contaboIp: string;
  /** When set, the host points at this distribution instead of Contabo. */
  prod?: cloudfront.IDistribution;
  staging?: cloudfront.IDistribution;
}

/**
 * The domain's records. Until the cutover they copy what DonWeb serves (everything at the Contabo VPS),
 * so moving the nameservers to Route 53 changes nothing; the cutover then moves one host at a time.
 */
export class DnsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: DnsStackProps) {
    super(scope, id, props);

    const { zone } = props;
    const point = (id: string, recordName: string | undefined, distribution?: cloudfront.IDistribution) => {
      if (distribution) {
        const target = route53.RecordTarget.fromAlias(new targets.CloudFrontTarget(distribution));
        new route53.ARecord(this, id, { zone, recordName, target });
        new route53.AaaaRecord(this, `${id}V6`, { zone, recordName, target });
      } else {
        new route53.ARecord(this, id, { zone, recordName, target: route53.RecordTarget.fromIpAddresses(props.contaboIp), ttl: cdk.Duration.minutes(5) });
      }
    };

    point('Apex', undefined, props.prod);
    point('Www', 'www', props.prod);
    point('Staging', 'staging', props.staging);
    // The Angular preview while it was not in production; it stays on the VPS until it is retired.
    point('Next', 'next');
  }
}
