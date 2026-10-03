# Build only the OBJ/ZIP -> GLB companion from the repository's pinned gitlink.
FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY model_optimizer/package.json ./
COPY deploy/optimizer-package-lock.json ./package-lock.json
RUN npm ci
COPY model_optimizer/tsconfig.json ./
COPY model_optimizer/src/ ./src/
RUN npm run build && npm prune --omit=dev

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build --chown=node:node /app/package.json /app/package-lock.json ./
COPY --from=build --chown=node:node /app/node_modules/ ./node_modules/
COPY --from=build --chown=node:node /app/dist/ ./dist/
COPY --chown=node:node model_optimizer/public/ ./public/
RUN mkdir -p temp/uploads temp/results && chown -R node:node temp
USER node
ENV NODE_ENV=production PORT=3000
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/index.js"]
