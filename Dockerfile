FROM node:20-alpine

WORKDIR /app

# Install dependencies
COPY backend/package.json ./
RUN npm install --production

# Copy source
COPY backend/src ./src

# Create data directory for SQLite
RUN mkdir -p /data

ENV NODE_ENV=production
ENV DB_PATH=/data/chat.db
ENV PORT=3001

EXPOSE 3001

CMD ["node", "src/index.js"]
