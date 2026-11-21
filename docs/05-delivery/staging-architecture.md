# Arquitectura de staging desplegada en Dokploy

Estado: topología base de consola/API desplegada desde 2026-11-10; el overlay de Issuer agregado en noviembre de 2026 está preparado en repo pero **todavía no está aplicado ni verificado en el host**. No autoriza producción. [ADR-0029](../decisions/ADR-0029.md) registra decisiones y límites. Fuentes: [`deploy/keycloak/docker-compose.yml`](../../deploy/keycloak/docker-compose.yml), [`deploy/staging/compose.yaml`](../../deploy/staging/compose.yaml), [`deploy/staging/compose.issuer.yaml`](../../deploy/staging/compose.issuer.yaml) y [`deploy/staging/Caddyfile`](../../deploy/staging/Caddyfile).

## Diagrama

Línea continua: tráfico de datos. Línea punteada: consulta de identidad o administración.

```mermaid
flowchart TB
  user["Navegador"]
  admin["Administrador<br/>laptop por Tailscale"]
  subgraph cf["Cloudflare"]
    cfedge["DNS, TLS y túnel homelab"]
  end
  subgraph host["Servidor homelab: Ubuntu + Dokploy"]
    cfd["cloudflared<br/>servicio del host"]
    traefik["Traefik (dokploy-traefik)<br/>:80, enruta por host y path"]
    subgraph kcstack["Compose deploy/keycloak, host hukid-id"]
      kc["Keycloak 26.8.2<br/>:8080, /realms y /resources"]
      kcdb[("Postgres 17<br/>base keycloak")]
    end
    subgraph apistack["Compose deploy/staging, host hukid"]
      web["web: Caddy :8081<br/>consola + proxy Issuer"]
      api["api: Go<br/>127.0.0.1:8080<br/>Issuer: overlay optativo"]
      workers["workers: deferred + retention<br/>perfil issuer-workers, optativo"]
      tools["tools: stagingdb<br/>perfil tools, a demanda"]
    end
    db[("Postgres hukid_staging<br/>servicio de base de Dokploy<br/>6 roles con overlay Issuer")]
    vault["Vault Transit HTTPS<br/>externo, endpoint/policy por confirmar"]
  end

  user -->|"HTTPS"| cfedge
  cfedge -->|"túnel"| cfd
  cfd -->|"HTTP :80"| traefik
  traefik -->|"hukid-id: /realms, /resources"| kc
  traefik -->|"hukid: servicio api, puerto 8081"| web
  kc --> kcdb
  web -->|"/console/*, /healthz, /v1/* y OID4VCI"| api
  api -->|"roles aislados; Issuer usa TLS"| db
  api -.->|"issuer OIDC por el nombre público"| cfedge
  api -->|"Vault Transit"| vault
  workers -->|"DB aislada + Vault"| db
  workers --> vault
  tools -->|"hukid_admin: migrate, runtime-logins, bootstrap"| db
  admin -.->|"túnel SSH a 127.0.0.1:8081, solo administración"| kc
```

## Componentes

| Componente | Rol | Notas |
| --- | --- | --- |
| Cloudflare | DNS, TLS y túnel `homelab` | Las rutas `hukid-id` y `hukid` apuntan a `http://localhost:80`. |
| `cloudflared` | Cliente del túnel | Servicio del host (systemd), no un contenedor. |
| Traefik | Entrada HTTP del servidor | Contenedor `dokploy-traefik`, puerto 80 del host. |
| Keycloak | IdP OIDC, realm `hukid` | 26.8.2 con `start`. `KC_HOSTNAME` es la URL pública; la administración solo escucha en `127.0.0.1:8081` del host. |
| Postgres de Keycloak | Base `keycloak` | Volumen `keycloak-db-data`, red `default` del compose, sin puerto publicado. |
| `web` | Caddy: consola estática y proxy | Escucha en 8081 dentro del espacio de red de `api` (`network_mode: service:api`). Sin puertos publicados. |
| `api` | Backend Go | `127.0.0.1:8080`, `HUKID_ENV=staging`. Healthcheck con el subcomando `hukid-api healthcheck`. |
| `tools` | `stagingdb`: `migrate`, `runtime-logins`, `bootstrap` | Perfil `tools`: solo corre con `docker compose --profile tools run`. Usa el propietario `hukid_admin`. |
| Postgres `hukid_staging` | Base de HukID | Servicio de base de Dokploy `hukid-staging-db-ggfxdz:5432`, sin puerto externo. Cinco logins de ejecución con RLS ([ADR-0029](../decisions/ADR-0029.md), punto 3). |

## Rutas públicas

| Host | Path | Destino | Dónde se configura |
| --- | --- | --- | --- |
| `hukid-id.zentrycore.com` | `/realms`, `/resources` | Keycloak, puerto 8080 | Etiquetas de Traefik en `deploy/keycloak/docker-compose.yml`. |
| `hukid-id.zentrycore.com` | `/admin` y el resto | Sin ruta: 404 de Traefik | No se enruta a propósito. |
| `hukid.zentrycore.com` | Todos | Servicio `api`, puerto 8081, atendido por `web` | Pestaña Domains de Dokploy (no versionado). |

Dentro de `web`, `/console/*`, `/healthz`, `/v1/*`, token/discovery y las rutas OID4VCI del issuer pasan a `api`; el resto sirve el build estático con `index.html` como respaldo. Las rutas están declaradas en `deploy/staging/Caddyfile`.

El overlay [`compose.issuer.yaml`](../../deploy/staging/compose.issuer.yaml) añade al API el runtime de emisión con el login PostgreSQL `issuance` y Vault Transit; añade los workers `deferred` y `retention` bajo el perfil `issuer-workers`. La base `compose.yaml` sigue permitiendo aprovisionar migraciones, logins y bootstrap antes de que existan los secretos de Vault. El overlay exige TLS verificado (`sslmode=verify-full`) y monta la CA PostgreSQL como secreto de solo lectura. `HUKID_STAGING_DB_HOST` debe resolver desde la red de Dokploy y coincidir con el SAN del certificado; el proveedor debe entregar la CA correspondiente.

## Límites de este diagrama

- Se dibujó a partir de los compose y de comprobaciones manuales del 2026-11-10 (discovery de Keycloak con 200, `/healthz` con 204 por Traefik, login de punta a punta). No se contrastó con una exportación de la configuración de Dokploy ni de Cloudflare.
- Viven fuera del repositorio y no están verificadas aquí: el dominio `hukid.zentrycore.com` de Dokploy, las rutas del túnel y la regla de caché de Cloudflare para `/realms/*`.
- Recrear `api` obliga a reiniciar `web`, por `network_mode: service:api` ([operación](staging-operations.md)).
- El realm `master` también responde por `/realms`; su restricción es una propuesta no aplicada ([keycloak-master-realm.md](keycloak-master-realm.md)).
- El overlay Issuer no se ha aplicado al Dokploy ni se ha ejecutado su verificación de punta a punta ([staging-verification.md](staging-verification.md)). El endpoint real de Vault, su policy/token, el tenant piloto y el alta inicial de la DEK siguen dependiendo de acceso y configuración del operador.

Contexto: [ADR-0028](../decisions/ADR-0028.md) define el entorno `staging` del backend.

Volver al [índice del proyecto](../../README.md).
