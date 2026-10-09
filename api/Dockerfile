FROM node:22-slim AS deps
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev

FROM node:22-slim
WORKDIR /app
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN useradd -u 1001 -m appuser
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /opt/yarn*
USER appuser
EXPOSE 4000
CMD ["node", "src/index.js"]
