# Observability Business Case

Caso base para talleres técnicos senior sobre arquitectura serverless, resiliencia y observabilidad. Esta iteración mantiene el flujo funcional de procesamiento de órdenes y reemplaza la infraestructura SAM por Terraform para simplificar CI/CD y el control del estado de la infraestructura.

## Arquitectura

- Amazon API Gateway HTTP API expone `POST /orders` y `GET /orders/{orderId}`.
- Lambda `create-order` valida el payload, calcula `totalAmount`, persiste la orden en DynamoDB con estado `PENDING` y publica `OrderCreated` en EventBridge.
- Lambda `order-processor` consume el evento, mueve la orden a `PROCESSING`, invoca sincrónicamente al simulador de pago y actualiza el estado final.
- Lambda `payment-simulator` simula pagos con modos configurables para escenarios de falla.
- DynamoDB almacena el estado y atributos de la orden.

## Estructura

```text
.
├── README.md
├── package.json
├── infra
│   └── terraform
│       ├── main.tf
│       ├── outputs.tf
│       └── variables.tf
├── scripts
│   ├── create-order.sh
│   ├── generate-load.sh
│   ├── get-order.sh
│   └── prepare-lambda-package.sh
└── src
    ├── order-api
    ├── order-processor
    ├── payment-simulator
    └── shared
```

## Requisitos

- Node.js 20.x
- Terraform CLI 1.6 o superior
- AWS CLI configurado con credenciales válidas

## Variables de despliegue

- `STACK_NAME`: prefijo para los recursos AWS. Default: `observability-business-case`
- `RESOURCE_PREFIX`: prefijo general opcional para namespacing de recursos. Default en CI/CD: el nombre del environment
- `AWS_REGION`: región de despliegue. Default: `us-east-1`
- `PAYMENT_FAILURE_MODE`: `none`, `always_fail`, `random_fail`, `slow_response`, `random_reject`
- `TF_STATE_BUCKET`: opcional. Si no se define en GitHub Actions, el workflow crea uno automáticamente
- `TF_STATE_KEY`: opcional. Default en CI/CD: `${environment}/${STACK_NAME}.tfstate`

## Despliegue local

### 1. Configurar credenciales AWS

Puedes usar AWS CLI:

```bash
aws configure
```

O variables de entorno:

```bash
export AWS_ACCESS_KEY_ID="<tu-access-key-id>"
export AWS_SECRET_ACCESS_KEY="<tu-secret-access-key>"
export AWS_REGION="us-east-1"
```

### 2. Configurar variables de despliegue

```bash
export STACK_NAME="observability-business-case"
export RESOURCE_PREFIX="aws-dev"
export AWS_REGION="us-east-1"
export PAYMENT_FAILURE_MODE="none"
```

Si quieres mantener estado remoto también localmente:

```bash
export TF_STATE_BUCKET="<tu-bucket-terraform-state>"
export TF_STATE_KEY="observability-business-case.tfstate"
```

### 3. Instalar dependencias y empaquetar Lambda

```bash
npm install
bash scripts/prepare-lambda-package.sh
```

### 4. Inicializar Terraform

Si usas estado remoto:

```bash
terraform -chdir=infra/terraform init -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY:-${STACK_NAME}.tfstate}" \
  -backend-config="region=${AWS_REGION}"
```

Si trabajas localmente sin backend remoto:

```bash
terraform -chdir=infra/terraform init -backend=false
```

### 5. Aplicar infraestructura

```bash
terraform -chdir=infra/terraform apply \
  -var="aws_region=${AWS_REGION}" \
  -var="stack_name=${STACK_NAME}" \
  -var="resource_prefix=${RESOURCE_PREFIX}" \
  -var="payment_failure_mode=${PAYMENT_FAILURE_MODE}"
```

### 6. Obtener la URL del API

```bash
terraform -chdir=infra/terraform output -raw api_base_url
```

Exporta la URL:

```bash
export API_BASE_URL="$(terraform -chdir=infra/terraform output -raw api_base_url)"
```

Las rutas operativas son `${API_BASE_URL}/orders` y `${API_BASE_URL}/orders/{orderId}`.

## Destruir infraestructura

```bash
terraform -chdir=infra/terraform destroy \
  -var="aws_region=${AWS_REGION}" \
  -var="stack_name=${STACK_NAME}" \
  -var="resource_prefix=${RESOURCE_PREFIX}" \
  -var="payment_failure_mode=${PAYMENT_FAILURE_MODE}"
```

## CI/CD con GitHub Actions

El repositorio incluye dos workflows:

- [ci.yml](/Users/pazfernando/Documents/projects/windsurf/workshop-order-processing/.github/workflows/ci.yml): valida sintaxis JavaScript, empaqueta Lambda y ejecuta `terraform fmt` y `terraform validate`
- [deploy.yml](/Users/pazfernando/Documents/projects/windsurf/workshop-order-processing/.github/workflows/deploy.yml): despliega automáticamente a AWS cuando hay push a `main`, y permite ejecución manual con `workflow_dispatch`

### Secrets y variables requeridos en GitHub

Secrets:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN` si usas credenciales temporales de STS

Variables:

- `AWS_REGION`
- `STACK_NAME`
- `RESOURCE_PREFIX` opcional
- `PAYMENT_FAILURE_MODE`
- `TF_STATE_KEY` opcional

### Backend remoto de Terraform en GitHub Actions

En GitHub Actions el backend remoto no es opcional. El runner es efímero, así que el workflow asegura un bucket S3 para el estado antes de ejecutar `terraform init`.

Si `TF_STATE_BUCKET` no está definido, el workflow crea uno automáticamente en la cuenta destino con este patrón:

- `${resource_prefix}-${stack_name}-${account_id}-${aws_region}-tfstate`

Luego usa una key por environment:

- `${environment}/${STACK_NAME}.tfstate`

En este repositorio, para el environment `aws-dev`, la key por defecto queda:

- `aws-dev/observability-business-case.tfstate`

Y los recursos nombrados quedan con este patrón:

- `${RESOURCE_PREFIX}-${STACK_NAME}-...`

### Flujo de despliegue

1. Crear un branch y abrir Pull Request.
2. GitHub Actions ejecuta `CI`.
3. Al hacer merge a `main`, GitHub Actions ejecuta `Deploy`.
4. El workflow empaqueta la app, ejecuta `terraform init` y luego `terraform apply`.
5. Al final imprime `api_base_url` desde Terraform.

## Permisos IAM mínimos sugeridos para el usuario de despliegue

El usuario o credencial usada en GitHub Actions debe poder operar al menos con:

- S3 para backend de estado de Terraform
- IAM
- Lambda
- API Gateway v2
- DynamoDB
- EventBridge
- CloudWatch Logs

## Probar el flujo

Crear una orden:

```bash
bash scripts/create-order.sh
```

Ejemplo `curl`:

```bash
curl -X POST "${API_BASE_URL}/orders" \
  -H "content-type: application/json" \
  --data '{
    "customerId": "customer-001",
    "items": [
      {
        "sku": "SKU-001",
        "quantity": 2,
        "unitPrice": 25.5
      }
    ],
    "currency": "USD"
  }'
```

Respuesta esperada:

```json
{
  "orderId": "generated-id",
  "status": "PENDING"
}
```

Consultar una orden:

```bash
bash scripts/get-order.sh <orderId>
```

Ejemplo `curl`:

```bash
curl "${API_BASE_URL}/orders/<orderId>"
```

## Comandos útiles

- Instalar dependencias: `npm install`
- Verificación rápida: `npm run check`
- Empaquetar Lambda: `npm run package:lambda`
- Formatear/verificar Terraform: `npm run terraform:fmt`
- Validar Terraform: `npm run terraform:validate`
