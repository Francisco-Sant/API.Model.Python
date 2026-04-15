name: docker-best-practices
description: "Boas práticas para criação de imagens Docker seguras, otimizadas e prontas para produção. Use esta skill sempre que o usuário pedir para criar, analisar, corrigir, revisar ou otimizar um Dockerfile — mesmo que não mencione 'boas práticas' explicitamente. Também use quando o usuário mencionar tamanho de imagem, segurança de container, multi-stage build, imagem pesada, CVEs em imagens, build lento, ou custo containerizar/dockerizar uma aplicação. Se o projeto tem um Dockerfile e o usuário pede qualquer revisão ou melhoria, esta skill se aplica."
---

# Docker Best Practices — Imagens de Container

Guia para criar imagens Docker que sejam pequenas, seguras e rápidas de buildar. O objetivo é sair de Dockerfiles "funciona mas tem problema" para Dockerfiles prontos para produção.

---

## 1. Primeiro passo: entender o projeto antes de tocar no Dockerfile

Antes de alterar qualquer coisa, analise o projeto. Um Dockerfile bom é um reflexo da aplicação — e cada stack tem suas particularidades. Ao revisar o projeto, siga estes passos práticos:

1. **Identifique a linguagem e o framework** — procure por `package.json`, `requirements.txt`, `go.mod`, `pom.xml`, `Cargo.toml` ou qualquer manifesto de dependências que indique a stack e versões alvo.
2. **Identifique o tipo de aplicação** — API REST, web com server-side rendering, worker/cron job, CLI, microserviço, etc. Isso influencia como a imagem é construída e executada.
3. **Analise as dependências** — entenda quais pacotes e bibliotecas são usados (ORM, clientes de banco, bindings nativos). Verifique se há dependências que exigem bibliotecas de sistema (ex.: `libpq`, `libxml2`) e se precisam existir na imagem final.
4. **Identifique portas e protocolos** — descubra em qual porta a aplicação escuta e que protocolos usa (HTTP, gRPC, WebSocket), para definir `EXPOSE`, `HEALTHCHECK` e regras de readiness/liveness.
5. **Procure por arquivos de orquestração** — verifique `docker-compose.yml`, `docker-compose.*.yml` ou manifests de orquestradores para entender serviços adjacentes (bancos, caches, filas) e variáveis de ambiente necessárias.

Quando não houver um Dockerfile de referência no projeto, use exemplos do próprio repositório, instruções do desenvolvedor ou arquivos de orquestração como fonte de verdade. Documente suposições e recomendações quando não houver exemplos explícitos no projeto.

---

## 2. Decisões por stack

Estas são abordagens de partida — a análise do projeto pode revelar necessidades específicas que alterem a estratégia.

| Situação detectada | Abordagem recomendada |
|---|---|
| Node.js com Express | Multi-stage; `npm ci --omit=dev`; base `alpine`; comando final `node server.js` |
| Node.js com build step (TypeScript, Next.js) | Multi-stage: build no primeiro estágio, copiar apenas `dist` ou `.next/` para a imagem final |
| Python (FastAPI/Flask) | Multi-stage; `pip install --no-cache-dir`; usar `slim` ou `alpine`; executar com `gunicorn` em produção |
| Go (qualquer framework) | Multi-stage; construir binário estático com `CGO_ENABLED=0`; imagem final `scratch` ou `alpine` |
| Java (Spring Boot) | Multi-stage com Maven/Gradle no builder; copiar apenas o JAR; usar JRE `slim` ou `distroless` como base final |
| Rust | Multi-stage; `cargo build --release` no builder; copiar binário para `alpine` ou `scratch` |

Use estas recomendações como ponto de partida e ajuste conforme requisitos (native bindings, bibliotecas de sistema, licenças, requisitos de segurança e desempenho).

---

## 3. Imagem base: pinar versão e usar variantes mínimas

Usar `FROM node` sem tag resolve para `latest` — e isso significa que cada build pode pegar uma versão diferente da runtime. Se a aplicação foi desenvolvida com Node 24 e o Node 25 trouxer breaking changes, o build pode quebrar sem nenhuma mudança no código. Além disso, a imagem padrão (sem variante) costuma incluir Debian completo, resultando em imagens de ~1 GB com pacotes desnecessários e potenciais CVEs.

