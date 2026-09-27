#!/usr/bin/env bash
# Build and deploy machine-failure-api. Safe to run repeatedly: every step checks before it creates.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-awsnew}"
REGION="us-east-2"
NAME="machine-failure-api"
ROLE_NAME="${NAME}-lambda-role"
LOG_GROUP="/aws/lambda/${NAME}"
LOG_RETENTION_DAYS=14
TAGS_KV="Project=${NAME},Owner=abhishek"

cd "$(dirname "$0")"

log() { printf '\n==> %s\n' "$*"; }

if ! aws --version >/dev/null 2>&1; then
  echo "The aws CLI at $(command -v aws || echo '<not found>') does not run. Put a working AWS CLI v2 first on PATH." >&2
  exit 1
fi
if ! ACCOUNT_ID="$(aws sts get-caller-identity --region "$REGION" --query Account --output text)"; then
  echo "AWS credentials are missing or expired for profile ${AWS_PROFILE}. Run: aws login" >&2
  exit 1
fi
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
REPO_URI="${REGISTRY}/${NAME}"

# ---------------------------------------------------------------- ECR repository
log "ECR repository ${NAME}"
if aws ecr describe-repositories --region "$REGION" --repository-names "$NAME" >/dev/null 2>&1; then
  echo "exists"
else
  aws ecr create-repository --region "$REGION" --repository-name "$NAME" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --tags Key=Project,Value="$NAME" Key=Owner,Value=abhishek >/dev/null
  echo "created"
fi
# Keep the five newest images so storage cost stays flat. put-lifecycle-policy overwrites, so it is idempotent.
aws ecr put-lifecycle-policy --region "$REGION" --repository-name "$NAME" --lifecycle-policy-text '{
  "rules": [{"rulePriority": 1, "description": "keep last 5 images",
             "selection": {"tagStatus": "any", "countType": "imageCountMoreThan", "countNumber": 5},
             "action": {"type": "expire"}}]}' >/dev/null

# ---------------------------------------------------------------- image build and push
# The tag is a hash of every build input, so an unchanged tree maps to an existing tag and skips the push.
BUILD_INPUTS=(Dockerfile requirements.txt features.py app.py model/model.onnx model/metadata.json)
IMAGE_TAG="$(cat "${BUILD_INPUTS[@]}" | shasum -a 256 | cut -c1-12)"

log "Image ${NAME}:${IMAGE_TAG}"
if aws ecr describe-images --region "$REGION" --repository-name "$NAME" --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
  echo "already in ECR, skipping build and push"
else
  docker build --platform linux/arm64 --provenance=false -t "${NAME}:${IMAGE_TAG}" .
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
  docker tag "${NAME}:${IMAGE_TAG}" "${REPO_URI}:${IMAGE_TAG}"
  docker push "${REPO_URI}:${IMAGE_TAG}"
fi
IMAGE_DIGEST="$(aws ecr describe-images --region "$REGION" --repository-name "$NAME" \
  --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)"
IMAGE_URI="${REPO_URI}@${IMAGE_DIGEST}"
echo "image uri: ${REPO_URI}@${IMAGE_DIGEST}" | sed "s/${ACCOUNT_ID}/<account-id>/"

# ---------------------------------------------------------------- IAM execution role
log "IAM role ${ROLE_NAME}"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "exists"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]}' \
    --tags Key=Project,Value="$NAME" Key=Owner,Value=abhishek >/dev/null
  echo "created"
fi
# Attaching an already attached policy is a no-op.
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"

# ---------------------------------------------------------------- CloudWatch log group
# Created up front so it carries tags and a retention period. Lambda would otherwise create it with no expiry.
log "Log group ${LOG_GROUP}"
if [[ "$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$LOG_GROUP" \
      --query "length(logGroups[?logGroupName=='${LOG_GROUP}'])" --output text)" == "1" ]]; then
  echo "exists"
else
  aws logs create-log-group --region "$REGION" --log-group-name "$LOG_GROUP" --tags "$TAGS_KV"
  echo "created"
fi
aws logs put-retention-policy --region "$REGION" --log-group-name "$LOG_GROUP" --retention-in-days "$LOG_RETENTION_DAYS"

# ---------------------------------------------------------------- Lambda function
log "Lambda function ${NAME}"
if aws lambda get-function --region "$REGION" --function-name "$NAME" >/dev/null 2>&1; then
  CURRENT_URI="$(aws lambda get-function --region "$REGION" --function-name "$NAME" --query Code.ImageUri --output text)"
  if [[ "$CURRENT_URI" == "$IMAGE_URI" ]]; then
    echo "already running this image"
  else
    aws lambda update-function-code --region "$REGION" --function-name "$NAME" --image-uri "$IMAGE_URI" >/dev/null
    aws lambda wait function-updated-v2 --region "$REGION" --function-name "$NAME"
    echo "updated image"
  fi
  # Any configuration update recycles the warm environments, so only update when a value differs.
  CURRENT_CONFIG="$(aws lambda get-function-configuration --region "$REGION" --function-name "$NAME" \
    --query '[MemorySize, Timeout]' --output text)"
  if [[ "$CURRENT_CONFIG" == $'512\t10' ]]; then
    echo "configuration already 512 MB, 10 s"
  else
    aws lambda update-function-configuration --region "$REGION" --function-name "$NAME" \
      --memory-size 512 --timeout 10 >/dev/null
    aws lambda wait function-updated-v2 --region "$REGION" --function-name "$NAME"
    echo "updated configuration"
  fi
else
  # A new IAM role takes a few seconds to become assumable by Lambda, so retry on that specific error.
  for attempt in 1 2 3 4 5 6; do
    if output="$(aws lambda create-function --region "$REGION" --function-name "$NAME" \
        --package-type Image --code ImageUri="$IMAGE_URI" --role "$ROLE_ARN" \
        --architectures arm64 --memory-size 512 --timeout 10 \
        --tags "$TAGS_KV" 2>&1)"; then
      echo "created"
      break
    fi
    if [[ "$output" == *"cannot be assumed by Lambda"* && "$attempt" -lt 6 ]]; then
      echo "role not ready yet, retrying in 10s"
      sleep 10
    else
      echo "$output" >&2
      exit 1
    fi
  done
  aws lambda wait function-active-v2 --region "$REGION" --function-name "$NAME"
fi

FUNCTION_ARN="$(aws lambda get-function --region "$REGION" --function-name "$NAME" --query Configuration.FunctionArn --output text)"

# ---------------------------------------------------------------- API Gateway HTTP API
log "HTTP API ${NAME}"
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='${NAME}'].ApiId | [0]" --output text)"
if [[ "$API_ID" != "None" && -n "$API_ID" ]]; then
  echo "exists"
