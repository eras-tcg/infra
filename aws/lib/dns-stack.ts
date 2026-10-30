import * as cdk from 'aws-cdk-lib';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import { Construct } from 'constructs';

export interface DnsStackProps extends cdk.StackProps {
  zone: route53.IHostedZone;
  prod: cloudfront.IDistribution;
  staging: cloudfront.IDistribution;
}

/** The domain's records: every host is an alias of its environment's CloudFront distribution. */
export class DnsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: DnsStackProps) {
    super(scope, id, props);

    const { zone } = props;
    const point = (id: string, recordName: string | undefined, distribution: cloudfront.IDistribution) => {
      const target = route53.RecordTarget.fromAlias(new targets.CloudFrontTarget(distribution));
      new route53.ARecord(this, id, { zone, recordName, target });
      new route53.AaaaRecord(this, `${id}V6`, { zone, recordName, target });
    };

    point('Apex', undefined, props.prod);
    point('Www', 'www', props.prod);
    point('Staging', 'staging', props.staging);
  }
}
