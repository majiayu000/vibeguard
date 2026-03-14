# Stage 1: Build the MCP server TypeScript sources
FROM node:22-alpine AS builder

WORKDIR /app

COPY mcp-server/package.json mcp-server/package-lock.json ./mcp-server/
RUN cd mcp-server && npm ci

COPY mcp-server/ ./mcp-server/
RUN cd mcp-server && npm run build

# Stage 2: Lightweight runtime image
FROM node:22-alpine

WORKDIR /app

# Copy compiled MCP server and production dependencies
COPY --from=builder /app/mcp-server/dist/ ./mcp-server/dist/
COPY --from=builder /app/mcp-server/node_modules/ ./mcp-server/node_modules/
COPY mcp-server/package.json ./mcp-server/package.json

# Copy guard scripts, hooks, and utility scripts
COPY guards/ ./guards/
COPY hooks/ ./hooks/
COPY scripts/ ./scripts/

ENV NODE_ENV=production

# Default: run the MCP server; override CMD to run a different command
ENTRYPOINT ["node", "mcp-server/dist/index.js"]
