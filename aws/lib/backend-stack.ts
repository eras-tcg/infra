import * as path from 'node:path';
import * as cdk from 'aws-cdk-lib';
import * as budgets from 'aws-cdk-lib/aws-budgets';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3assets from 'aws-cdk-lib/aws-s3-assets';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';

export type BackendStackProps = cdk.StackProps;

// SSM names shared with the scripts on the server (instance/bin) and in scripts/.
export const ORIGIN_SECRET_PARAM = '/eras/infra/origin-secret';
export const BUNDLE_PARAM = '/eras/infra/bundle';
// The budget alert recipient, kept out of this public repository.
export const BACKUP_BUCKET_PARAM = '/eras/infra/backup-bucket';
export const BUDGET_EMAIL_PARAM = '/eras/infra/budget-email';
export const SERVICES = ['drive-manager', 'users-service'] as const;
export const ENVIRONMENTS = ['prod', 'staging'] as const;

/**
 * The backend: one EC2 instance running both environments' Spring services in docker behind an nginx proxy
 * (prod on port 80, staging on 8080), reachable only from CloudFront. It powers itself off after 30 minutes
 * without activity and the wake Lambda starts it again.
 */
export class BackendStack extends cdk.Stack {
  readonly instance: ec2.Instance;
  readonly originDomainName: string;
  readonly wake: lambda.Function;
  readonly wakeUrl: lambda.FunctionUrl;
  readonly repositories: ecr.Repository[];

