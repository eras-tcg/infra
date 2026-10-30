# ERAS en AWS

Infraestructura de erastcg.com en AWS (proyecto `211078959523`, Región **us-east-2**), escrita en CDK (TypeScript).
Reemplaza al VPS de Contabo. MongoDB Atlas, Cloudflare R2 (imágenes) y Google Drive (API) no cambian.

```
Usuario ──► CloudFront  erastcg.com / staging.erastcg.com
              ├─ /*           → S3 (build Angular "aws", privado con OAC; rutas sin extensión → index.html)
              ├─ /wake        → Lambda Wake (StartInstances; responde solo con el header secreto)
              └─ /api/*, /ws  → EC2 :80 (prod) / :8080 (staging), header X-Eras-Origin obligatorio
                                 nginx ─► {env}-drive-manager :8081   (/api/*, /ws)
                                       └► {env}-users-service :8082   (/api/auth|users|roles|permissions)
EC2 (t3a.medium, Amazon Linux 2023, docker) ─► Atlas · R2 · Drive API · ECR
Se apaga solo tras 30 min sin actividad (eras-idle); la Lambda lo enciende.
```

## Stacks

| Stack | Contenido |
|---|---|
| `ErasZone` | Zona pública Route 53 `erastcg.com` (protegida contra borrado) |
| `ErasBackend` | VPC (1 subred pública, sin NAT), security group solo CloudFront, EC2 + IP elástica, ECR `eras/drive-manager` y `eras/users-service`, logs `/eras/prod` y `/eras/staging` (14 días), bucket de backups de Mongo (30 días), Lambda Wake, presupuesto mensual con aviso por correo (destinatario en SSM `/eras/infra/budget-email`) |
| `ErasSiteProd` / `ErasSiteStaging` | Bucket del sitio + distribución CloudFront |
| `ErasDns` | Registros del dominio: hoy copian DonWeb (todo al VPS); `-c cutover=prod,staging` los pasa a CloudFront |
| `ErasCi` | Usuario IAM `eras-ci` con la política mínima de despliegue |

Restricciones del proyecto ("new AWS experience") que dan forma a esto:
- **Sin proveedores OIDC** (`iam:*Provider*` bloqueado): GitHub Actions usa una llave del usuario `eras-ci` guardada en secrets de GitHub.
- **Sin CloudFormation en us-east-1**: el certificado de CloudFront (que vive en us-east-1) se crea con `scripts/request-certificate.sh` y CDK recibe su ARN.
- Todo lo regional va en us-east-2.

## Comandos

Requisitos: Node 20+, AWS CLI v2 con el perfil `eras` (`aws login --profile eras`), `jq`, `openssl`. Desde `aws/`:

```bash
npm ci
npx cdk synth --strict --profile eras
npx cdk diff --profile eras
npx cdk deploy <Stack> --profile eras [-c certificateArn=...] [-c cutover=prod,staging]
```

**Nunca** usar el perfil `default` en este PC (son credenciales de otro trabajo).

## Puesta en marcha (orden)

1. `npx cdk bootstrap aws://211078959523/us-east-2 --profile eras` (una vez).
2. `scripts/bootstrap-params.sh` → secreto `/eras/infra/origin-secret`.
3. `npx cdk deploy ErasZone ErasBackend ErasSiteProd ErasSiteStaging ErasDns ErasCi --profile eras`.
4. **Atlas**: agregar la IP de salida `ErasBackend.PublicIp` a *Network Access*.
5. **Variables de cada servicio** → SSM: `scripts/env-to-ssm.sh <prod|staging> <servicio> <archivo.env>` (los `.env` del VPS en `/etc/<servicio>[-staging]/.env`). Ajustar los que nombran el dominio o la máquina (ver abajo).
6. **Imágenes** → ECR y primer deploy: `scripts/deploy-backend.sh <env> <servicio> <uri:tag>`.
7. **Front**: `ng build --configuration aws` y `scripts/deploy-site.sh <env> dist/eras-web/browser`.
8. Probar en las URLs `https://dxxxx.cloudfront.net` (salidas `Url` de los stacks del sitio).
9. **DNS**: en DonWeb cambiar los nameservers a los de `ErasZone.NameServers`. Como la zona copia DonWeb, nada cambia todavía.
10. `scripts/request-certificate.sh` → cuando el estado sea `ISSUED`: `npx cdk deploy ErasSiteProd ErasSiteStaging -c certificateArn=<arn>`.
11. **Corte**: `npx cdk deploy ErasDns -c certificateArn=<arn> -c cutover=staging` → probar → `-c cutover=prod,staging`. Volver atrás = desplegar sin `cutover`.
12. Después del corte: apagar Contabo cuando producción lleve unos días estable.

## Configuración en SSM Parameter Store

| Parámetro | Tipo | Quién lo escribe |
|---|---|---|
| `/eras/infra/origin-secret` | String | `bootstrap-params.sh` |
| `/eras/infra/bundle` | String | CDK (`ErasBackend`): zip de `instance/` |
| `/eras/<env>/<servicio>/image` | String | `eras-deploy` en el servidor |
| `/eras/<env>/<servicio>/env/<VARIABLE>` | SecureString | `env-to-ssm.sh` |

`eras-up` arma el `.env` de cada contenedor con esos parámetros. Cambiar una variable: `env-to-ssm.sh` (o
`aws ssm put-parameter`) y luego recrear: `deploy-backend.sh` con la misma imagen, o `sudo /opt/eras/current/bin/eras-up`
en el servidor.