else
  API_ID="$(aws apigatewayv2 create-api --region "$REGION" --name "$NAME" --protocol-type HTTP \
    --tags "$TAGS_KV" --query ApiId --output text)"
  echo "created"
fi

log "Lambda proxy integration"
INTEGRATION_ID="$(aws apigatewayv2 get-integrations --region "$REGION" --api-id "$API_ID" \
  --query "Items[?IntegrationUri=='${FUNCTION_ARN}'].IntegrationId | [0]" --output text)"
if [[ "$INTEGRATION_ID" != "None" && -n "$INTEGRATION_ID" ]]; then
  echo "exists"
else
  INTEGRATION_ID="$(aws apigatewayv2 create-integration --region "$REGION" --api-id "$API_ID" \
    --integration-type AWS_PROXY --integration-uri "$FUNCTION_ARN" \
    --payload-format-version 2.0 --timeout-in-millis 10000 --query IntegrationId --output text)"
  echo "created"
fi

log "Route POST /predict"
ROUTE_ID="$(aws apigatewayv2 get-routes --region "$REGION" --api-id "$API_ID" \
  --query "Items[?RouteKey=='POST /predict'].RouteId | [0]" --output text)"
if [[ "$ROUTE_ID" != "None" && -n "$ROUTE_ID" ]]; then
  echo "exists"
else
  aws apigatewayv2 create-route --region "$REGION" --api-id "$API_ID" \
    --route-key "POST /predict" --target "integrations/${INTEGRATION_ID}" >/dev/null
  echo "created"
fi

# The public endpoint has no auth, so a stage throttle caps how fast anyone can spend money through it.
log "Stage \$default (auto deploy, throttled)"
if aws apigatewayv2 get-stage --region "$REGION" --api-id "$API_ID" --stage-name '$default' >/dev/null 2>&1; then
  aws apigatewayv2 update-stage --region "$REGION" --api-id "$API_ID" --stage-name '$default' \
    --default-route-settings ThrottlingBurstLimit=20,ThrottlingRateLimit=10 >/dev/null
  echo "exists, throttle settings applied"
else
  aws apigatewayv2 create-stage --region "$REGION" --api-id "$API_ID" --stage-name '$default' --auto-deploy \
    --default-route-settings ThrottlingBurstLimit=20,ThrottlingRateLimit=10 --tags "$TAGS_KV" >/dev/null
  echo "created"
fi

# Resource based policy on the function: only this API, this method, and this path may invoke it.
log "Invoke permission for API Gateway"
STATEMENT_ID="apigw-${API_ID}-post-predict"
SOURCE_ARN="arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/POST/predict"
if aws lambda get-policy --region "$REGION" --function-name "$NAME" --query Policy --output text 2>/dev/null \
    | grep -q "\"Sid\":\"${STATEMENT_ID}\""; then
  echo "exists"
else
  aws lambda add-permission --region "$REGION" --function-name "$NAME" \
    --statement-id "$STATEMENT_ID" --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com --source-arn "$SOURCE_ARN" >/dev/null
  echo "created"
fi

API_ENDPOINT="$(aws apigatewayv2 get-api --region "$REGION" --api-id "$API_ID" --query ApiEndpoint --output text)"

log "Done"
aws lambda get-function-configuration --region "$REGION" --function-name "$NAME" \
  --query '{State:State,LastUpdateStatus:LastUpdateStatus,Architectures:Architectures,MemorySize:MemorySize,Timeout:Timeout,PackageType:PackageType}' \
  --output table
echo "Predict URL: ${API_ENDPOINT}/predict"
