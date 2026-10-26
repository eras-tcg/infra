# eras-tcg/infra

Despliegue de ERAS (erastcg.com) con GitHub Actions. Reemplaza a Jenkins.

## Flujo

```
PR a develop/main ──► build (runner de GitHub)              sin deploy
push a develop    ──► build + push ghcr.io/eras-tcg/<svc>:<sha> ──► deploy staging (automático)
push a main       ──► build + push ──► deploy production (espera aprobación en GitHub)
Run workflow      ──► redeploy de una imagen existente (rollback) a staging o production
```

- Build: en `ubuntu-latest`, imagen a GHCR etiquetada con el sha del commit.
- Deploy: workflow reutilizable [`deploy.yml`](.github/workflows/deploy.yml) en el runner self-hosted
  `eras-vps` (VPS 161.97.173.61), que ejecuta [`deploy/deploy.sh`](deploy/deploy.sh):
  pull → reemplaza el contenedor → healthcheck contra la base de datos → si falla, vuelve a la imagen anterior.
- Aprobación de producción: GitHub Environment `production` con revisor requerido (CapitanPio), solo rama `main`.

## Servicios

| Servicio | Contenedor staging / prod | Puerto staging / prod | Config en el VPS | Healthcheck |
|---|---|---|---|---|
| drive-manager | `drive-manager-staging` / `-prod` | 8091 / 8081 | `/etc/drive-manager[-staging]/.env` | `GET /api/cards/search/edition` → 200 |
| users-service | `users-service-staging` / `-prod` | 8090 / 8082 | `/etc/users-service[-staging]/.env` | login de usuario inexistente → 401 |
| eras-frontend | `eras-frontend-staging` / `-prod` | 3001 / 3000 | (imagen por entorno) + vhost nginx del repo | `GET /` → 200 |

Todos en la red docker `eras-network`; nginx del host enruta los dominios a esos puertos.

## Instalación del runner (una vez, como root en el VPS)

```bash
git clone https://github.com/eras-tcg/infra.git /opt/eras-infra
bash /opt/eras-infra/server/setup-runner.sh <registration-token>
```

Token (válido 1 h): `gh api -X POST orgs/eras-tcg/actions/runners/registration-token --jq .token`

El usuario `github-runner` está en el grupo `docker`, puede leer los `.env` de servicio y solo puede ejecutar
`/usr/local/sbin/eras-nginx-apply` con sudo.

## Seguridad del runner

Los repos son públicos y el runner corre en el VPS de producción:

- Los workflows usan `eras-vps` **solo** en `push` a `develop`/`main` y `workflow_dispatch`, nunca en `pull_request`.
- La organización exige aprobación para workflows de PRs de colaboradores externos.
- Las ramas `develop`/`main` solo aceptan cambios por PR (ruleset).

## Rollback

Actions → *CI/CD* del servicio → **Run workflow** → elegir `environment` y `image_tag` (sha corto o completo
de un build anterior).

## Pendiente

- Mover los `.env` del VPS a secrets de los Environments de GitHub.
- `/api/auth/health` de users-service responde 403 (el permitAll apunta a `/api/health`).