  constructor(scope: Construct, id: string, props: BackendStackProps) {
    super(scope, id, props);

    // Created once by scripts/bootstrap-params.sh (a random value); CloudFront sends it, nginx and the Lambda check it.
    const originSecret = ssm.StringParameter.valueForStringParameter(this, ORIGIN_SECRET_PARAM);

    // --- Network: one public subnet, no NAT. The instance reaches Atlas, Drive, R2 and ECR through its public IP.
    const vpc = new ec2.Vpc(this, 'Vpc', {
      ipAddresses: ec2.IpAddresses.cidr('10.40.0.0/16'),
      maxAzs: 1,
      natGateways: 0,
      subnetConfiguration: [{ name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 }],
    });

    const sg = new ec2.SecurityGroup(this, 'ServerSg', { vpc, description: 'ERAS backend: only CloudFront', allowAllOutbound: true });
    // One rule for both proxy ports (80 prod, 8080 staging): the CloudFront prefix list weighs ~55 rules per use.
    const cloudFrontPrefixList = ec2.PrefixList.fromLookup(this, 'CloudFrontOrigins', {
      prefixListName: 'com.amazonaws.global.cloudfront.origin-facing',
    });
    sg.addIngressRule(ec2.Peer.prefixList(cloudFrontPrefixList.prefixListId), ec2.Port.tcpRange(80, 8080), 'CloudFront to the proxy');

    // --- Images: CI pushes here, the instance pulls with its role (no registry token on the server).
    this.repositories = SERVICES.map(
      (svc) =>
        new ecr.Repository(this, `Repo-${svc}`, {
          repositoryName: `eras/${svc}`,
          imageScanOnPush: true,
          imageTagMutability: ecr.TagMutability.IMMUTABLE,
          lifecycleRules: [{ description: 'keep the last 20 images', maxImageCount: 20 }],
          removalPolicy: cdk.RemovalPolicy.RETAIN,
        }),
    );

    // --- Logs of every container (docker awslogs driver).
    const logGroups = ENVIRONMENTS.map(
      (envName) =>
        new logs.LogGroup(this, `Logs-${envName}`, {
          logGroupName: `/eras/${envName}`,
          retention: logs.RetentionDays.TWO_WEEKS,
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }),
    );

    // --- Scripts and systemd units for the server. Every boot syncs the bundle named by BUNDLE_PARAM, so a
    // change here reaches the server on its next start (or with `eras-sync` through Session Manager).
    const bundle = new s3assets.Asset(this, 'ServerBundle', { path: path.join(import.meta.dirname, '..', 'instance') });
    const bundleParam = new ssm.StringParameter(this, 'BundleParam', {
      parameterName: BUNDLE_PARAM,
      stringValue: bundle.s3ObjectUrl,
      description: 'Scripts and units of the ERAS server (synced at boot)',
    });

    const role = new iam.Role(this, 'ServerRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')],
    });
    bundle.grantRead(role);
    this.repositories.forEach((repo) => repo.grantPull(role));
    logGroups.forEach((group) => group.grantWrite(role));
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['ssm:GetParameter', 'ssm:GetParameters', 'ssm:GetParametersByPath'],
        resources: [this.formatArn({ service: 'ssm', resource: 'parameter', resourceName: 'eras/*' })],
      }),
    );
    // eras-deploy records the image it runs, and goes back to the previous one when the new one is unhealthy.
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['ssm:PutParameter'],
        resources: ENVIRONMENTS.flatMap((e) =>
          SERVICES.map((s) => this.formatArn({ service: 'ssm', resource: 'parameter', resourceName: `eras/${e}/${s}/image` })),
        ),
      }),
    );

    // --- Daily MongoDB dumps (eras-backup on the server, started by .github/workflows/backup-mongo.yml).
    const backups = new s3.Bucket(this, 'Backups', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      lifecycleRules: [{ id: 'keep-30-days', expiration: cdk.Duration.days(30) }],
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    backups.grantPut(role, 'mongo/*');
    backups.grantRead(role, 'mongo/*');
    new ssm.StringParameter(this, 'BackupBucketParam', {
      parameterName: BACKUP_BUCKET_PARAM,
      stringValue: backups.bucketName,
      description: 'Bucket of the daily MongoDB dumps',
    });

    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      'set -euxo pipefail',
      'dnf install -y docker jq unzip',
      // Compose v2 plugin (not packaged for Amazon Linux 2023).
      'mkdir -p /usr/local/lib/docker/cli-plugins',
      'curl -fsSL https://github.com/docker/compose/releases/download/v2.39.2/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose',
      'chmod +x /usr/local/lib/docker/cli-plugins/docker-compose',
      'systemctl enable --now docker',
      // 2 GB of swap: four JVMs share 4 GB.
      'if [ ! -f /swapfile ]; then dd if=/dev/zero of=/swapfile bs=1M count=2048 && chmod 600 /swapfile && mkswap /swapfile; fi',
      'grep -q /swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab',
      'swapon -a',
      'mkdir -p /opt/eras/releases',
      `printf 'REGION=%s\\nACCOUNT=%s\\nBUNDLE_PARAM=%s\\n' ${this.region} ${this.account} ${BUNDLE_PARAM} > /opt/eras/infra.env`,
      // eras-sync: unpacks the bundle into its own release folder and points /opt/eras/current at it.
      `cat > /usr/local/bin/eras-sync <<'EOF'
#!/bin/bash
set -euo pipefail
source /opt/eras/infra.env
url=$(aws ssm get-parameter --region "$REGION" --name "$BUNDLE_PARAM" --query Parameter.Value --output text)
dir=/opt/eras/releases/$(basename "$url" .zip)
if [ ! -d "$dir" ]; then
  tmp=$(mktemp -d)
  aws s3 cp --region "$REGION" --only-show-errors "$url" "$tmp/bundle.zip"
  unzip -q "$tmp/bundle.zip" -d "$tmp/x"
  chmod +x "$tmp/x/bin/"*
  mv "$tmp/x" "$dir"
  rm -rf "$tmp"
fi
ln -sfn "$dir" /opt/eras/current
install -m 644 /opt/eras/current/systemd/* /etc/systemd/system/
systemctl daemon-reload
EOF`,
      'chmod +x /usr/local/bin/eras-sync',
      '/usr/local/bin/eras-sync',
      'systemctl enable eras.service eras-idle.timer',
      'systemctl start eras.service eras-idle.timer',
    );

    this.instance = new ec2.Instance(this, 'Server', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3A, ec2.InstanceSize.MEDIUM),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({ cachedInContext: true }),
      securityGroup: sg,
      role,
      userData,
      requireImdsv2: true,
      associatePublicIpAddress: true,
      instanceInitiatedShutdownBehavior: ec2.InstanceInitiatedShutdownBehavior.STOP,
      blockDevices: [
        { deviceName: '/dev/xvda', volume: ec2.BlockDeviceVolume.ebs(30, { volumeType: ec2.EbsDeviceVolumeType.GP3, encrypted: true }) },
      ],
    });
    this.instance.node.addDependency(bundleParam);

    // Fixed address: Atlas allows it by IP, and CloudFront reaches the instance by its public DNS name.
    const eip = new ec2.CfnEIP(this, 'ServerIp', { domain: 'vpc', tags: [{ key: 'Name', value: 'eras-server' }] });
    new ec2.CfnEIPAssociation(this, 'ServerIpAssociation', { allocationId: eip.attrAllocationId, instanceId: this.instance.instanceId });
    this.originDomainName = cdk.Fn.join('', [
      'ec2-',
      cdk.Fn.join('-', cdk.Fn.split('.', eip.attrPublicIp)),
      `.${this.region}.compute.amazonaws.com`,
    ]);

    // --- Wake: CloudFront /wake → this function → StartInstances. Its URL is public but answers only to the
    // origin secret CloudFront adds (the front calls it with POST, which origin access control cannot sign).
    const wake = (this.wake = new lambda.Function(this, 'Wake', {
      runtime: lambda.Runtime.PYTHON_3_13,
      architecture: lambda.Architecture.ARM_64,
      handler: 'wake.handler',
      code: lambda.Code.fromAsset(path.join(import.meta.dirname, '..', 'lambda')),
      timeout: cdk.Duration.seconds(10),
      memorySize: 128,
      environment: { INSTANCE_ID: this.instance.instanceId, ORIGIN_SECRET: originSecret },
      logGroup: new logs.LogGroup(this, 'WakeLogs', { retention: logs.RetentionDays.TWO_WEEKS, removalPolicy: cdk.RemovalPolicy.DESTROY }),
    }));
    wake.addToRolePolicy(new iam.PolicyStatement({ actions: ['ec2:DescribeInstances'], resources: ['*'] }));
    wake.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['ec2:StartInstances'],
        resources: [this.formatArn({ service: 'ec2', resource: 'instance', resourceName: this.instance.instanceId })],
      }),
    );
    this.wakeUrl = wake.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });

    // --- Monthly budget: e-mail when the month reaches USD 20 or is forecast to. The project's spend limit
    // (AWS Settings, USD 35) pauses everything when reached, so this warns well before it.
    const budgetEmail = ssm.StringParameter.valueForStringParameter(this, BUDGET_EMAIL_PARAM);
    new budgets.CfnBudget(this, 'Budget', {
      budget: { budgetName: 'eras-spend-alert', budgetType: 'COST', timeUnit: 'MONTHLY', budgetLimit: { amount: 20, unit: 'USD' } },
      notificationsWithSubscribers: [
        {
          notification: { notificationType: 'ACTUAL', comparisonOperator: 'GREATER_THAN', threshold: 100, thresholdType: 'PERCENTAGE' },
          subscribers: [{ subscriptionType: 'EMAIL', address: budgetEmail }],
        },
        {
          notification: { notificationType: 'FORECASTED', comparisonOperator: 'GREATER_THAN', threshold: 100, thresholdType: 'PERCENTAGE' },
          subscribers: [{ subscriptionType: 'EMAIL', address: budgetEmail }],
        },
      ],
    });

    new cdk.CfnOutput(this, 'InstanceId', { value: this.instance.instanceId });
    new cdk.CfnOutput(this, 'PublicIp', { value: eip.attrPublicIp, description: 'Add to the Atlas IP access list' });
    new cdk.CfnOutput(this, 'OriginDomainName', { value: this.originDomainName });
    new cdk.CfnOutput(this, 'BackupBucket', { value: backups.bucketName });
    this.repositories.forEach((repo, i) => new cdk.CfnOutput(this, `Repo${i}`, { value: repo.repositoryUri }));
  }
}
