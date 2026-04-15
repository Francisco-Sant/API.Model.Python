# Etapa de build: instala dependencias do projeto em uma virtualenv isolada.
FROM python:3.14-slim AS builder

# Configuracoes de Python e pip para logs limpos e imagem mais enxuta.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Diretorio de trabalho da aplicacao para as proximas instrucoes COPY/RUN.
WORKDIR /app

# Cria uma virtualenv dedicada que sera copiada para a imagem final.
RUN python -m venv /opt/venv
# Garante que os binarios instalados na virtualenv tenham prioridade.
ENV PATH="/opt/venv/bin:$PATH"

# Copia metadados primeiro para maximizar reaproveitamento de cache das dependencias.
COPY pyproject.toml README.md ./
# Copia o codigo-fonte usado na instalacao do pacote.
COPY src ./src

# Instala dependencias do pacote e o servidor de producao.
RUN pip install --upgrade pip && \
    pip install . gunicorn


# Etapa de runtime: mantem apenas o necessario para executar a API com seguranca.
FROM python:3.14-slim AS runtime

# Mantem comportamento do Python previsivel em producao.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Cria usuario/grupo sem privilegios para reduzir superficie de ataque.
RUN groupadd --system appgroup && \
    useradd --system --gid appgroup --create-home --home-dir /home/appuser appuser

# Diretorio de trabalho da etapa de runtime.
WORKDIR /app

# Traz a virtualenv preinstalada do builder e copia o codigo da aplicacao.
COPY --from=builder /opt/venv /opt/venv
# Garante ownership dos arquivos da aplicacao para o usuario sem privilegios.
COPY --chown=appuser:appgroup src ./src

# Executa o processo com usuario sem privilegios.
USER appuser

# Documenta a porta de escuta da API.
EXPOSE 8000

# Prova de saude do container usada por Docker/Compose/Kubernetes.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health/ready', timeout=2)"]

# Inicia a API FastAPI em modo de producao com Gunicorn + workers Uvicorn.
CMD ["gunicorn", "-k", "uvicorn.workers.UvicornWorker", "--chdir", "/app/src", "--bind", "0.0.0.0:8000", "--workers", "2", "main:app"]
