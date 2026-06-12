### Stage 1: Build the React frontend
FROM node:20-alpine AS frontend-builder

WORKDIR /frontend

COPY frontend/package.json ./
RUN npm install

COPY frontend/ ./
# VITE_API_URL is empty so the frontend hits the same origin (served by Express)
RUN VITE_API_URL="" npm run build

### Stage 2: Production backend + serve frontend
FROM node:20-alpine

WORKDIR /app

# Install backend dependencies
COPY backend/package.json ./
RUN npm install --omit=dev

# Copy backend source
COPY backend/src ./src

# Copy built frontend into a public directory Express will serve
COPY --from=frontend-builder /frontend/dist ./public

# Create data directory for SQLite (overridden by EFS volume in ECS)
RUN mkdir -p /data

ENV NODE_ENV=production
ENV DB_PATH=/data/chat.db
ENV PORT=3001

EXPOSE 3001

CMD ["node", "src/index.js"]
