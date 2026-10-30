# eras-tcg/infra

Infraestructura y despliegue de ERAS (erastcg.com) en AWS. Todo está documentado en [`aws/README.md`](aws/README.md).

- [`aws/`](aws/): app CDK (TypeScript) con los stacks, los scripts y unidades systemd del servidor y los scripts de operación.
- [`.github/workflows/deploy-aws.yml`](.github/workflows/deploy-aws.yml): deploy reutilizable de los backends
  (DriveManager, ErasUsersService). Copia la imagen de GHCR a ECR y ejecuta `eras-deploy` en el servidor por SSM,
  con healthcheck y rollback.
- [`.github/workflows/deploy-site-aws.yml`](.github/workflows/deploy-site-aws.yml): deploy reutilizable del front
  (eras-web) a S3 + CloudFront.
- [`.github/workflows/backup-mongo.yml`](.github/workflows/backup-mongo.yml): backup diario de `eras_db` a S3.

## Flujo

```
PR a develop/main ──► test + build (runner de GitHub)                   sin deploy
push a develop    ──► build + push ghcr.io/eras-tcg/<svc>:<sha> ──► deploy staging (automático)
push a main       ──► build + push ──► deploy production (espera aprobación en GitHub)
Run workflow      ──► redeploy de una imagen existente (rollback) a staging o production
```

La aprobación de producción la da el GitHub Environment `production` de cada repo (revisor CapitanPio). Las ramas
`develop`/`main` solo aceptan cambios por PR.

Hasta el 2026-10-30 ERAS corría en un VPS de Contabo con un runner self-hosted. Ese despliegue (`deploy.yml`,
`deploy/`, `server/`, `ops/`, `aws/scripts/copy-vps-env.sh`) se puede ver en el historial de git.
