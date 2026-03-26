# Assertion helpers for bats tests.
# Usage: load test_helper/assertions

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  [ "$expected" = "$actual" ] || fail "$context: expected [$expected], got [$actual]"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"
  case "$haystack" in
    *"$needle"*)
      ;;
    *)
      fail "$context: expected to find [$needle]"
      ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"
  case "$haystack" in
    *"$needle"*)
      fail "$context: did not expect to find [$needle]"
      ;;
    *)
      ;;
  esac
}
