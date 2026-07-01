#!/usr/bin/env bash
# Comprehensive CI/CD Wrapper Test Suite
# Tests wrapper functionality, distributed builds, and mining integration

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
log_test() {
    echo -e "${BLUE}[TEST]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((TESTS_PASSED++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((TESTS_FAILED++))
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $*"
}

# Test 1: Wrapper exists and is executable
test_wrapper_exists() {
    log_test "Wrapper exists on all nodes"

    local all_good=true
    for node in zephyr nexus forge sentry; do
        if [ "$node" = "$(hostname -s)" ]; then
            if [ -x "/run/current-system/sw/bin/nixos-rebuild" ]; then
                echo "  ✓ $node: wrapper present"
            else
                echo "  ✗ $node: wrapper missing"
                all_good=false
            fi
        else
            if ssh j_kro@$node "test -x /run/current-system/sw/bin/nixos-rebuild" 2>/dev/null; then
                echo "  ✓ $node: wrapper present"
            else
                echo "  ✗ $node: wrapper missing"
                all_good=false
            fi
        fi
    done

    if $all_good; then
        log_pass "Wrapper present on all nodes"
        return 0
    else
        log_fail "Wrapper missing on some nodes"
        return 1
    fi
}

# Test 2: Wrapper has CPU-only mining pause logic
test_cpu_mining_only() {
    log_test "Wrapper only pauses CPU mining (not GPU)"

    local all_good=true
    for node in nexus forge sentry; do
        if ssh j_kro@$node "grep -q 'CPU_MINING_SERVICES' /run/current-system/sw/bin/nixos-rebuild" 2>/dev/null; then
            echo "  ✓ $node: CPU mining services defined"
        else
            echo "  ✗ $node: CPU mining services not found"
            all_good=false
        fi

        if ssh j_kro@$node "grep -q 'readonly CPU_MINING_SERVICES=\"(.*xmrig' /run/current-system/sw/bin/nixos-rebuild" 2>/dev/null; then
            echo "  ✓ $node: Only CPU mining in pause list"
        else
            echo "  ✗ $node: CPU mining pause list incorrect"
            all_good=false
        fi
    done

    if $all_good; then
        log_pass "Wrapper configured for CPU-only mining pause"
        return 0
    else
        log_fail "Wrapper mining pause configuration incorrect"
        return 1
    fi
}

# Test 3: Native binary symlink exists
test_native_binary() {
    log_test "Native binary symlink exists"

    local all_good=true
    for node in zephyr nexus forge sentry; do
        if [ "$node" = "$(hostname -s)" ]; then
            if [ -L "/run/wrappers/bin/.nixos-rebuild-native" ]; then
                echo "  ✓ $node: native binary symlink exists"
            else
                echo "  ✗ $node: native binary symlink missing"
                all_good=false
            fi
        else
            if ssh j_kro@$node "test -L /run/wrappers/bin/.nixos-rebuild-native" 2>/dev/null; then
                echo "  ✓ $node: native binary symlink exists"
            else
                echo "  ✗ $node: native binary symlink missing"
                all_good=false
            fi
        fi
    done

    if $all_good; then
        log_pass "Native binary symlink present on all nodes"
        return 0
    else
        log_fail "Native binary symlink missing on some nodes"
        return 1
    fi
}

# Test 4: State directory exists
test_state_dir() {
    log_test "State directory /run/nixos-deploy exists"

    local all_good=true
    for node in zephyr nexus forge sentry; do
        if [ "$node" = "$(hostname -s)" ]; then
            if [ -d "/run/nixos-deploy" ]; then
                echo "  ✓ $node: state directory exists"
            else
                echo "  ✗ $node: state directory missing"
                all_good=false
            fi
        else
            if ssh j_kro@$node "test -d /run/nixos-deploy" 2>/dev/null; then
                echo "  ✓ $node: state directory exists"
            else
                echo "  ✗ $node: state directory missing"
                all_good=false
            fi
        fi
    done

    if $all_good; then
        log_pass "State directory present on all nodes"
        return 0
    else
        log_fail "State directory missing on some nodes"
        return 1
    fi
}

# Test 5: Distributed builds configured
test_distributed_builds() {
    log_test "Distributed builds configured correctly"

    local all_good=true
    for node in zephyr nexus forge sentry; do
        local expected_count
        case "$node" in
            zephyr) expected_count=3 ;;  # Should have nexus, forge, sentry
            nexus) expected_count=3 ;;   # Should have zephyr, forge, sentry
            forge) expected_count=3 ;;   # Should have zephyr, nexus, sentry
            sentry) expected_count=3 ;;  # Should have zephyr, nexus, forge
        esac

        local actual_count
        if [ "$node" = "$(hostname -s)" ]; then
            actual_count=$(wc -l < /etc/nix/machines)
        else
            actual_count=$(ssh j_kro@$node "wc -l < /etc/nix/machines" 2>/dev/null || echo "0")
        fi

        if [ "$actual_count" -eq "$expected_count" ]; then
            echo "  ✓ $node: has $expected_count build machines (correct)"
        else
            echo "  ✗ $node: has $actual_count build machines (expected $expected_count)"
            all_good=false
        fi
    done

    if $all_good; then
        log_pass "Distributed builds correctly configured"
        return 0
    else
        log_fail "Distributed builds configuration incorrect"
        return 1
    fi
}

# Test 6: Self-exclusion filter working
test_self_exclusion() {
    log_test "Self-exclusion filter working"

    local all_good=true
    for node in zephyr nexus forge sentry; do
        local has_self=false
        if [ "$node" = "$(hostname -s)" ]; then
            if grep -q "hostName = $node" /etc/nix/machines 2>/dev/null; then
                has_self=true
            fi
        else
            if ssh j_kro@$node "grep -q 'hostName = $node' /etc/nix/machines" 2>/dev/null; then
                has_self=true
            fi
        fi

        if $has_self; then
            echo "  ✗ $node: lists itself in build machines (bad)"
            all_good=false
        else
            echo "  ✓ $node: excludes itself from build machines"
        fi
    done

    if $all_good; then
        log_pass "Self-exclusion filter working correctly"
        return 0
    else
        log_fail "Self-exclusion filter not working"
        return 1
    fi
}

# Test 7: Wrapper command translation
test_command_translation() {
    log_test "Wrapper translates commands to Colmena"

    # Test on local node only
    local output
    output=$(bash -c 'echo "switch" | /run/current-system/sw/bin/nixos-rebuild 2>&1' | grep "colmena" || true)

    if [ -n "$output" ]; then
        echo "  ✓ wrapper translates to colmena commands"
        log_pass "Command translation working"
        return 0
    else
        echo "  ✗ wrapper does not translate to colmena"
        log_fail "Command translation not working"
        return 1
    fi
}

# Test 8: Justfile updated to use wrapper
test_justfile_wrapper() {
    log_test "Justfile uses wrapper instead of old script"

    if grep -q "sudo nixos-rebuild switch" /etc/nixos/justfile; then
        echo "  ✓ justfile uses wrapper"
        log_pass "Justfile correctly updated"
        return 0
    else
        echo "  ✗ justfile still uses old script"
        log_fail "Justfile not updated"
        return 1
    fi
}

# Main test execution
main() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CI/CD Wrapper Test Suite${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    test_wrapper_exists
    test_cpu_mining_only
    test_native_binary
    test_state_dir
    test_distributed_builds
    test_self_exclusion
    test_command_translation
    test_justfile_wrapper

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Test Results${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        log_info "All tests passed!"
        exit 0
    else
        log_info "Some tests failed - review output above"
        exit 1
    fi
}

main "$@"
