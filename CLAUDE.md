# infra: guía para agentes

Infraestructura de ERAS en AWS (us-east-2; CloudFront es global). El detalle está en `aws/README.md`; lo que sigue es lo que un agente necesita saber antes de tocar algo.

## Piezas

- **`aws/` (CDK, TypeScript)**: stacks `ErasZone`, `ErasBackend`, `ErasSiteProd`, `ErasSiteStaging`, `ErasDns`, `ErasCi` y `ErasMonitoring`.
  - **El CDK no corre en CI.** Lo despliega el dueño a mano con `npx cdk deploy <Stack> --profile eras`. Un agente puede cambiar el código y comprobarlo con `npx cdk synth --strict` (el aviso W7001 es conocido), pero no desplegarlo.
- **`aws/lib/site-stack.ts`**: CloudFront del sitio.
  - Rutas: S3 para el sitio, `/api/*` y `/ws` van al servidor, y `/wake` va a la Lambda que enciende el backend dormido.
  - Su función `SpaRewrite` responde con `index.html` a las rutas sin extensión, y desde #16 trata como archivos las extensiones de hasta 12 caracteres.
  - Con `canonicalHost`, redirige con un 301 a `www.erastcg.com`.
- **`aws/scripts/deploy-site.sh`**: lo usa `.github/workflows/deploy-site-aws.yml`, que eras-web llama.
  - Sube los archivos con hash como `immutable` y el resto como `no-cache`.
  - Sube el `manifest.json` y el `ERAS.apk` con su content type.
  - Invalida `index.html`, los archivos del service worker y `/app/*`.
  - Si un build no trae `app/`, conserva lo que ya estaba publicado.
- **`.github/workflows/deploy-aws.yml`**: despliegue reutilizable de los backends (DriveManager y ErasUsersService). Copia la imagen de GHCR a ECR y ejecuta `eras-deploy` por SSM, con healthcheck y rollback.

## Cómo se trabaja

- Rama → PR a **`main`**. Los workflows de los otros repos usan `infra@main`, así que **un cambio de infra que necesita otro repo se mergea primero**.
- Comprobaciones antes de subir:
  - `bash -n aws/scripts/deploy-site.sh`;
  - `cd aws && npx cdk synth --strict <Stack>` si cambió el CDK;
  - para la lógica de la función de CloudFront, probarla en Node con eventos de ejemplo.
- Producción de cada repo espera la aprobación del dueño en el GitHub Environment `production`.

## Pendientes del dueño (CDK sin desplegar)

- `npx cdk deploy ErasSiteProd ErasSiteStaging --profile eras` aplica dos cambios:
  - el 301 de `erastcg.com` a `www` (#15), que mientras tanto hace el propio sitio;
  - la regla de extensiones largas (#16).
- Opcional: una regla CORS en el bucket R2 de imágenes, para `https://www.erastcg.com` y `https://localhost` (la app Android).

## Repos relacionados

- **eras-web**: el sitio, la PWA y la app Android.
- **DriveManager**: el servidor y el motor.
- **ErasUsersService**: login.
