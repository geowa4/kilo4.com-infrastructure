# Contributing

Contributions are welcome! Please follow these guidelines.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Install dependencies: `mise install && uv sync`
4. Configure your environment variables in `mise.local.toml`

## Development Workflow

### Validation

Before submitting changes, run validation:

```bash
# Validate all (CloudFormation, Ansible, shell scripts)
mise run security-scan

# Individual validators
mise run validate:cloudformation
mise run validate:playbooks
mise run validate:shell
```

### Code Style

- **Shell scripts**: Must pass `shellcheck` and use `set -euo pipefail`
- **Ansible playbooks**: Must pass `ansible-lint` with production profile
- **CloudFormation**: Must pass `cfn-lint` and AWS `validate-template`

### Commit Messages

Use clear, descriptive commit messages:

```
Add S3 encryption to playbooks bucket

- Enable KMS encryption with aws/s3 key
- Block all public access
- Add versioning configuration
```

## Pull Request Process

1. Ensure all validation passes
2. Update documentation if needed
3. Add a clear description of changes
4. Reference any related issues

## Security

- Never commit secrets, credentials, or API keys
- Review IAM policies for least privilege
- See [SECURITY.md](SECURITY.md) for vulnerability reporting

## License

By contributing, you agree that your contributions will be licensed under the terms in [LICENSE](LICENSE).
