import { CfnOutput, Duration, RemovalPolicy, Stack, StackProps, Tags } from 'aws-cdk-lib';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as secrets from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

export const SECRET_ID = '/raptgen-ui-web/edge-auth';
export const FULL_GROUP = 'raptgen-full';
export const READONLY_GROUP = 'raptgen-readonly';

export interface RaptGenUiWebProps extends StackProps {
  originInstanceArn: string; // private EC2 (any Region) reached through a CloudFront VPC origin
  originPrivateDns: string;
  originPort: number;
  cognitoDomainPrefix: string; // unique per Region; chosen in bin/app.ts
}

/** VPC origin endpoint by ARN (the instance lives in another Region than this stack). */
class ArnEndpoint extends cloudfront.VpcOriginEndpoint {
  constructor(public readonly endpointArn: string, public readonly domainName?: string) { super(); }
}

/**
 * Browser -> CloudFront (HTTPS) -> Lambda@Edge (Cognito login + group check, fail-closed)
 *         -> VPC origin (CloudFront-managed ENI in the private subnet) -> EC2:18042 (HTTP, VPC-internal)
 * The EC2 security group is opened ONLY to the CloudFront VPC-origin service SG, and only after
 * scripts/verify-gate.sh shows anonymous requests are denied.
 */
export class RaptGenUiWebStack extends Stack {
  constructor(scope: Construct, id: string, props: RaptGenUiWebProps) {
    super(scope, id, props);
    Tags.of(this).add('Component', 'raptgen-ui-web');
    const COGNITO_DOMAIN_PREFIX = props.cognitoDomainPrefix;

    const logs = new s3.Bucket(this, 'LogBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_PREFERRED, // CloudFront standard logs need ACLs
      lifecycleRules: [{ expiration: Duration.days(90) }],
      removalPolicy: RemovalPolicy.RETAIN,
    });

    // ── Identity: admin-created users only, two roles ──
    const pool = new cognito.UserPool(this, 'Users', {
      userPoolName: 'raptgen-ui-web',
      featurePlan: cognito.FeaturePlan.LITE,
      selfSignUpEnabled: false,
      signInAliases: { username: true },
      signInCaseSensitive: false,
      mfa: cognito.Mfa.OPTIONAL,
      mfaSecondFactor: { otp: true, sms: false },
      passwordPolicy: {
        minLength: 14, requireDigits: true, requireLowercase: true, requireUppercase: true, requireSymbols: true,
        tempPasswordValidity: Duration.days(7),
      },
      accountRecovery: cognito.AccountRecovery.NONE,
      deletionProtection: true,
      removalPolicy: RemovalPolicy.RETAIN,
    });
    const domain = pool.addDomain('Domain', { cognitoDomain: { domainPrefix: COGNITO_DOMAIN_PREFIX } });
    new cognito.CfnUserPoolGroup(this, 'FullGroup', {
      userPoolId: pool.userPoolId, groupName: FULL_GROUP,
      description: 'RaptGen-UI: every action (upload, train, GMM, Bayesian optimization, delete)',
    });
    new cognito.CfnUserPoolGroup(this, 'ReadOnlyGroup', {
      userPoolId: pool.userPoolId, groupName: READONLY_GROUP,
      description: 'RaptGen-UI: view models and latent space, encode/decode only; no writes',
    });

    const edgeFn = new cloudfront.experimental.EdgeFunction(this, 'EdgeAuth', {
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset(path.join(here, '..', 'edge', 'dist')),
      memorySize: 128,
      timeout: Duration.seconds(5),
      description: 'Cognito login gate + role check for RaptGen-UI',
    });

    const headers = new cloudfront.ResponseHeadersPolicy(this, 'SecurityHeaders', {
      securityHeadersBehavior: {
        strictTransportSecurity: { accessControlMaxAge: Duration.days(365), includeSubdomains: true, override: true },
        contentTypeOptions: { override: true },
        frameOptions: { frameOption: cloudfront.HeadersFrameOption.DENY, override: true },
        referrerPolicy: { referrerPolicy: cloudfront.HeadersReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN, override: true },
      },
      customHeadersBehavior: {
        customHeaders: [{ header: 'X-Robots-Tag', value: 'noindex, nofollow', override: true }],
      },
    });

    const vpcOrigin = new cloudfront.VpcOrigin(this, 'Ec2Origin', {
      vpcOriginName: 'raptgen-ui-dev-ec2',
      endpoint: new ArnEndpoint(props.originInstanceArn, props.originPrivateDns),
      httpPort: props.originPort,
      protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
    });

    const dist = new cloudfront.Distribution(this, 'Cdn', {
      comment: 'RaptGen-UI (Cognito-gated, full/read-only roles, private EC2 origin)',
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
      httpVersion: cloudfront.HttpVersion.HTTP2,
      enableLogging: true,
      logBucket: logs,
      logFilePrefix: 'cloudfront/',
      defaultBehavior: {
        origin: origins.VpcOrigin.withVpcOrigin(vpcOrigin, {
          domainName: props.originPrivateDns,
          readTimeout: Duration.seconds(60),
        }),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
        responseHeadersPolicy: headers,
        edgeLambdas: [{ functionVersion: edgeFn.currentVersion, eventType: cloudfront.LambdaEdgeEventType.VIEWER_REQUEST }],
      },
    });

    const siteUrl = `https://${dist.distributionDomainName}`;
    const client = pool.addClient('WebClient', {
      userPoolClientName: 'raptgen-ui-web',
      generateSecret: false,
      authFlows: {},
      preventUserExistenceErrors: true,
      enableTokenRevocation: true,
      accessTokenValidity: Duration.hours(1),
      idTokenValidity: Duration.hours(1),
      refreshTokenValidity: Duration.days(1),
      supportedIdentityProviders: [cognito.UserPoolClientIdentityProvider.COGNITO],
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.PROFILE],
        callbackUrls: [`${siteUrl}/oauth2/idpresponse`],
        logoutUrls: [`${siteUrl}/`],
      },
    });

    new secrets.Secret(this, 'EdgeAuthConfig', {
      secretName: SECRET_ID,
      description: 'Lambda@Edge Cognito gate config for RaptGen-UI',
      generateSecretString: {
        secretStringTemplate: Stack.of(this).toJsonString({
          region: this.region,
          userPoolId: pool.userPoolId,
          clientId: client.userPoolClientId,
          domain: `${COGNITO_DOMAIN_PREFIX}.auth.${this.region}.amazoncognito.com`,
        }),
        generateStringKey: 'nonceSigningSecret',
        excludePunctuation: true,
        passwordLength: 48,
      },
      removalPolicy: RemovalPolicy.DESTROY,
    });
    edgeFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['secretsmanager:GetSecretValue'],
      resources: [`arn:aws:secretsmanager:us-east-1:${this.account}:secret:${SECRET_ID}-*`],
    }));
    domain.node.addDependency(pool);

    new CfnOutput(this, 'SiteUrl', { value: siteUrl });
    new CfnOutput(this, 'DistributionId', { value: dist.distributionId });
    new CfnOutput(this, 'VpcOriginId', { value: vpcOrigin.vpcOriginId });
    new CfnOutput(this, 'UserPoolId', { value: pool.userPoolId });
    new CfnOutput(this, 'UserPoolClientId', { value: client.userPoolClientId });
    new CfnOutput(this, 'CognitoDomain', { value: `${COGNITO_DOMAIN_PREFIX}.auth.${this.region}.amazoncognito.com` });
  }
}
