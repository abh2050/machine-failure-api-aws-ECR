# Lambda Python 3.12 base image, pinned by manifest list digest (multi-arch; built here for arm64).
FROM public.ecr.aws/lambda/python:3.12@sha256:19c3bd742143e6670514284fdfd424eae96a1a728c9ea4abc291d4e7600f7bfe

# Runtime dependencies only: numpy, onnxruntime, pydantic, aws-lambda-powertools.
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt --target ${LAMBDA_TASK_ROOT}

COPY features.py app.py ${LAMBDA_TASK_ROOT}/
COPY model/model.onnx model/metadata.json ${LAMBDA_TASK_ROOT}/model/

CMD ["app.lambda_handler"]
