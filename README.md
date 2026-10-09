# App Migration: AWS EC2 to GKE

ClearPay is a small sample payment application packaged as a containerized stack for local development and cloud-migration exercises. It includes a React/Vite frontend, an Express API, and a PostgreSQL database.

## Project structure

- `ui/` - React frontend served by Vite.
- `api/` - Express API, authentication, accounts, and transactions.
- `db/schema.sql` - PostgreSQL schema, initialized when the database container is first created.
- `docker-compose.yml` - Local PostgreSQL, API, and frontend services.

The API reports deployment metadata through `/api/info` and health status through `/health` and `/health/ready`. The Compose configuration sets sample values for `PLATFORM`, `APP_VERSION`, `GIT_COMMIT`, and `ROLLBACK_ACTIVE`.

## Run locally

Prerequisites: Docker Desktop with Docker Compose.

From the repository root:

```sh
docker compose up --build -d
docker compose exec api npm run seed
```

Open the frontend at <http://localhost:5173>. The API is available at <http://localhost:4000>.

The seed command creates these local demo accounts:

| Email | Password |
| --- | --- |
| `alice@clearpay.dev` | `password123` |
| `bob@clearpay.dev` | `password123` |

Check service status with `docker compose ps`, and stop the stack with `docker compose down`.

## API endpoints

- `GET /health` - Liveness status and serving-instance metadata.
- `GET /health/ready` - Readiness status, including database connectivity.
- `GET /api/info` - Platform and rollback metadata.
- `/api/auth`, `/api/accounts`, `/api/transactions` - Authentication and payment application routes.

## Development configuration

The credentials and JWT secret in `docker-compose.yml`, along with the seeded accounts, are for local development only. Replace them with securely managed values before deploying to any shared or production environment.

The repository currently provides the application and local Compose stack; Kubernetes deployment manifests are not included.