O que fazer:

1. **Pinar a versão da runtime** que o projeto usa (ex.: `node:24`, `python:3.12`).
2. **Prefira variantes mínimas** — ordem prática de preferência:
	- `alpine` — menor tamanho e superfície de ataque (atenção a musl vs glibc)
	- `slim` — intermediária, baseada em Debian mínimo
	- `distroless` — sem shell nem package manager, máxima segurança
	- Hardened Images (imagens oficiais com foco em segurança) — imagens com CVEs mitigados e atualizações constantes
3. **Evitar imagens grandes sem necessidade** — escolha variantes enxutas a menos que bibliotecas de sistema sejam obrigatórias.

```dockerfile
# Problema: sem versão e imagem completa do Debian (~1 GB)
FROM node

# Correto: versão pinada + variante mínima (~150 MB)
FROM node:24-alpine3.23
```

---

## 4. Otimização de cache de camadas

O Docker trata cada instrução do Dockerfile como camada cacheável. Quando uma camada muda, todas as camadas posteriores são invalidadas — por isso pequenas reordenações no Dockerfile podem transformar builds de minutos em segundos.

O que fazer: copie apenas os manifestos de dependência antes de instalar, instale dependências, e só então copie o resto do código. Assim mudanças no código não invalidam o cache das dependências.

Problema (qualquer alteração no código reinstala dependências):
```dockerfile
COPY . .
RUN npm install
```

Correto (aproveita cache das dependências):
```dockerfile
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY . .
```

"O que fazer" por linguagem (ponto de partida):

| Linguagem | Copiar primeiro | Instalar | Depois copiar |
|---|---:|---|---|
| Node.js | `package.json`, `package-lock.json` | `npm ci --omit=dev` | `COPY .` |
| Python | `requirements.txt` | `pip install --no-cache-dir -r requirements.txt` | `COPY .` |
| Go | `go.mod`, `go.sum` | `go mod download` | `COPY .` |
| Java (Maven/Gradle) | `pom.xml` / `build.gradle` | baixar dependências (`mvn dependency:go-offline` / `gradle --no-daemon assemble`) | `COPY .` |
| Rust | `Cargo.toml`, `Cargo.lock` | `cargo build --release` (no builder) | `COPY .` |

Boas práticas e dicas adicionais:

- Em monorepos, limite o contexto de build ao pacote/serviço alterado para preservar cache.
- Use BuildKit com `--mount=type=cache` para caches persistentes (ex.: `~/.m2/repository`, `~/.cache/pip`).
- Não copie diretórios gerados localmente (`node_modules`, `target`, `dist`) antes das etapas de instalação.
- Para instalações que precisam de compilação nativa, use multi-stage: instale as ferramentas necessárias apenas no stage builder.

Exemplo de Dockerfile otimizado (Node.js com build):
```dockerfile
FROM node:24-alpine3.23 AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY . .
RUN npm run build
```

Essas mudanças reduzem tempo de build e tornam resultados mais reprodutíveis.

---

## 5. `npm ci` vs `npm install` (nota prática)

- Use `npm ci` em builds/CI: é mais rápido e determinístico (respeita `package-lock.json`) e falha se o lockfile estiver desatualizado. Para produção, `npm ci --omit=dev` (NPM >=9 use `--omit=dev`, ou `--only=production` em versões antigas).
- `npm install` é adequado para desenvolvimento, mas pode alterar `package-lock.json` e instalar versões diferentes — ruim para builds reprodutíveis.

Pré-requisito: commit do `package-lock.json`. Se não existir, gere-o em ambiente de dev e faça commit; sem lockfile o build será não-determinístico.

---

## 6. Multi-stage build

Use multi-stage builds para separar deps/compilação do runtime. O builder contém compiladores, headers e caches; a imagem final contém apenas o artefato e o runtime mínimo.

Exemplo (Node com build):
```
# Stage 1: build
FROM node:24-alpine3.23 AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY . .
RUN npm run build

# Stage 2: runtime
FROM node:24-alpine3.23
WORKDIR /app
COPY --from=builder /app/dist ./
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
EXPOSE 8080
CMD ["node","server.js"]
```

