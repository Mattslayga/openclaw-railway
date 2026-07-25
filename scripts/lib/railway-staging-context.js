import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function validateStagingContext(status, expectedProjectId, serviceName) {
  if (expectedProjectId && status.id !== expectedProjectId) {
    throw new Error(
      `linked Railway project is ${status.name} (${status.id}), expected ${expectedProjectId}`,
    );
  }

  const staging = status.environments?.edges
    ?.map((edge) => edge.node)
    .find((environment) => environment?.name === 'staging');
  if (!staging) {
    throw new Error(`linked Railway project ${status.name} has no staging environment`);
  }

  const service = staging.serviceInstances?.edges
    ?.map((edge) => edge.node)
    .find((instance) => instance?.serviceName === serviceName);
  if (!service) {
    throw new Error(`staging service ${serviceName} was not found`);
  }

  const sleepApplication =
    service.latestDeployment?.meta?.serviceManifest?.deploy?.sleepApplication;
  if (sleepApplication !== true) {
    throw new Error(
      `staging service ${serviceName} must have Railway Serverless (sleep when inactive) enabled`,
    );
  }

  return {
    projectId: status.id,
    projectName: status.name,
    environmentId: staging.id,
    environmentName: staging.name,
    serviceId: service.serviceId,
    serviceName: service.serviceName,
    sleepApplication,
  };
}

function main() {
  const [statusPath, expectedProjectId, serviceName] = process.argv.slice(2);
  if (!statusPath || !serviceName) {
    console.error(
      'Usage: node scripts/lib/railway-staging-context.js <status-json> [project-id] <service-name>',
    );
    process.exit(2);
  }

  try {
    const status = JSON.parse(fs.readFileSync(statusPath, 'utf8'));
    const context = validateStagingContext(status, expectedProjectId, serviceName);
    process.stdout.write(`${JSON.stringify(context, null, 2)}\n`);
  } catch (error) {
    console.error(`ERROR: ${error.message}.`);
    process.exit(1);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
