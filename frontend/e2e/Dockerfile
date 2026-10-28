# Browsers come with the image; playwright-core must match its version (1.64.1).
FROM mcr.microsoft.com/playwright:v1.64.1-jammy
WORKDIR /e2e
RUN npm init -y >/dev/null && npm install --no-audit --no-fund playwright-core@1.64.1
COPY i18n.spec.cjs .
CMD ["node", "i18n.spec.cjs"]
