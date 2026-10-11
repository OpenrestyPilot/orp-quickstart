FROM python:3.12-alpine

WORKDIR /app
COPY generator.py /app/generator.py

USER nobody
ENTRYPOINT ["python", "/app/generator.py"]