Variables que cambian respecto del VPS:
- `SERVER_PORT` la fija compose (8081 / 8082): no hace falta en SSM.
- `CORS_ALLOWED_ORIGINS`: el dominio público (y la URL `*.cloudfront.net` mientras se prueba).
- `DRIVE_WEBHOOK_URL`: `https://<dominio>/api/drive/webhook` (llega por CloudFront).
- `DRIVE_CATCH_UP_ON_START=true` en drive-manager (revisa Drive al despertar).
- `NGROK_AUTH_TOKEN` **no** va en AWS: sin `DRIVE_WEBHOOK_URL` DriveManager abriría un túnel ngrok público hacia sí mismo.
- `DRIVE_INSTANCE_ID` con sufijo `-aws` mientras conviva con Contabo (canal de Drive y `sync_state` propios).
- `VERIFICATION_BASE_URL`: el dominio público.

## El servidor

- Sin SSH: acceso por **Session Manager** (`aws ssm start-session --target <InstanceId> --profile eras`, requiere el plugin de Session Manager) o la consola.
- `/opt/eras/current` → scripts de `instance/` (se sincronizan en cada arranque desde `/eras/infra/bundle`; a mano: `sudo eras-sync`).
- `eras.service` (al arrancar): `eras-sync` + `eras-up`. `eras-idle.timer`: cada 5 min; apaga si
  `/api/system/activity` de todos los entornos dice más de 1800 s sin uso y ninguna sala con jugadores
  (si ningún entorno responde ese endpoint, **no apaga**: las imágenes sin él quedan siempre encendidas). No apaga durante un `eras-deploy`.
- Logs: CloudWatch `/eras/prod` y `/eras/staging`, un stream por servicio (`proxy` en `/eras/prod`).
- Memoria: prod 1000 MB y staging 700 MB por servicio, 2 GB de swap.

## Backups de MongoDB

- Diario a las 04:30 UTC: workflow `backup-mongo.yml` → `scripts/backup-mongo.sh` → `eras-backup` en el servidor
  (lo enciende si duerme; Atlas solo acepta su IP) → `mongodump` de `eras_db` a
  `s3://<BackupBucket>/mongo/eras_db-<fecha>.archive.gz`. El bucket borra cada dump a los 30 días.
- Manual: Actions → `backup-mongo` → *Run workflow*, o `bash aws/scripts/backup-mongo.sh` con el perfil `eras`.
- `mongo/vps/`: los backups que tenía el VPS de Contabo (27–29 oct 2026).
- Restaurar (a una base nueva, desde un lugar con acceso a Atlas, p. ej. el servidor):
  ```bash
  aws s3 cp s3://<BackupBucket>/mongo/<archivo> - | docker run --rm -i -e URI="<uri>" mongo:7     sh -c 'mongorestore --uri "$URI" --gzip --archive --nsFrom "eras_db.*" --nsTo "<destino>.*"'
  ```

## Contrato con la aplicación

- Front (build `aws`): `apiBaseUrl: ''`, `wakeUrl: '/wake'`. `POST /wake` responde `{"state": "pending|running|..."}`
  (202 mientras arranca, 200 si ya corre). Con el servidor apagado, `/api/*` falla rápido (CloudFront 502/504
  tras ~2 s): es la señal para mostrar "Encendiendo el servidor…" y llamar a `/wake`.
- `GET /api/drive/health` lo usa el front para saber si el backend responde.
- `GET /api/system/activity` → `{idleSeconds, activeRooms, startedAt}`: lo usa `eras-idle` (sin autenticación,
  solo alcanzable a través de CloudFront o desde el propio servidor).
- Healthchecks de `eras-deploy`: drive-manager `GET /api/drive/health` → 200; users-service `GET /api/auth/health` → 200.
- WebSocket del simulador en `/ws` (CloudFront lo soporta; nginx mantiene la conexión hasta 1 h).

## CI/CD (GitHub Actions)

Credenciales: secrets de la organización `eras-tcg` `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` del usuario
`eras-ci` (los crea y rota `scripts/ci-access-key.sh`; rotar cada 90 días). Los repos llaman a los workflows
reutilizables con `secrets: inherit`:

- Backends (`DriveManager`, `ErasUsersService`): `test` → `build` (imagen `ghcr.io/eras-tcg/<servicio>:<sha>`) →
  [`deploy-aws.yml`](../.github/workflows/deploy-aws.yml) con `service`, `environment` (staging|production) e
  `image_tag`: copia la imagen a ECR y corre `scripts/deploy-backend.sh`. develop → staging, main → production
  (aprobación). Rollback: *Run workflow* con el sha de una imagen anterior.
- Front (`eras-web`): `ng build --configuration aws` → artifact → [`deploy-site-aws.yml`](../.github/workflows/deploy-site-aws.yml)
  (`scripts/deploy-site.sh`). Rollback: re-ejecutar el job de deploy de un run anterior.

## Costos esperados (USD/mes)

EC2 t3a.medium ~0,038/h solo encendido (~7 con 6 h/día) · disco 30 GB ~2,4 · IP elástica ~3,6 · ECR < 1 ·
CloudFront, Lambda, S3, SSM ~0 con este tráfico · Route 53 0,50. Total ~13–15. Aviso por correo a USD 20 (gastado o previsto); límite de gasto del proyecto en AWS Settings: USD 35 (al alcanzarlo AWS pausa todo).
