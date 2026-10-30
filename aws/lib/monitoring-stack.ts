import * as cdk from 'aws-cdk-lib';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as actions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { BackendStack, BUDGET_EMAIL_PARAM, ENVIRONMENTS } from './backend-stack.js';
import { SiteStack } from './site-stack.js';

export interface MonitoringStackProps extends cdk.StackProps {
  backend: BackendStack;
  sites: SiteStack[];
}

const NAMESPACE = 'ERAS';

/**
 * How ERAS is doing, in one CloudWatch dashboard ("ERAS"), and e-mail alarms for what needs a person: the server
 * broken (not asleep), the wake function failing, prod logging errors, or the server never going to sleep.
 * Everything fits the free tier (dashboards, alarms and the two log metrics). A stopped server sends no metrics,
 * so missing data is never an alarm: sleeping is the normal state.
 */
export class MonitoringStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: MonitoringStackProps) {
    super(scope, id, props);
    const { backend, sites } = props;
    const instanceId = backend.instance.instanceId;

    const topic = new sns.Topic(this, 'Alerts', { topicName: 'eras-alerts', displayName: 'ERAS' });
    // Same recipient as the budget alert; AWS e-mails a confirmation link first.
    const email = ssm.StringParameter.valueForStringParameter(this, BUDGET_EMAIL_PARAM);
    topic.addSubscription(new subscriptions.EmailSubscription(email));
    const notify = new actions.SnsAction(topic);

    const ec2Metric = (metricName: string, statistic: string, period = cdk.Duration.minutes(5)) =>
      new cloudwatch.Metric({ namespace: 'AWS/EC2', metricName, dimensionsMap: { InstanceId: instanceId }, statistic, period });

    // --- Errors in the Spring services' logs (Spring Boot lines read "<time>  ERROR 1 --- [app] ...").
    const errorMetrics = Object.fromEntries(
      ENVIRONMENTS.map((envName) => {
        const filter = new logs.MetricFilter(this, `Errors-${envName}`, {
          logGroup: logs.LogGroup.fromLogGroupName(this, `Logs-${envName}`, `/eras/${envName}`),
          filterPattern: logs.FilterPattern.literal('"ERROR 1 ---"'),
          metricNamespace: NAMESPACE,
          metricName: `BackendErrors-${envName}`,
          metricValue: '1',
        });
        return [envName, filter.metric({ statistic: 'Sum', period: cdk.Duration.minutes(5), label: envName })];
      }),
    );

    // --- Alarms
    const alarms = [
      new cloudwatch.Alarm(this, 'ServerBroken', {
        alarmName: 'eras-server-broken',
        alarmDescription: 'The ERAS server is running but fails its EC2 status checks (broken, not asleep).',
        metric: ec2Metric('StatusCheckFailed', 'Maximum', cdk.Duration.minutes(1)),
        threshold: 1,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        evaluationPeriods: 5,
        datapointsToAlarm: 3,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      }),
      new cloudwatch.Alarm(this, 'WakeFailing', {
        alarmName: 'eras-wake-failing',
        alarmDescription: 'The wake function fails: a sleeping server cannot be started from the site.',
        metric: backend.wake.metricErrors({ period: cdk.Duration.minutes(5), statistic: 'Sum' }),
        threshold: 1,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      }),
      new cloudwatch.Alarm(this, 'ProdErrors', {
        alarmName: 'eras-prod-errors',
        alarmDescription: 'The prod services logged 5 or more ERROR lines in 5 minutes (see /eras/prod).',
        metric: errorMetrics.prod,
        threshold: 5,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      }),
      // CPU is sampled every 5 minutes while the server runs: 140 of 144 samples in 12 hours means it never slept,
      // so eras-idle is not powering it off and the month costs the always-on price.
      new cloudwatch.Alarm(this, 'NeverSleeps', {
        alarmName: 'eras-server-never-sleeps',
        alarmDescription: 'The ERAS server has been on for ~12 hours straight: check eras-idle (cost).',
        metric: ec2Metric('CPUUtilization', 'SampleCount', cdk.Duration.hours(12)),
        threshold: 140,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      }),
    ];
    alarms.forEach((alarm) => {
      alarm.addAlarmAction(notify);
      alarm.addOkAction(notify);
    });

    // --- Dashboard. CloudFront publishes its metrics only in us-east-1; the widgets read them from there.
    const cdnMetric = (site: SiteStack, metricName: string, statistic: string, label: string) =>
      new cloudwatch.Metric({
        namespace: 'AWS/CloudFront',
        metricName,
        region: 'us-east-1',
        dimensionsMap: { DistributionId: site.distribution.distributionId, Region: 'Global' },
        statistic,
        period: cdk.Duration.minutes(5),
        label,
      });
    const siteName = (site: SiteStack) => (site.node.id.endsWith('Prod') ? 'prod' : 'staging');
    const dashboard = new cloudwatch.Dashboard(this, 'Dashboard', {
      dashboardName: 'ERAS',
      defaultInterval: cdk.Duration.days(1),
    });
    dashboard.addWidgets(
      new cloudwatch.TextWidget({
        width: 24,
        height: 2,
        markdown:
          '# ERAS\nServidor sin datos = dormido (normal). Se despierta solo al entrar alguien al sitio. ' +
          'Alarmas por e-mail; gasto del mes en Billing → Budgets (`eras-spend-alert`).',
      }),
    );
    dashboard.addWidgets(
      new cloudwatch.AlarmStatusWidget({ title: 'Alarmas', alarms, width: 8, height: 4 }),
      new cloudwatch.GraphWidget({
        title: 'Servidor: CPU (sin línea = dormido)',
        left: [ec2Metric('CPUUtilization', 'Average').with({ label: 'CPU %' })],
        leftYAxis: { min: 0, max: 100 },
        width: 8,
        height: 4,
      }),
      new cloudwatch.GraphWidget({
        title: 'Despertares (función wake)',
        left: [
          backend.wake.metricInvocations({ statistic: 'Sum', label: 'llamadas' }),
          backend.wake.metricErrors({ statistic: 'Sum', label: 'errores' }),
        ],
        width: 8,
        height: 4,
      }),
    );
    dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: 'Visitas (requests CloudFront)',
        left: sites.map((site) => cdnMetric(site, 'Requests', 'Sum', siteName(site))),
        width: 8,
        height: 6,
      }),
      new cloudwatch.GraphWidget({
        title: 'Errores del sitio % (5xx)',
        left: sites.map((site) => cdnMetric(site, '5xxErrorRate', 'Average', siteName(site))),
        leftYAxis: { min: 0 },
        width: 8,
        height: 6,
      }),
      new cloudwatch.GraphWidget({
        title: 'Errores en logs del backend',
        left: ENVIRONMENTS.map((envName) => errorMetrics[envName]),
        leftYAxis: { min: 0 },
        width: 8,
        height: 6,
      }),
    );
    dashboard.addWidgets(
      new cloudwatch.LogQueryWidget({
        title: 'Últimos errores (prod)',
        logGroupNames: ['/eras/prod'],
        queryLines: ['fields @timestamp, @logStream, @message', 'filter @message like /ERROR 1 ---/', 'sort @timestamp desc', 'limit 20'],
        width: 24,
        height: 6,
      }),
    );

    new cdk.CfnOutput(this, 'DashboardUrl', {
      value: `https://${this.region}.console.aws.amazon.com/cloudwatch/home?region=${this.region}#dashboards/dashboard/ERAS`,
    });
  }
}
