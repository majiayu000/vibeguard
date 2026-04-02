---
description: "Security rules for API routes and controllers"
globs: ["**/api/**", "**/routes/**", "**/controllers/**", "**/handlers/**"]
---

# API Security Rules

- All user input must be validated and sanitized, no external data is trusted
- SQL queries must use parameterized queries, and string splicing is prohibited
- Sensitive data (passwords, tokens) are prohibited from appearing in logs and responses
- API responses are prohibited from leaking internal error stacks, and production environments return common error messages.
- Authentication/authorization checks must be enforced at the routing level, independent of the frontend
- Rate limiting must be implemented at the gateway or middleware layer
