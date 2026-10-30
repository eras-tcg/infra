#!/usr/bin/env node
// ERAS on AWS. Everything lives in the project's Region (us-east-2); CloudFront is global.
// The CloudFront certificate lives in us-east-1, where the project cannot run CloudFormation, so it is created
// with scripts/request-certificate.sh; its ARN is the context "certificateArn" in cdk.json.
// DNS cutover from Contabo to AWS, per host: context "cutover" in cdk.json ("staging", "prod,staging", or "" to go back)
import * as cdk from 'aws-cdk-lib';
import { BackendStack } from '../lib/backend-stack.js';
import { CiStack } from '../lib/ci-stack.js';
import { DnsStack } from '../lib/dns-stack.js';
import { SiteStack } from '../lib/site-stack.js';
import { ZoneStack } from '../lib/zone-stack.js';

const app = new cdk.App();
const env = { account: '211078959523', region: 'us-east-2' };
const domain = 'erastcg.com';
const certificateArn: string | undefined = app.node.tryGetContext('certificateArn');
const cutover = String(app.node.tryGetContext('cutover') ?? '').split(',').filter(Boolean);

cdk.Tags.of(app).add('project', 'eras');

const zone = new ZoneStack(app, 'ErasZone', { env, domain });
const backend = new BackendStack(app, 'ErasBackend', { env });

const prod = new SiteStack(app, 'ErasSiteProd', {
  env,
  envName: 'prod',
  backend,
  originPort: 80,
  domainNames: certificateArn ? [domain, `www.${domain}`] : undefined,
  certificateArn,
});
const staging = new SiteStack(app, 'ErasSiteStaging', {
  env,
  envName: 'staging',
  backend,
  originPort: 8080,
  domainNames: certificateArn ? [`staging.${domain}`] : undefined,
  certificateArn,
});

new DnsStack(app, 'ErasDns', {
  env,
  zone: zone.zone,
  contaboIp: '161.97.173.61',
  prod: cutover.includes('prod') ? prod.distribution : undefined,
  staging: cutover.includes('staging') ? staging.distribution : undefined,
});

new CiStack(app, 'ErasCi', { env, backend, sites: [prod, staging] });