Exemplo (Java + Maven):
```
FROM maven:3.9.0-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml ./
COPY src ./src
RUN mvn -B -DskipTests package

FROM eclipse-temurin:17-jre-jammy
WORKDIR /app
COPY --from=build /app/target/app.jar ./app.jar
USER 1000
EXPOSE 8080
ENTRYPOINT ["java","-jar","/app/app.jar"]
```

---

## 7. Usuário não-root e permissões

Por padrão containers rodam como `root`. Crie um usuário sem privilégios e atribua ownership correto para evitar permissões e reduzir superfície de ataque.

Exemplo:
```
RUN addgroup --system appgroup && \
		adduser --system --ingroup appgroup appuser
COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules
USER appuser
```

Use `COPY --chown=` para evitar uma camada extra só de `chown`.

---

## 8. `.dockerignore`

Sem `.dockerignore`, o contexto de build inclui tudo (node_modules local, .git, credenciais), tornando o build lento e podendo vazar informações.

Conteúdo recomendado (adaptar à stack):

```
node_modules
.git
.gitignore
.env
.env.*
.vscode
.idea
Dockerfile
.dockerignore
docker-compose*.yml
target/
build/
dist/
tests/
coverage/
```

Coloque o `.dockerignore` na raiz do contexto de build (pode ser diferente da raiz do projeto quando `docker build -f` é usado).

---

## 9. EXPOSE e HEALTHCHECK

EXPOSE declara portas para documentação; orquestradores detectam portas automaticamente mas é boa prática declarar.

HEALTHCHECK permite que orquestradores saibam se a aplicação está saudável:
```
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
	CMD wget --no-verbose --tries=1 --spider http://localhost:8080/ || exit 1
```

Use `curl`/`wget` conforme disponibilidade na imagem final (distroless não tem shell — teste healthchecks no builder ou use sidecar).

---

## 10. Segurança adicional

- **Secrets fora da imagem** — não copie `.env` ou credenciais para a imagem. Injete secrets via runtime/orquestrador.
- **Filesystem read-only** — quando possível, rode o container com `--read-only` e monte volumes para diretórios que precisam de escrita.
- **Dependencies native no builder** — instale pacotes nativos (ex.: `build-base`, `python3-dev`) apenas no stage builder.
- **Scan de CVEs** — automatize `trivy`/`clair` no pipeline e falhe o build para CVEs críticos.

---

## 11. Checklist de validação

- [ ] Imagem base com versão pinada e variante mínima
- [ ] Multi-stage quando há fase de build
- [ ] Usuário não-root definido antes do `CMD`
- [ ] `.dockerignore` presente e bem configurado
- [ ] Healthcheck declarado quando aplicável
- [ ] Dependências instaladas em etapa cacheável
- [ ] Scans de CVE no pipeline
- [ ] Artefatos necessários copiados para o estágio final
- [ ] Ownership e permissões ajustadas (`COPY --chown=` ou `chown` controlado)

---

## 12. Verificação funcional com Docker Compose

Procedimento rápido:

1. `docker compose build`
2. `docker compose up -d`
3. Aguardar serviços prontos (ver retry/timeout)
4. Testar endpoints principais (HTTP, health, integrações com DB)
5. `docker compose logs --tail=200` para depurar falhas

---

## 13. Critérios de sucesso

- Build completo sem erros
- Serviço responde na porta esperada (HTTP 200 no health)
- Container roda como usuário não-root
- Imagem final significativamente menor que versão não-otimizada

---

## 14. Formato de resposta ao revisar um Dockerfile

Ao analisar um Dockerfile entregue, devolva:

1. Lista de problemas encontrados, classificados por severidade (`Crítico`, `Importante`, `Recomendado`).
2. Dockerfile corrigido (sugestão) com as mudanças que importam.
3. Checklist preenchida com itens OK/NÃO OK.
4. Sugestões de pipeline (hadolint, trivy, buildkit cache).

---

Créditos: adaptado de práticas comuns de engenharia para produção. Use este SKILL como referência e peça para eu gerar exemplos ou templates específicos por stack (ex.: `node`, `java`, `python`) quando quiser.

