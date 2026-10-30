import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import { BackendStack, ENVIRONMENTS, SERVICES } from './backend-stack.js';
import { SiteStack } from './site-stack.js';

export interface CiStackProps extends cdk.StackProps {
  backend: BackendStack;
  sites: SiteStack[];
}

/**
 * What GitHub Actions may do in AWS: push images to ECR, upload the site and invalidate CloudFront, start the
 * server and run eras-deploy on it through SSM. The project's policies block IAM identity providers (no OIDC),
 * so the identity is the user eras-ci; its access key is created outside CloudFormation (scripts/ci-access-key.sh)
 * and kept only in GitHub secrets.
 */
export class CiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CiStackProps) {
    super(scope, id, props);
    const { backend, sites } = props;
    const instanceArn = backend.formatArn({ service: 'ec2', resource: 'instance', resourceName: backend.instance.instanceId });

    const policy = new iam.ManagedPolicy(this, 'DeployPolicy', {
      managedPolicyName: 'eras-ci-deploy',
      statements: [
        new iam.PolicyStatement({ actions: ['ecr:GetAuthorizationToken'], resources: ['*'] }),
        new iam.PolicyStatement({
          actions: [
            'ecr:BatchCheckLayerAvailability',
            'ecr:BatchGetImage',
            'ecr:CompleteLayerUpload',
            'ecr:DescribeImages',
            'ecr:GetDownloadUrlForLayer',
            'ecr:InitiateLayerUpload',
            'ecr:PutImage',
            'ecr:UploadLayerPart',
          ],
          resources: backend.repositories.map((r) => r.repositoryArn),
        }),
        new iam.PolicyStatement({ actions: ['s3:ListBucket'], resources: sites.map((s) => s.bucket.bucketArn) }),
        new iam.PolicyStatement({
          actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
          resources: sites.map((s) => s.bucket.arnForObjects('*')),
        }),
        new iam.PolicyStatement({
          actions: ['cloudfront:CreateInvalidation', 'cloudfront:GetInvalidation'],
          resources: sites.map((s) => s.distribution.distributionArn),
        }),
        // The deploy scripts find the bucket and distribution in the site stacks' outputs.
        new iam.PolicyStatement({ actions: ['cloudformation:DescribeStacks'], resources: sites.map((s) => s.stackId) }),
        new iam.PolicyStatement({ actions: ['ec2:DescribeInstances', 'ec2:DescribeInstanceStatus'], resources: ['*'] }),
        new iam.PolicyStatement({ actions: ['ec2:StartInstances'], resources: [instanceArn] }),
        new iam.PolicyStatement({
          actions: ['ssm:SendCommand'],
          resources: [instanceArn, `arn:aws:ssm:${this.region}::document/AWS-RunShellScript`],
        }),
        new iam.PolicyStatement({ actions: ['ssm:GetCommandInvocation', 'ssm:ListCommandInvocations'], resources: ['*'] }),
        new iam.PolicyStatement({
          actions: ['ssm:GetParameter'],
          resources: ENVIRONMENTS.flatMap((e) =>
            SERVICES.map((s) => this.formatArn({ service: 'ssm', resource: 'parameter', resourceName: `eras/${e}/${s}/image` })),
          ),
        }),
      ],
    });

    const user = new iam.User(this, 'CiUser', { userName: 'eras-ci', managedPolicies: [policy] });
    new cdk.CfnOutput(this, 'CiUserName', { value: user.userName });
  }
}
