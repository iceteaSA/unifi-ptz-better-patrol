# Pull Request

## Description

A clear and concise description of what this PR does.

Fixes #(issue number)

## Type of Change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Code refactoring (no functional changes)

## Changes Made

Detailed list of changes:

-
-
-

## Testing

### Test Environment

- **Device Model**: (e.g., UDM, UDR, UNVR)
- **PTZ Camera Model**: (e.g., G5 PTZ, G6 PTZ)
- **UniFi Protect Version**: (e.g., v6.2.88)
- **Test Duration**: (e.g., 1 hour, 24 hours)

### Test Scenarios

- [ ] Patrol cycling (correct preset sequence)
- [ ] Motion hold (pause on motion/smart detection)
- [ ] Manual control detection (zoom drift)
- [ ] Dynamic auto-tracking (enable/disable cycle)
- [ ] Schedule (pause/resume at window boundaries)
- [ ] Error recovery (auth failures, API errors)
- [ ] Startup (discovery, auto-setup)
- [ ] Shutdown (graceful cleanup)
- [ ] Shellcheck passes: `shellcheck -s bash api.sh discover.sh patrol.sh ptz-patrol.sh install.sh setup.sh bootstrap.sh uninstall.sh`
- [ ] Other:

### Test Results

```
# Paste relevant logs or output here

```

## Configuration Impact

- [ ] No configuration changes required
- [ ] New optional configuration parameters added
- [ ] Existing configuration parameters modified

If configuration changes are needed, document them here:

## Documentation

- [ ] README.md updated (if needed)
- [ ] AGENTS.md updated (if architecture changed)
- [ ] config.json.example updated (if config changed)
- [ ] Code comments added/updated

## Checklist

- [ ] My code follows the project's style guide (see AGENTS.md)
- [ ] All function-local variables use `local`
- [ ] All variable expansions are double-quoted
- [ ] `local` declarations are separate from subshell assignments
- [ ] Shellcheck passes with no warnings
- [ ] I have tested my changes on hardware (or explained why not)
- [ ] I have updated documentation as needed

---

**By submitting this PR, I confirm that**:
- [ ] I have read and agree to follow the [Code of Conduct](../CODE_OF_CONDUCT.md)
- [ ] I have read the [Contributing Guidelines](../CONTRIBUTING.md)
- [ ] My contribution is licensed under the MIT License
