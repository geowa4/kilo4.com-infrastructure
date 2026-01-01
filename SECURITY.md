# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly.

**Do not open a public issue for security vulnerabilities.**

Instead, please send an email to the repository maintainer with:

1. A description of the vulnerability
2. Steps to reproduce the issue
3. Potential impact of the vulnerability
4. Any suggested fixes (optional)

## Response Timeline

- **Initial response**: Within 7 days
- **Status update**: Within 30 days
- **Resolution target**: Within 90 days for critical issues

## Scope

This security policy applies to:

- CloudFormation templates and AWS infrastructure definitions
- Ansible playbooks and configuration management
- Shell scripts and automation tasks
- Python dependencies and tooling

## Security Best Practices

When contributing to this project, please ensure:

1. **No hardcoded secrets**: Never commit AWS credentials, API keys, or passwords
2. **Least privilege**: IAM policies should grant minimum required permissions
3. **Encryption**: Enable encryption for S3 buckets and data at rest
4. **Input validation**: Sanitize all user inputs in scripts
5. **Dependency security**: Keep dependencies updated and audit regularly

## Known Security Considerations

- SSH keys are provisioned from GitHub public keys endpoint
- Third-party install scripts (Claude Code, Tailscale) are downloaded via HTTPS
- All EC2 access is via AWS Systems Manager (no inbound SSH port)
