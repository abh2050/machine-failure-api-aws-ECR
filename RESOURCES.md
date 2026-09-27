# AWS resources

**Status: every resource below was deleted on 2026-09-27.** A follow up inventory found no resource tagged `Project=machine-failure-api`, and no API, function, log group, role, or repository with the project name. The four custom CloudWatch metrics remain, because AWS does not allow deleting metrics. They cost nothing once no new data arrives and expire after 15 months. Run `./deploy.sh` to recreate the stack.

Every resource below lives in us-east-2 (IAM is global) and carries the tags `Project=machine-failure-api` and `Owner=abhishek`. The account ID is left out on purpose. Get it with `aws sts get-caller-identity --query Account --output text`.

All commands assume `export AWS_PROFILE=awsnew`.

| Gate | Resource | ARN pattern | Delete command |
|---|---|---|---|
| 4 | ECR repository `machine-failure-api` (immutable tags, scan on push, keeps 5 newest images) | `arn:aws:ecr:us-east-2:<account-id>:repository/machine-failure-api` | `aws ecr delete-repository --region us-east-2 --repository-name machine-failure-api --force` |
| 4 | IAM role `machine-failure-api-lambda-role` with managed policy `AWSLambdaBasicExecutionRole` | `arn:aws:iam::<account-id>:role/machine-failure-api-lambda-role` | `aws iam detach-role-policy --role-name machine-failure-api-lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole && aws iam delete-role --role-name machine-failure-api-lambda-role` |
| 4 | CloudWatch log group `/aws/lambda/machine-failure-api` (14 day retention) | `arn:aws:logs:us-east-2:<account-id>:log-group:/aws/lambda/machine-failure-api` | `aws logs delete-log-group --region us-east-2 --log-group-name /aws/lambda/machine-failure-api` |
| 4 | Lambda function `machine-failure-api` (container image, arm64, 512 MB, 10 s timeout) | `arn:aws:lambda:us-east-2:<account-id>:function:machine-failure-api` | `aws lambda delete-function --region us-east-2 --function-name machine-failure-api` |
| 5 | API Gateway HTTP API `machine-failure-api`, which includes its Lambda proxy integration, the `POST /predict` route, and the `$default` stage (auto deploy, 10 requests per second, burst 20) | `arn:aws:apigateway:us-east-2::/apis/<api-id>` | `aws apigatewayv2 delete-api --region us-east-2 --api-id <api-id>` |
| 5 | Lambda resource policy statement `apigw-<api-id>-post-predict`, which lets the API invoke the function on `POST /predict` only | source ARN `arn:aws:execute-api:us-east-2:<account-id>:<api-id>/*/POST/predict` | `aws lambda remove-permission --region us-east-2 --function-name machine-failure-api --statement-id apigw-<api-id>-post-predict` |
| 7 | ECR image tag `drill-feature-order-20260927093651` in repository `machine-failure-api`, the deliberately broken image from the feature order drill. The function does not use it, and the lifecycle rule expires it once five newer images exist. | `<account-id>.dkr.ecr.us-east-2.amazonaws.com/machine-failure-api:drill-feature-order-20260927093651` | `aws ecr batch-delete-image --region us-east-2 --repository-name machine-failure-api --image-ids imageTag=drill-feature-order-20260927093651` |

Find the API ID with `aws apigatewayv2 get-apis --region us-east-2 --query "Items[?Name=='machine-failure-api'].ApiId" --output text`.

## Teardown order

Delete the HTTP API first, which removes its integration, route, and stage. Deleting the function also removes its resource policy, so the permission needs its own command only when the function stays. Then delete the function, the log group, the role, and the repository. The `--force` flag on the repository deletes the images inside it.
