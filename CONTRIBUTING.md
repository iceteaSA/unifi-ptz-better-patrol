# Contributing to UniFi PTZ Better Patrol

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Code of Conduct

By participating in this project, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When creating a bug report, include:

- **Clear descriptive title** for the issue
- **Detailed steps to reproduce** the problem
- **Expected behavior** vs actual behavior
- **System information**:
  - Device model (UDM, UDR, UNVR)
  - PTZ camera model (G5 PTZ, G6 PTZ, etc.)
  - UniFi Protect version
  - UniFi OS version
- **Relevant logs** from `journalctl -u ptz-patrol.service`
- **Configuration** (redact credentials)

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, include:

- **Clear descriptive title**
- **Detailed description** of the proposed functionality
- **Use cases** explaining why this enhancement would be useful
- **Possible implementation** approach if you have one in mind

### Pull Requests

1. **Fork the repository** and create your branch from `main`
2. **Make your changes**:
   - Follow the existing code style (see AGENTS.md for conventions)
   - All function-local variables must use `local`
   - Always double-quote variable expansions
   - Prefix functions with their module name (`api_*`, `patrol_*`, etc.)
3. **Lint your changes**:
   ```bash
   shellcheck -s bash api.sh discover.sh patrol.sh ptz-patrol.sh install.sh setup.sh bootstrap.sh uninstall.sh
   ```
4. **Test your changes**:
   - Test on actual hardware if possible
   - Verify patrol cycling, motion hold, and manual control detection
   - Check logs for errors or warnings
5. **Commit your changes**:
   - Use clear, descriptive commit messages
   - Reference related issues in commits
6. **Submit a pull request**:
   - Provide a clear description of changes
   - Link related issues
   - Include test results

## Development Guidelines

### Code Style

See [AGENTS.md](AGENTS.md) for the full style guide. Key points:

- `set -euo pipefail` in executable scripts only (not sourced libraries)
- Separate `local` declaration from subshell assignment: `local val; val=$(cmd)`
- Always quote variables: `"$cam_id"`, `"${presets[$idx]}"`
- Use `cfg()` helper for config reads with jq `//` defaults
- Use `log "tag" "level" "message"` for all output

### Architecture

```
api.sh          (base library: auth, HTTP, config, PTZ queries)
  -> discover.sh  (camera discovery; dual-mode: sourceable + standalone)
  -> patrol.sh    (per-camera patrol loop)
     -> ptz-patrol.sh  (sole entrypoint: init, discover, launch)
```

- Scripts source each other, not import modules
- One subprocess per camera with isolated auth
- `ptz-patrol.sh` is the only script users run directly

### Testing

There is no test suite yet. If adding tests, use [bats-core](https://github.com/bats-core/bats-core). When making changes, manually test:

1. **Startup**: Discovery, auto-setup, auth
2. **Patrol cycling**: Correct preset sequence
3. **Motion hold**: Patrol pauses on motion/smart detection
4. **Manual control**: Zoom drift detection triggers hold
5. **Dynamic tracking**: Enable/disable cycle on person detection
6. **Schedule**: Pause/resume at window boundaries
7. **Error recovery**: Auth failures, API errors, camera disconnect
8. **Shutdown**: Graceful cleanup, tracking disable

### Safety

- Never leave cameras in an undefined state
- Fail-safe: treat API failures as "active" (hold patrol, don't advance)
- Always disable dynamic tracking on shutdown
- `config.json` contains credentials — never commit it

## Commit Message Guidelines

- Use present tense ("Add feature" not "Added feature")
- Use imperative mood ("Move cursor to..." not "Moves cursor to...")
- Limit first line to 72 characters or less
- Reference issues and pull requests after the first line

Examples:
```
feat: add support for PTZ zoom tracking during patrol

fix: prevent snap-back to same preset after dynamic tracking clears

docs: update detection hierarchy with isSmartDetected field
```

## Branch Naming

- `feature/description` — New features
- `fix/description` — Bug fixes
- `docs/description` — Documentation changes
- `refactor/description` — Code refactoring

## Getting Help

- Check existing [documentation](README.md)
- Review [AGENTS.md](AGENTS.md) for architecture and conventions
- Search existing [issues](https://github.com/iceteaSA/unifi-ptz-better-patrol/issues)
- Create a new issue with detailed information

## License

By contributing to this project, you agree that your contributions will be licensed under the MIT License.
