import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { BackendStack, ORIGIN_SECRET_PARAM } from './backend-stack.js';

export interface SiteStackProps extends cdk.StackProps {
  envName: 'prod' | 'staging';
  backend: BackendStack;
  /** The proxy port of this environment on the server. */
  originPort: number;
  domainNames?: string[];
  certificateArn?: string;
}

const ORIGIN_HEADER = 'X-Eras-Origin';

/**
 * One environment of the site: the Angular build in a private bucket, and a CloudFront distribution that serves
 * it and sends /api and /ws to the server and /wake to the wake function.
 */
export class SiteStack extends cdk.Stack {
  readonly bucket: s3.Bucket;
  readonly distribution: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: SiteStackProps) {
    super(scope, id, props);
    const { backend } = props;
    // Read here rather than taken from the backend stack: a cross-stack reference would publish it as an output.
    const originSecret = ssm.StringParameter.valueForStringParameter(this, ORIGIN_SECRET_PARAM);

    this.bucket = new s3.Bucket(this, 'Site', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // Client-side routes (no file extension, e.g. /cartas/E1.3) get index.html; files keep their path.
    // Done at the edge instead of custom error responses, which would also turn API 403/404 into the page.
    const spaRewrite = new cloudfront.Function(this, 'SpaRewrite', {
      runtime: cloudfront.FunctionRuntime.JS_2_0,
      code: cloudfront.FunctionCode.fromInline(
        "function handler(event) { var r = event.request; if (!/\\.[a-z][a-z0-9]{0,4}$/i.test(r.uri)) { r.uri = '/index.html'; } return r; }",
      ),
    });

    const server = new origins.HttpOrigin(backend.originDomainName, {
      protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
      httpPort: props.originPort,
      customHeaders: { [ORIGIN_HEADER]: originSecret },
      // A sleeping server must fail fast so the front can show the warm-up screen and call /wake.
      connectionTimeout: cdk.Duration.seconds(2),
      connectionAttempts: 1,
      readTimeout: cdk.Duration.seconds(60),
    });
    const serverBehavior: cloudfront.BehaviorOptions = {
      origin: server,
      viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
      allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
      cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
      originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER,
    };

    const wake = new origins.FunctionUrlOrigin(backend.wakeUrl, { customHeaders: { [ORIGIN_HEADER]: originSecret } });

    this.distribution = new cloudfront.Distribution(this, 'Cdn', {
      comment: `ERAS ${props.envName}`,
      defaultRootObject: 'index.html',
      httpVersion: cloudfront.HttpVersion.HTTP2_AND_3,
      minimumProtocolVersion: props.certificateArn ? cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021 : undefined,
      priceClass: cloudfront.PriceClass.PRICE_CLASS_ALL, // players are in South America
      domainNames: props.domainNames,
      certificate: props.certificateArn ? acm.Certificate.fromCertificateArn(this, 'Cert', props.certificateArn) : undefined,
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(this.bucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        responseHeadersPolicy: cloudfront.ResponseHeadersPolicy.SECURITY_HEADERS,
        functionAssociations: [{ function: spaRewrite, eventType: cloudfront.FunctionEventType.VIEWER_REQUEST }],
      },
      additionalBehaviors: {
        '/api/*': serverBehavior,
        '/ws': serverBehavior,
        '/ws/*': serverBehavior,
        '/wake': {
          origin: wake,
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
        },
      },
    });

    new cdk.CfnOutput(this, 'BucketName', { value: this.bucket.bucketName });
    new cdk.CfnOutput(this, 'DistributionId', { value: this.distribution.distributionId });
    new cdk.CfnOutput(this, 'Url', { value: `https://${this.distribution.distributionDomainName}` });
  }
}
