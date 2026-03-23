# Single source of truth for policy.json shape (see README.md).
# shellcheck shell=bash
# Sourced by validate-policy.sh — keep in sync with read-policy.sh field reads and ci-orchestrator jobs.

POLICY_STATES=(prototype alpha beta)
POLICY_KEYS=(format compliance compliance_checks dataset build unit-tests)
